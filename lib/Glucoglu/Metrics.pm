package Glucoglu::Metrics;
# Pure Tier 1 metrics engine (design §7, rows 1-11) — no DB, no HTTP; testable in isolation.
# Rows must be [{ts => epoch seconds, mg_dl => value}, ...] sorted by ts.
use Mojo::Base -base, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(tier1 agp agp_svg events percentile tz_offset);

# Consensus thresholds (Battelino 2019; 54: IHSG 2017). Inclusive bounds: TIR is 70<=G<=180.
my ($TIR_LO, $TIR_HI, $TAR_HI, $TBR_LO, $TBR_VLOW) = (70, 180, 250, 70, 54);
my $EVENT_MIN = 15 * 60;         # event minimum duration (Danne 2017)
my $EXT_HYPO  = 120 * 60;        # extended hypo: >120 min below 70
my $EXT_HYPER = 90 * 60;         # shortcut: extended hyper = one continuous >250 stretch >=90 min, not the flapping ">=90 cumulative within 120 min" variant; revisit with 1-min stream data

sub percentile ($values, $p) {
  return undef unless @$values;
  my @s = sort { $a <=> $b } @$values;
  return $s[0] if @s == 1;
  my $idx   = $#s * $p / 100;    # linear interpolation (PERCENTILE.INC)
  my $lo    = int $idx;
  my $frac  = $idx - $lo;
  return $lo < $#s ? $s[$lo] + ($s[$lo + 1] - $s[$lo]) * $frac : $s[-1];
}

sub tier1 ($rows, $window_days) {
  my @g = map { $_->{mg_dl} } @$rows;
  my $n = scalar @g;
  return {n => 0, events => {}} unless $n;

  my $sum = 0; $sum += $_ for @g;
  my $mean = $sum / $n;
  my $var  = 0; $var += ($_ - $mean)**2 for @g;
  my $sd   = sqrt $var / $n;
  my $pct  = sub ($lo, $hi) { 100 * (grep { $_ >= $lo && $_ <= $hi } @g) / $n };

  # shortcut: expected readings assume the 15-min cadence (96/day); stream users trivially pass
  my $expected = $window_days * 96;
  return {
    n    => $n,
    tir  => $pct->($TIR_LO, $TIR_HI),
    tar180 => $pct->($TIR_HI + 0.0001, 1e9),
    tar250 => $pct->($TAR_HI + 0.0001, 1e9),
    tbr70  => $pct->(-1e9, $TBR_LO - 0.0001),
    tbr54  => $pct->(-1e9, $TBR_VLOW - 0.0001),
    mean => $mean,
    sd   => $sd,
    cv   => $mean ? 100 * $sd / $mean : 0,
    gmi  => 3.31 + 0.02392 * $mean,      # Bergenstal 2018
    ea1c => ($mean + 46.7) / 28.7,       # Nathan 2008 (ADAG)
    sufficiency => $expected ? ($n / $expected > 1 ? 100 : 100 * $n / $expected) : 0,
    events => events($rows),
  };
}

# Hypo/hyper events (Danne 2017): start >=15 min beyond a threshold, end at/above the exit
# level (L1 exit >=70, L2 exit >=54). A reading gap >15 min breaks continuity and closes events.
sub events ($rows) {
  my %ev = (l1 => 0, l2 => 0, hyper => 0, ext_hypo => 0, ext_hyper => 0);
  my ($prev, $s70, $s54, $s250);
  for my $r (@$rows) {
    my ($ts, $g) = ($r->{ts}, $r->{mg_dl});
    ($s70, $s54, $s250) = (undef) x 3 if defined $prev && $ts - $prev > $EVENT_MIN;
    $s70  //= $ts if $g < 70;
    $s54  //= $ts if $g < 54;
    $s250 //= $ts if $g > 250;
    if ($g >= 70 && defined $s70) {
      if ($ts - $s70 >= $EVENT_MIN) { $ev{l1}++; $ev{ext_hypo}++ if $ts - $s70 > $EXT_HYPO }
      $s70 = undef;
    }
    if ($g >= 54 && defined $s54) { $ev{l2}++ if $ts - $s54 >= $EVENT_MIN; $s54 = undef }
    if ($g <= 250 && defined $s250) {
      if ($ts - $s250 >= $EVENT_MIN) { $ev{hyper}++; $ev{ext_hyper}++ if $ts - $s250 >= $EXT_HYPER }
      $s250 = undef;
    }
    $prev = $ts;
  }
  return \%ev;
}

