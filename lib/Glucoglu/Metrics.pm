package Glucoglu::Metrics;
# Pure Tier 1 metrics engine (design §7, rows 1-11) — no DB, no HTTP; testable in isolation.
# Rows must be [{ts => epoch seconds, mg_dl => value}, ...] sorted by ts.
use Mojo::Base -base, -signatures;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(tier1 agp agp_svg events percentile tz_offset deltas today_svg);

# Consensus thresholds (Battelino 2019; 54: IHSG 2017). Inclusive bounds: TIR is 70<=G<=180.
my ($TIR_LO, $TIR_HI, $TAR_HI, $TBR_LO, $TBR_VLOW) = (70, 180, 250, 70, 54);
my $EVENT_MIN = 15 * 60;         # event minimum duration (Danne 2017)
my $GAP_MAX   = 20 * 60;         # longer reading gap breaks continuity: one missing 15-min point plus jitter
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

# Hypo/hyper events (Danne 2017; Battelino 2023 Table 4). Per kind (L1 <70, L2 <54, hyper >250):
# - starts at the first reading beyond the threshold;
# - ends only after readings stay at/past the exit level (L1 >=70, L2 >=54, hyper <=250) for 15 min;
#   a reading beyond the threshold during that time continues the event;
# - counts if the time beyond the threshold is >=15 min: start to the first exit-level reading.
# A reading gap >20 min, or the end of the data, closes an open event. If no recovery was seen,
# the time beyond is start to the last reading beyond: an event cut by a gap still counts (Danne
# defines the event by its first 15 min), so a sensor gap during a hypo does not hide it.
sub events ($rows) {
  my %ev = (l1 => 0, l2 => 0, hyper => 0, ext_hypo => 0, ext_hyper => 0);
  my %rule = (    # kind => [beyond the threshold, at/past the exit level]
    l1    => [sub ($g) { $g < 70 },  sub ($g) { $g >= 70 }],
    l2    => [sub ($g) { $g < 54 },  sub ($g) { $g >= 54 }],
    hyper => [sub ($g) { $g > 250 }, sub ($g) { $g <= 250 }],
  );
  my %open;    # kind => {start, last => last reading beyond, exit => first exit-level reading or undef}
  my $close = sub ($k) {
    my $e   = delete $open{$k} or return;
    my $dur = ($e->{exit} // $e->{last}) - $e->{start};
    return unless $dur >= $EVENT_MIN;
    $ev{$k}++;
    $ev{ext_hypo}++  if $k eq 'l1'    && $dur > $EXT_HYPO;
    $ev{ext_hyper}++ if $k eq 'hyper' && $dur >= $EXT_HYPER;
  };
  my $prev;
  for my $r (@$rows) {
    my ($ts, $g) = ($r->{ts}, $r->{mg_dl});
    if (defined $prev && $ts - $prev > $GAP_MAX) { $close->($_) for keys %open }
    for my $k (keys %rule) {
      my ($beyond, $ok) = $rule{$k}->@*;
      if ($beyond->($g)) {
        my $e = $open{$k} //= {start => $ts};
        ($e->{last}, $e->{exit}) = ($ts, undef);
      }
      elsif ($open{$k} && $ok->($g)) {
        my $e = $open{$k};
        $e->{exit} //= $ts;
        $close->($k) if $ts - $e->{exit} >= $EVENT_MIN;
      }
    }
    $prev = $ts;
  }
  $close->($_) for keys %open;
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

# Deltas (§6 "Trend and deltas"): ΔX = latest − the newest reading at or before
# (latest − X min), valid only if that reference is within 2X of the latest, else undef.
# This is what makes the Libre 1 case work: two history points give Δ15; a spot scanned
# 5 min after a history point gives Δ5 = spot − history, and Δ15 = spot − the point before.
# Arrow: Dexcom thresholds on mg/dL/min slope, basis Δ5 else Δ15 else Δ1 (best available).
sub deltas ($rows, $now) {
  my @sorted = sort { $a->{ts} <=> $b->{ts} } @$rows;
  return {glyph => '?'} unless @sorted;
  my $latest = $sorted[-1];
  my %d = (age => $now - $latest->{ts});
  my %pair;    # window => [delta, elapsed_minutes]
  for my $min (1, 5, 15) {
    my $ref;
    for my $r (@sorted) {
      last if $r->{ts} > $latest->{ts} - $min * 60;
      $ref = $r;
    }
    next unless $ref && $latest->{ts} != $ref->{ts} && $latest->{ts} - $ref->{ts} <= 2 * $min * 60;
    $pair{$min} = [$latest->{mg_dl} - $ref->{mg_dl}, ($latest->{ts} - $ref->{ts}) / 60];
    $d{"d$min"} = $pair{$min}[0];
  }
  my $basis = $pair{5} // $pair{15} // $pair{1};
  if ($basis) {
    my $slope = $d{slope} = $basis->[0] / $basis->[1];
    ($d{arrow}, $d{glyph}) =
        $slope >= 3  ? ('DoubleUp', '↑↑')
      : $slope >= 2  ? ('SingleUp', '↑')
      : $slope >= 1  ? ('FortyFiveUp', '↗')
      : $slope >  -1 ? ('Flat', '→')
      : $slope >  -2 ? ('FortyFiveDown', '↘')
      : $slope >  -3 ? ('SingleDown', '↓')
      :                ('DoubleDown', '↓↓');
  }
  return \%d;
}

# Today trace: all readings since local midnight, line broken at >30-min gaps,
# spot values drawn as dots. Same 40-400 scale and guides as the AGP.
sub today_svg ($rows, $tz_off) {
  return '' unless @$rows;
  my ($X0, $X1, $Y0, $Y1) = (42, 940, 16, 246);
  my ($YMIN, $YMAX) = (40, 400);
  my $y = sub ($v) { $Y1 - ($v - $YMIN) / ($YMAX - $YMIN) * ($Y1 - $Y0) };
  my $x = sub ($ts) { my $l = (($ts + $tz_off) % 86400 + 86400) % 86400; $X0 + $l / 86400 * ($X1 - $X0) };

  my @parts = sprintf
    q{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 270" role="img" aria-label="Today's glucose trace">
<rect x="%d" y="%.1f" width="%d" height="%.1f" fill="#28a745" fill-opacity="0.07"/>
<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="currentColor" opacity="0.3"/>},
    $X0, $y->(180), $X1 - $X0, $y->(70) - $y->(180), $X0, $Y0, $X1 - $X0, $Y1 - $Y0;
  for my $line ([70, '70'], [180, '180'], [250, '250']) {
    my $yy = $y->($line->[0]);
    push @parts, sprintf(
      q{<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="currentColor" stroke-dasharray="4 4" opacity="0.4"/>
<text x="944" y="%.1f" font-size="10" text-anchor="end" fill="currentColor" opacity="0.7">%s</text>},
      $X0, $yy, $X1, $yy, $yy + 3, $line->[1]);
  }

  my (@segs, $prev);
  for my $r (@$rows) {
    push @segs, [] if !@segs || (defined $prev && $r->{ts} - $prev > 1800);
    push $segs[-1]->@*, $r;
    $prev = $r->{ts};
  }
  for my $seg (@segs) {
    push @parts, sprintf q{<path d="%s" fill="none" stroke="#1f5c99" stroke-width="2"/>},
      'M' . join(' L', map { sprintf('%.1f,%.1f', $x->($_->{ts}), $y->($_->{mg_dl})) } @$seg);
    push @parts, sprintf(q{<circle cx="%.1f" cy="%.1f" r="3" fill="#1f5c99"/>},
      $x->($_->{ts}), $y->($_->{mg_dl})) for grep { ($_->{source_type} // '') eq 'spot' } @$seg;
  }
  my $last = $segs[-1][-1];
  push @parts, sprintf q{<circle cx="%.1f" cy="%.1f" r="4" fill="#1f5c99"/>},
    $x->($last->{ts}), $y->($last->{mg_dl});
  for my $hour (0, 6, 12, 18, 24) {
    push @parts, sprintf(
      q{<text x="%.1f" y="260" font-size="10" text-anchor="middle" fill="currentColor" opacity="0.7">%02d</text>},
      $X0 + $hour / 24 * ($X1 - $X0), $hour);
  }
  push @parts, '</svg>';
  return join "\n", @parts;
}

1;