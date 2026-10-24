use Mojo::Base -strict, -signatures;

use Test::More;
use Glucoglu::Metrics qw(agp agp_svg deltas events percentile tier1 today_svg tz_offset);

subtest 'percentile' => sub {
  is percentile([1, 2, 3, 4], 50), 2.5,  'interpolated median';
  is percentile([1, 2, 3, 4], 100), 4,   'max';
  is percentile([10], 25),         10,   'single value';
  ok !defined percentile([], 50),        'empty';
};

subtest 'tier1 basics' => sub {
  my $m = tier1([map {{ts => 1000 + $_ * 900, mg_dl => $_}} 100, 100, 100, 200], 14);
  is $m->{n},     4,     'four readings';
  is $m->{tir},   75,    'TIR counts the in-range share';
  is $m->{tar180}, 25,   'one above 180';
  is $m->{tbr70},  0,    'none below 70';
  is $m->{mean},  125,   'mean';
  ok abs($m->{sd} - sqrt(1875)) < 1e-9, 'population SD';
  ok abs($m->{cv} - 100 * sqrt(1875) / 125) < 1e-9, 'CV';
  ok abs($m->{gmi} - (3.31 + 0.02392 * 125)) < 1e-9, 'GMI (Bergenstal 2018)';
  ok abs($m->{ea1c} - (125 + 46.7) / 28.7) < 1e-9,   'eA1c (ADAG)';
  ok abs($m->{sufficiency} - 100 * 4 / (14 * 96)) < 1e-9, 'sufficiency = share of expected 96/day';
  is tier1([map {{ts => $_ * 900, mg_dl => 100}} 1 .. 300], 1)->{sufficiency}, 100, 'capped at 100';
  is tier1([], 14)->{n}, 0, 'empty window';
};

subtest 'tier1 thresholds are inclusive' => sub {
  my $m = tier1([map {{ts => $_ * 900, mg_dl => $_}} (70, 180, 71, 179)], 14);
  is $m->{tir},   100, '70 and 180 count as in range';
  is $m->{tar180}, 0, 'exactly 180 is not above';
  is $m->{tbr70},  0, 'exactly 70 is not below';
};

