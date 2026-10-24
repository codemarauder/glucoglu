use Mojo::Base -strict, -signatures;

use Test::More;
plan skip_all => 'set GLUCOGLU_DB_DSN to a throwaway Postgres DSN (e.g. postgresql://glucoglu:pass@localhost/glucoglu_test)'
  unless $ENV{GLUCOGLU_DB_DSN};

use Test::Mojo;
my $t   = Test::Mojo->new('Glucoglu');    # startup runs the migrations
my $db  = $t->app->pg->db;
my $one = sub ($sql) { $db->query($sql)->array->[0] };
my $cnt = sub ($table) { $db->query("SELECT count(*) FROM $table")->array->[0] };
$db->query(
  'TRUNCATE shares, lab_a1c, notes, exercise, iob, insulin, meals, payload_log, readings, login_tokens, mail_log, users, invites');

subtest 'users defaults after the freeze' => sub {
  $db->query("INSERT INTO users (email) VALUES ('a\@b.co')");
  is $one->("SELECT unit FROM users WHERE email = 'a\@b.co'"), 'mgdl', 'unit defaults to mgdl (D11)';
  is $one->("SELECT tz   FROM users WHERE email = 'a\@b.co'"), 'UTC',  'tz defaults to UTC (D13)';
  is $one->("SELECT tier FROM users WHERE email = 'a\@b.co'"), 'free', 'billing stub tier';
}, $one;

subtest 'readings keep their design source types' => sub {
  my $uid = $one->("SELECT id FROM users WHERE email = 'a\@b.co'");
  $db->query("INSERT INTO readings (user_id, ts, mg_dl, raw) VALUES (?, now(), 100, '{}')", $uid);
  is $one->('SELECT source_type FROM readings'), 'stream', 'uploader default is stream (§3)';
  $db->query('DELETE FROM readings');
}, $one;

subtest 'right-to-delete cascades everywhere (D12)' => sub {
  my $uid = $db->query("INSERT INTO users (email) VALUES ('o\@b.co') RETURNING id")->array->[0];
  my $vid = $db->query("INSERT INTO users (email) VALUES ('v\@b.co') RETURNING id")->array->[0];
  $db->query('INSERT INTO meals (user_id, ts, carbs) VALUES (?, now(), 30)', $uid);
  $db->query("INSERT INTO insulin (user_id, ts, units, kind) VALUES (?, now(), 5, 'rapid')", $uid);
  $db->query('INSERT INTO iob (user_id, ts, units) VALUES (?, now(), 1.5)', $uid);
  $db->query('INSERT INTO exercise (user_id, ts, minutes) VALUES (?, now(), 45)', $uid);
  $db->query("INSERT INTO notes (user_id, ts, body) VALUES (?, now(), 'felt great')", $uid);
  $db->query('INSERT INTO lab_a1c (user_id, ts, percent) VALUES (?, now(), 6.4)', $uid);
  $db->query('INSERT INTO shares (owner_id, viewer_id) VALUES (?, ?)', $uid, $vid);
  $db->query('INSERT INTO readings (user_id, ts, mg_dl, raw) VALUES (?, now(), 100, \'{}\')', $uid);

  ok !eval { $db->query('INSERT INTO insulin (user_id, ts, units, kind) VALUES (?, now(), -5, \'rapid\')', $uid); 1 },
    'negative insulin rejected';
  ok !eval { $db->query('INSERT INTO lab_a1c (user_id, ts, percent) VALUES (?, now(), 25)', $uid); 1 },
    'impossible A1c rejected';
  ok !eval { $db->query('INSERT INTO shares (owner_id, viewer_id) VALUES (?, ?)', $uid, $uid); 1 },
    'no self-sharing';

  $db->query('DELETE FROM users WHERE id = ?', $uid);
  for my $table (qw(meals insulin iob exercise notes lab_a1c readings shares)) {
    is $cnt->($table), 0, "$table emptied by user delete";
  }
}, $one, $cnt;

done_testing();