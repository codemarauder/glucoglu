use Mojo::Base -strict, -signatures;

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

subtest 'unknown command fails' => sub {
  $admin->('bogus');
  ok $?, 'non-zero exit';
}, $one;

done_testing();