subtest 'events (Danne 2017)' => sub {
  my $seq = sub (@values) { [map {{ts => $_ * 900, mg_dl => $values[$_]}} 0 .. $#values] };

  is events($seq->(100, 65, 65, 65, 75))->{l1}, 1, '30-min dip below 70 = one L1 event';
  is events($seq->(100, 65, 75))->{l1},           1, '15-min dip still counts';
  my $stream = [map {{ts => $_ * 300, mg_dl => (100, 65, 75, 100)[$_]}} 0 .. 3];
  is events($stream)->{l1}, 0, 'sub-threshold for only 5 min is too short';
  is events($seq->(100, 65, 65, 65, 75))->{l2},   0, 'not deep enough for L2';

  my $with_gap = [map {{ts => $_, mg_dl => $_ < 2700 ? 60 : 75}} 0, 900, 1800, 9000, 9900, 10800];
  # 3 readings below 70, then a 90-min gap breaks continuity before recovery
  is events($with_gap)->{l1}, 0, 'gap >15 min closes an event without counting it';

  my $deep = events($seq->((100) x 2, 40, 40, 40, 60, 75));
  is $deep->{l2}, 1, 'L2 exits at >=54 even below 70';
  is $deep->{l1}, 1, 'L1 continues until >=70';

  my $long = [map {{ts => $_ * 900, mg_dl => $_ < 11 ? 60 : 75}} 0 .. 12];
  is events($long)->{ext_hypo}, 1, '150 min below 70 = extended hypo';

  my $hyper = events($seq->(100, 260, 260, 260, 240));
  is $hyper->{hyper},     1, '45 min above 250 = one hyper event';
  is $hyper->{ext_hyper}, 0, 'not extended';
};

subtest 'AGP slots respect the time zone' => sub {
  my $midnight_utc = [{ts => 0, mg_dl => 100}, {ts => 86400, mg_dl => 120}];
  my $slots = agp($midnight_utc, 0);
  is $slots->[0]{slot}, 0, 'midnight UTC lands in slot 0';
  is $slots->[0]{p5},   101, 'p5 of {100,120} interpolates to 101';
  is $slots->[0]{p50},  110, 'median of two midnight values';
  $slots = agp($midnight_utc, tz_offset('+05:30'));
  is $slots->[0]{slot}, 22, 'midnight UTC is 05:30 in IST: slot 22';
  like agp_svg($slots), qr{<svg.*path}s, 'SVG renders';
  is tz_offset('UTC'), 0, 'UTC';
  is tz_offset('-04:00'), -14400, 'negative offset';
};

subtest 'AGP keeps data gaps as gaps' => sub {
  my $bands = [{slot => 0, p5 => 80, p25 => 90, p50 => 100, p75 => 110, p95 => 120},
               {slot => 2, p5 => 80, p25 => 90, p50 => 100, p75 => 110, p95 => 120}];
  my $svg = agp_svg($bands);
  my @paths = $svg =~ /<path d="(.*?)"/g;
  is scalar @paths, 6, 'two runs x (outer band + inner band + median)';
};

subtest 'deltas and arrow (Libre 1 reality)' => sub {
  my $now = 1_000_000;
  # history points 15 min apart; a spot scan 5 min after the last history point
  my $rows = [
    {ts => $now - 1500, mg_dl => 100},
    {ts => $now - 600,  mg_dl => 110},
    {ts => $now - 300,  mg_dl => 118, source_type => 'spot'},
  ];
  my $d = deltas($rows, $now);
  is $d->{age},   300,  'spot is 5 min old';
  is $d->{d5},    8,   'Δ5 = spot vs last history point';
  is $d->{d15},   18,  'Δ15 = spot vs the point before';
  ok !defined $d->{d1}, 'no 1-min data';
  is $d->{arrow}, 'FortyFiveUp', 'slope 1.6 mg/dL/min';
  is $d->{glyph}, '↗', 'glyph';

  # two history points only: Δ15, no Δ5/Δ1 — the sensor-reported cadence
  $d = deltas([{ts => $now - 1800, mg_dl => 120}, {ts => $now - 900, mg_dl => 150}], $now);
  is $d->{d15}, 30, 'Δ15 from the last two history points';
  ok !defined $d->{d5}, 'no 5-min delta from 15-min cadence';
  is $d->{arrow}, 'SingleUp', '30 mg/dL over 15 min = 2.0 slope';

  my $slope = sub ($v, $e) { deltas([{ts => $now - $e * 60, mg_dl => 100}, {ts => $now, mg_dl => 100 + $v}], $now)->{arrow} };
  is $slope->(20, 5),  'DoubleUp',      '+4/min';
  is $slope->(-20, 5), 'DoubleDown',    '-4/min';
  is $slope->(-5, 5),  'FortyFiveDown', '-1/min';
  is $slope->(2, 15),  'Flat',          'reference too far for Δ5: Δ15 slope ~0.09';
  is deltas([], $now)->{glyph}, '?', 'no data';
};

subtest 'today trace' => sub {
  my $rows = [
    {ts => 3600,  mg_dl => 100, source_type => 'history'},
    {ts => 5400,  mg_dl => 110, source_type => 'history'},
    {ts => 36000, mg_dl => 150, source_type => 'spot'},    # 8-hour gap: separate segment
  ];
  my $svg = today_svg($rows, 0);
  like $svg, qr{<svg.*Today}s,   'SVG renders';
  my @lines = $svg =~ /stroke="#1f5c99" stroke-width="2"/g;
  is scalar @lines, 2, 'gap breaks the trace into two segments';
  like $svg, qr/<circle[^>]*r="3"/, 'spot scans are dots';
};

done_testing();