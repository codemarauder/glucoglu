# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
use Mojo::Base -strict, -signatures;

use Test::More;

# A shiftable clock for the whole process. Must be installed before the app is compiled.
BEGIN { $main::CLOCK = 0; *CORE::GLOBAL::time = sub :prototype() { CORE::time() + $main::CLOCK } }

plan skip_all => 'set GLUCOGLU_DB_DSN to a throwaway Postgres DSN (e.g. postgresql://glucoglu:pass@localhost/glucoglu_test)'
  unless $ENV{GLUCOGLU_DB_DSN};

# Fake mailer: records the codes instead of sending mail.
{
  package Glucoglu::Mailer::Fake;
  use Mojo::Base -base, -signatures;
  has codes => sub { [] };
  sub send_login ($self, $email, $code, $url) { push @{$self->codes}, [$email, $code, $url]; return 1 }
}

use Test::Mojo;
my $t  = Test::Mojo->new('Glucoglu');
$t->app->mailer(Glucoglu::Mailer::Fake->new);
my $db = $t->app->pg->db;
$db->query(
  'TRUNCATE shares, lab_a1c, notes, exercise, iob, insulin, meals, payload_log, readings, login_tokens, mail_log, users, invites');
$db->query("INSERT INTO invites (code) VALUES ('TEST01')");

sub _login ($t, $email = 'a@b.co', $invite = 'TEST01') {
  $t->ua->max_redirects(0);
  $t->post_ok('/login' => form => {email => $email, invite => $invite, tz => '+05:30'})->status_is(302);
  my $code = $t->app->mailer->codes->[-1][1];
  $t->post_ok('/login/check' => form => {code => $code})->status_is(302);
  $t->get_ok('/dashboard')->status_is(200);
}