# AGP (§6): percentiles 5/25/50/75/95 per 15-min time-of-day slot, in the user's local time.
sub agp ($rows, $tz_off) {
  my @slots = map { [] } 1 .. 96;
  for my $r (@$rows) {
    my $local  = $r->{ts} + $tz_off;
    my $minute = (($local % 86400) + 86400) % 86400;
    push $slots[int $minute / 900]->@*, $r->{mg_dl};
  }
  my @out;
  for my $i (0 .. 95) {
    next unless $slots[$i]->@*;
    push @out, {slot => $i, map { ("p$_" => percentile($slots[$i], $_)) } 5, 25, 50, 75, 95};
  }
  \@out;
}

sub tz_offset ($tz) {
  return 0 unless defined $tz && $tz =~ /^([+-])(\d{2}):(\d{2})$/;
  my ($sign, $h, $m) = ($1, $2, $3);
  my $off = $h * 3600 + $m * 60;
  return $sign eq '-' ? -$off : $off;
}

# Server-side SVG: fixed 40-400 mg/dL grid, threshold guides at 70/180/250, slot gaps preserved.
sub agp_svg ($bands) {
  my ($X0, $X1, $Y0, $Y1) = (42, 940, 16, 246);
  my ($YMIN, $YMAX) = (40, 400);
  my $y = sub ($v) { $Y1 - ($v - $YMIN) / ($YMAX - $YMIN) * ($Y1 - $Y0) };
  my $x = sub ($slot) { $X0 + $slot / 96 * ($X1 - $X0) };

  # split into consecutive-slot runs so data gaps stay visible
  my @runs;
  for my $b (@$bands) {
    if (!@runs || $runs[-1][-1]{slot} != $b->{slot} - 1) { push @runs, [$b] }
    else                                                   { push $runs[-1]->@*, $b }
  }

  my @parts = sprintf(
    q{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 270" role="img" aria-label="AGP: glucose percentiles by time of day">
<rect x="42" y="16" width="898" height="230" fill="none" stroke="currentColor" opacity="0.3"/>});
  for my $line ([70, '70'], [180, '180'], [250, '250']) {
    my $yy = $y->($line->[0]);
    push @parts, sprintf(
      q{<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="currentColor" stroke-dasharray="4 4" opacity="0.4"/>
<text x="944" y="%.1f" font-size="10" text-anchor="end" fill="currentColor" opacity="0.7">%s</text>},
      $X0, $yy, $X1, $yy, $yy + 3, $line->[1]);
  }
  my $band_path = sub ($run, $lo_key, $hi_key, $fill, $op) {
    my @up   = map { $x->($_->{slot}) . ',' . sprintf('%.1f', $y->($_->{$hi_key})) } @$run;
    my @down = map { $x->($_->{slot}) . ',' . sprintf('%.1f', $y->($_->{$lo_key})) } reverse @$run;
    my $d = 'M' . join(' L', @up) . ' L' . join(' L', @down) . ' Z';
    sprintf q{<path d="%s" fill="%s" fill-opacity="%.2f" stroke="none"/>}, $d, $fill, $op;
  };
  for my $run (@runs) {
    push @parts, $band_path->($run, 'p5',  'p95', '#3a76c4', 0.18);
    push @parts, $band_path->($run, 'p25', 'p75', '#3a76c4', 0.40);
    push @parts, sprintf q{<path d="%s" fill="none" stroke="#1f5c99" stroke-width="2"/>},
      'M' . join(' L', map { $x->($_->{slot}) . ',' . sprintf('%.1f', $y->($_->{p50})) } @$run);
  }
  for my $hour (0, 6, 12, 18, 24) {
    my $xx = $x->($hour * 4);
    push @parts, sprintf(
      q{<text x="%.1f" y="260" font-size="10" text-anchor="middle" fill="currentColor" opacity="0.7">%02d</text>},
      $xx, $hour);
  }
  push @parts, '</svg>';
  return join "\n", @parts;
}

1;