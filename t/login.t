use Mojo::Base -signatures;

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
my $t = Test::Mojo->new('Glucoglu');
$t->app->mailer(Glucoglu::Mailer::Fake->new);
my $db = $t->app->pg->db;

$db->query('DELETE FROM mail_log; DELETE FROM login_tokens; DELETE FROM users; DELETE FROM invites');
$db->query("INSERT INTO invites (code) VALUES ('TEST01')");

subtest 'login page' => sub ($t) {
  $t->get_ok('/login')->status_is(200)
    ->content_like(qr{glue for your glucose data from Juggluco})
    ->content_like(qr{name="email"});
}, $t;

subtest 'registration needs an invite' => sub ($t) {
  $t->post_ok('/login' => form => {email => 'a@b.co'})->status_is(200)
    ->content_like(qr{invite code}i);
  $t->post_ok('/login' => form => {email => 'a@b.co', invite => 'WRONG'})->status_is(200)
    ->content_like(qr{not valid}i);
  $t->post_ok('/login' => form => {email => 'a@b.co', invite => 'TEST01'})->status_is(302);
  ok @{$t->app->mailer->codes} == 1, 'one mail sent';
  is $t->app->mailer->codes->[0][0], 'a@b.co', 'mail goes to the right address';
}, $t;

subtest 'link logs in, code is single use' => sub ($t) {
  my $code = $t->app->mailer->codes->[0][1];
  like $code, qr/^[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}$/, 'code format';
  $t->get_ok("/auth/$code")->status_is(302);
  $t->get_ok('/dashboard')->status_is(200)->content_like(qr{Nothing here yet});
  $t->post_ok('/logout')->status_is(302);
  $t->get_ok('/dashboard')->status_is(302);    # back to login
  $t->get_ok("/auth/$code")->status_is(302);  # reuse bounces to login
  $t->get_ok('/dashboard')->status_is(302);
}, $t;

subtest 'typed code works too, expiry is enforced' => sub ($t) {
  $t->post_ok('/login' => form => {email => 'a@b.co'})->status_is(302);    # user exists, no invite needed
  my $code = $t->app->mailer->codes->[-1][1];
  $t->post_ok('/login/check' => form => {code => lc $code})->status_is(302);
  $t->get_ok('/dashboard')->status_is(200);
  $t->post_ok('/logout')->status_is(302);    # the expired-code test needs a logged-out user

  $t->post_ok('/login' => form => {email => 'a@b.co'})->status_is(302);
  my $code2 = $t->app->mailer->codes->[-1][1];
  $db->query("UPDATE login_tokens SET expires_at = now() - interval '1 minute'");
  $t->post_ok('/login/check' => form => {code => $code2})->status_is(302);
  $t->get_ok('/dashboard')->status_is(302);    # expired code does not log in
}, $t;

subtest 'invite is burned, rate limit caps mail' => sub ($t) {
  $t->post_ok('/login' => form => {email => 'x@y.co', invite => 'TEST01'})->status_is(200)
    ->content_like(qr{not valid}i);

  $t->app->mailer->codes([]);
  my $sent = 0;
  for (1 .. 7) {
    $t->post_ok('/login' => form => {email => 'a@b.co'});
    $sent++ if $t->tx->res->code == 302;
  }
  is $sent, 2, 'three mails sent before, two more pass, the rest hit the hourly limit';
  $t->get_ok('/login')->status_is(200);    # page still answers under the limit
}, $t;

done_testing();