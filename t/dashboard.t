use Mojo::Base -strict, -signatures;

use Test::More;
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

sub _login ($t) {
  $t->ua->max_redirects(0);
  $t->post_ok('/login' => form => {email => 'a@b.co', invite => 'TEST01', tz => '+05:30'})->status_is(302);
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

subtest 'D10: no data without ownership or grant' => sub {
  my $other = $db->query("INSERT INTO users (email) VALUES ('x\@y.co') RETURNING id")->array->[0];
  $t->get_ok("/dashboard?user_id=$other")->status_is(404, 'foreign dashboard does not exist for me');
  $db->query('INSERT INTO shares (owner_id, viewer_id) VALUES (?, ?)', $other,
    $db->query("SELECT id FROM users WHERE email = 'a\@b.co'")->array->[0]);
  $t->get_ok("/dashboard?user_id=$other")->status_is(200, 'read-only grant works (D10)');
};

done_testing();