subtest 'dashboard with data' => sub {
  _login($t);
  is $db->query("SELECT tz FROM users WHERE email = 'a\@b.co'")->array->[0], '+05:30', 'tz captured at registration (D13)';

  my $uid = $db->query("SELECT id FROM users WHERE email = 'a\@b.co'")->array->[0];
  my $now = time;
  $db->query('INSERT INTO readings (user_id, ts, mg_dl, source_type, raw) VALUES (?, to_timestamp(?), 120, \'history\', \'{}\')',
    $uid, $now - 3600);
  $db->query('INSERT INTO readings (user_id, ts, mg_dl, source_type, raw) VALUES (?, to_timestamp(?), 200, \'history\', \'{}\')',
    $uid, $now - 1800);
  $db->query('INSERT INTO readings (user_id, ts, mg_dl, source_type, raw) VALUES (?, to_timestamp(?), 999, \'spot\', \'{}\')',
    $uid, $now - 60);    # scan-biased spot value: latest, but not in the metrics

  $t->get_ok('/dashboard')->status_is(200)
    ->content_like(qr{Time in range 70\x{2013}180})->content_like(qr{50\.0%})
    ->content_like(qr{<svg.*percentiles}s)->content_like(qr{<span class="today-current">999})
    ->content_like(qr{main class="wide"})->content_like(qr{class="warn"})
    ->content_like(qr{the 100 m race}s)->content_like(qr{Today's glucose trace}s);
  $t->get_ok('/dashboard?days=90')->status_is(200)->content_like(qr{percentiles by time of day});
  $t->get_ok('/dashboard?days=99')->status_is(200)->content_like(qr{percentiles by time of day}, 'invalid window falls back');
};

subtest 'day paging on the Today graph' => sub {
  my $uid = $db->query("SELECT id FROM users WHERE email = 'a\@b.co'")->array->[0];
  $db->query('INSERT INTO readings (user_id, ts, mg_dl, source_type, raw) VALUES (?, to_timestamp(?), 155, \'spot\', \'{}\')',
    $uid, time - 2 * 86400);    # spot: shows in the daily trace, not in the metrics

  $t->get_ok('/dashboard?day=2')->status_is(200)
    ->content_like(qr{Today's glucose trace}s, 'two days back has its own trace')
    ->content_like(qr{today-current}, 'current value still shows today (day 0) data')
    ->content_like(qr{title="next day"}, 'forward button is an active link when paged back');
  $t->get_ok('/dashboard?day=1')->status_is(200)->content_like(qr{No readings for this day});
  $t->get_ok('/dashboard?day=999')->status_is(200)->content_like(qr{today-current}, 'out-of-range day falls back to today');
  $t->get_ok('/dashboard')->status_is(200)
    ->content_like(qr{navbtn right off}, 'forward button disabled on day 0')
    ->content_like(qr{title="previous day"}, 'back button active on day 0')
    ->content_unlike(qr{>today</a>}, 'today shortcut removed')
    ->content_like(qr{<span class="sep">\|</span>}, 'AGP windows are pipe-separated')
    ->content_like(qr{hint caption}, 'captions carry the right-align class');
};

subtest 'deltas look back 30 min past midnight' => sub {
  my $t2 = Test::Mojo->new('Glucoglu');
  $t2->app->mailer(Glucoglu::Mailer::Fake->new);
  $db->query("INSERT INTO invites (code) VALUES ('TEST02')");
  _login($t2, 'late@b.co', 'TEST02');
  my $uid = $db->query("SELECT id FROM users WHERE email = 'late\@b.co'")->array->[0];

  # Local time is +05:30. Put the clock at 00:05 local: 23:50 is yesterday, 00:05 is today.
  my ($off, $real) = (19800, CORE::time);
  my $midnight = int(($real + $off) / 86400) * 86400 - $off;
  my $ins = 'INSERT INTO readings (user_id, ts, mg_dl, source_type, raw) VALUES (?, to_timestamp(?), ?, \'stream\', \'{}\')';
  $db->query($ins, $uid, $midnight - 600, 100);    # 23:50
  $db->query($ins, $uid, $midnight + 300, 115);    # 00:05

  local $main::CLOCK = $midnight + 300 - $real;
  $t2->get_ok('/dashboard')->status_is(200)
    ->content_like(qr{15mins</strong>\s*\+15 mg/dL}, 'delta 15 reaches back over midnight');
};

subtest 'non-numeric user_id is not found, not 500' => sub {
  $t->get_ok('/dashboard?user_id=abc')->status_is(404);
  $t->get_ok('/dashboard?user_id=1%20OR%201%3D1')->status_is(404, 'no SQL reaches the database');
};

subtest 'Last 24 h summary under Today' => sub {
  my $mk = sub ($email, $invite) {
    my $tt = Test::Mojo->new('Glucoglu');
    $tt->app->mailer(Glucoglu::Mailer::Fake->new);
    $db->query('INSERT INTO invites (code) VALUES (?)', $invite);
    _login($tt, $email, $invite);
    my $uid = $db->query('SELECT id FROM users WHERE email = ?', $email)->array->[0];
    return ($tt, $uid);
  };
  my $ins = sub ($uid, $ts, $mg, $type) {
    $db->query('INSERT INTO readings (user_id, ts, mg_dl, source_type, raw) VALUES (?, to_timestamp(?), ?, ?, \'{}\')',
      $uid, $ts, $mg, $type);
  };
  my $now = time;

  # 10 history readings in the last 24 h: 60, 50, seven at 120, one at 200 (15 min apart).
  # Known: TIR 70%, <70 20%, <54 10%, >180 10%, mean 115, one hypo event, 10 of 96 slots = 10%.
  my ($t1, $u1) = $mk->('l24a@b.co', 'TEST03');
  my $base = $now - 6 * 3600;
  my $i = 0;
  $ins->($u1, $base + 900 * $i++, $_, 'history') for 60, 50, (120) x 7, 200;
  $ins->($u1, $now - 25 * 3600, 300, 'history');    # older than 24 h: not counted
  $ins->($u1, $now - 3 * 3600, 999, 'spot');        # spot: not counted
  $t1->get_ok('/dashboard')->status_is(200)
    ->content_like(qr{Last 24 h:}, 'label says Last 24 h')
    ->content_like(qr{<span class="warn">TIR: 70%</span>}, 'TIR with its grade')
    ->content_like(qr{<span class="bad">&lt;70: 20%</span>}, '<70 with its grade')
    ->content_like(qr{<span class="bad">&lt;54: 10%</span>}, '<54')
    ->content_like(qr{<span class="good">&gt;180: 10%</span>}, '>180')
    ->content_like(qr{Mean: 115\b}, 'mean excludes the old reading and the spot value')
    ->content_like(qr{Hypos: 1\b}, 'one hypo event')
    ->content_like(qr{Data: 10%}, 'data share of 96 slots')
    ->content_like(qr{Targets are for 14 days}, 'note about the targets')
    ->text_unlike('p.last24' => qr{GMI|eA1c|CV|SD}, 'no GMI, eA1c, CV or SD in the line');

  # Only a reading older than 24 h: no data.
  my ($t2, $u2) = $mk->('l24b@b.co', 'TEST04');
  $ins->($u2, $now - 25 * 3600, 120, 'history');
  $t2->get_ok('/dashboard')->status_is(200)->content_like(qr{Last 24 h: no data});
};

subtest 'settings holds ingest and account' => sub {
  $t->get_ok('/dashboard/settings')->status_is(200)
    ->content_like(qr{Regenerate ingest token})->content_like(qr{Log out})
    ->content_like(qr{api/v1/entries});
  $t->get_ok('/dashboard')->content_unlike(qr{Regenerate ingest token}, 'dashboard no longer shows ingest');
};

subtest 'D10: no data without ownership or grant' => sub {
  my $other = $db->query("INSERT INTO users (email) VALUES ('x\@y.co') RETURNING id")->array->[0];
  $t->get_ok("/dashboard?user_id=$other")->status_is(404, 'foreign dashboard does not exist for me');
  $db->query('INSERT INTO shares (owner_id, viewer_id) VALUES (?, ?)', $other,
    $db->query("SELECT id FROM users WHERE email = 'a\@b.co'")->array->[0]);
  $t->get_ok("/dashboard?user_id=$other")->status_is(200, 'read-only grant works (D10)');
};

done_testing();