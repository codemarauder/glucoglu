use Mojo::Base -strict, -signatures;
use File::Temp 'tempfile';

use Test::More;
plan skip_all => 'set GLUCOGLU_DB_DSN to a throwaway Postgres DSN (e.g. postgresql://glucoglu:pass@localhost/glucoglu_test)'
  unless $ENV{GLUCOGLU_DB_DSN};

use Test::Mojo;
my $t   = Test::Mojo->new('Glucoglu');
my $db  = $t->app->pg->db;
my $one = sub ($sql) { $db->query($sql)->array->[0] };
$db->query('DELETE FROM mail_log; DELETE FROM login_tokens; DELETE FROM users; DELETE FROM invites');

my $admin = sub (@args) { system($^X, 'script/glucoglu-admin', @args) };

subtest 'invite' => sub {
  $admin->('invite', 'TEST01');
  ok !$?, 'invite exits 0';
  is $one->("SELECT count(*) FROM invites WHERE code = 'TEST01'"), 1, 'custom invite code created';
  $admin->('invite');
  like $one->("SELECT code FROM invites WHERE code <> 'TEST01'"), qr/^GLU-[0-9a-f]{8}$/, 'random invite code minted';
}, $one;

subtest 'delete removes the user and their data' => sub {
  my $uid = $db->query("INSERT INTO users (email) VALUES ('a\@b.co') RETURNING id")->array->[0];
  $db->query('INSERT INTO login_tokens (code, user_id, expires_at) VALUES (?, ?, now())', 'X', $uid);
  $db->query("INSERT INTO mail_log (email) VALUES ('a\@b.co')");
  $admin->('delete', 'a@b.co');
  ok !$?, 'delete exits 0';
  is $one->('SELECT count(*) FROM users'),                 0, 'user gone';
  is $one->('SELECT count(*) FROM login_tokens'),         0, 'tokens cascaded';
  is $one->("SELECT count(*) FROM mail_log WHERE email = 'a\@b.co'"), 0, 'mail log cleaned';
}, $one;

subtest 'prune drops expired tokens and old mail log' => sub {
  my $uid = $db->query("INSERT INTO users (email) VALUES ('a\@b.co') RETURNING id")->array->[0];
  $db->query("INSERT INTO login_tokens (code, user_id, expires_at) VALUES ('expired', ?, now() - interval '1 minute')", $uid);
  $db->query("INSERT INTO login_tokens (code, user_id, expires_at) VALUES ('live', ?, now() + interval '10 minutes')", $uid);
  $db->query("INSERT INTO mail_log (email, created_at) VALUES ('a\@b.co', now() - interval '40 days')");
  $db->query("INSERT INTO mail_log (email) VALUES ('a\@b.co')");
  $admin->('prune');
  ok !$?, 'prune exits 0';
  is $one->("SELECT code FROM login_tokens"), 'live', 'expired token pruned, live kept';
  is $one->("SELECT count(*) FROM mail_log"), 1, 'old mail pruned, recent kept';
}, $one;

subtest 'login link works without mail' => sub {
  my $out = qx{$^X script/glucoglu-admin login 'dev\@b.co' 2>&1};
  ok !$?, 'login exits 0';
  my ($code) = $out =~ m{/auth/([A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5})};
  ok $code, 'prints a login link';
  $t->get_ok("/auth/$code")->status_is(302);
  $t->get_ok('/dashboard')->status_is(200);
}, $one;

subtest 'TSV import (Libre 1 mirror path)' => sub {
  my ($fh, $file) = tempfile(UNLINK => 1, SUFFIX => '.tsv');
  print $fh "Sensorid\tnr\tUnixTime\tYYYY-mm-ddTHH:MM:SS\tTZ\tMin\tmg/dL\n";
  print $fh join("\t", qw(3MH01DZF38H 4 1764253834 2025-11-27T20:00:34 5.5 60 147)), "\n";
  print $fh join("\t", qw(3MH01DZF38H 5 1764254741 2025-11-27T20:15:41 5.5 75 7.8)), "\n";   # mmol/L value
  print $fh join("\t", qw(3MH01DZF38H 6 1764256553 2025-11-27T20:30:47 5.5 90 30)),  "\n";   # between unit ranges
  print $fh join("\t", qw(0M000Y36FAR 7 1792847053 2026-10-24T18:34:13 5.5 1635 244)), "\n";
  close $fh;

  my $out = qx{$^X script/glucoglu-admin import history $file 'imp\@b.co' 2>&1};
  ok !$?, 'import exits 0';
  like $out, qr/imported 3 history readings/, '3 of 4 rows inserted, header skipped';
  is $one->('SELECT count(*) FROM readings'), 3, 'between-range value rejected';
  ok abs($one->('SELECT mg_dl FROM readings WHERE ts = to_timestamp(1764254741)') - 7.8 * 18.018) < 0.01,
    'mmol/L converted to mg/dL';
  is $one->("SELECT source_type FROM readings WHERE ts = to_timestamp(1764253834)"), 'history', 'source_type history';
  is $one->("SELECT raw->>'sensor' FROM readings"), '3MH01DZF38H', 'raw keeps the sensor id';

  $out = qx{$^X script/glucoglu-admin import history $file 'imp\@b.co' 2>&1};
  like $out, qr/imported 0 history readings.*3 duplicates/, 're-run inserts nothing';
  is $one->('SELECT count(*) FROM readings'), 3, 'idempotent';

  $out = qx{$^X script/glucoglu-admin import spot $file 'imp\@b.co' 2>&1};
  like $out, qr/imported 3 spot readings/, 'spot coexists with history at same timestamps';
  is $one->('SELECT count(*) FROM readings'), 6, 'history + spot both stored';
}, $one;

subtest 'unknown command fails' => sub {
  $admin->('bogus');
  ok $?, 'non-zero exit';
  my $out = qx{$^X script/glucoglu-admin 2>&1};
  ok $?, 'no arguments: non-zero exit';
  unlike $out, qr/uninitialized/, 'no warnings without arguments';
  like $out, qr/usage: glucoglu-admin COMMAND/, 'usage shown';
}, $one;

done_testing();