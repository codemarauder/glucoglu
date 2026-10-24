package Glucoglu;
use Mojo::Base 'Mojolicious', -signatures;

use Glucoglu::Mailer;
use Mojo::Pg;

# Codes use the alphabet without I, O, 0, 1 so that humans cannot misread them.
my @ALPHABET = ('A' .. 'H', 'J' .. 'N', 'P' .. 'Z', 2 .. 9);

has pg => sub ($app) { Mojo::Pg->new($app->config->{db}{dsn}) };

# Swappable in tests with a fake mailer: $app->mailer(Fake->new)
has mailer => sub ($app) { Glucoglu::Mailer->new(%{$app->config->{mail} // {}}) };

sub startup ($self) {
  $self->plugin('Config');
  $self->secrets($self->config->{secrets});
  $self->sessions->secure(1) if $self->mode eq 'production';

  # 12 chars from the 32-symbol alphabet = 2^60: not brute-forceable online, still typeable on a phone.
  $self->helper(gen_token => sub ($c, $len = 12) {
    join '', map { $ALPHABET[int rand @ALPHABET] } 1 .. $len;
  });

  $self->pg->migrations->from_data->migrate;

  my $r = $self->routes;
  $r->get('/')->to(cb => sub ($c) {
    $c->redirect_to($c->session('user_id') ? 'dashboard' : 'login');
  });
  $r->get('/login')->to('auth#login_form')->name('login');
  $r->post('/login')->to('auth#request');
  $r->get('/login/check')->to('auth#check_form');
  $r->post('/login/check')->to('auth#verify');
  $r->get('/auth/:code')->to('auth#verify');
  $r->post('/logout')->to('auth#logout');
  $r->post('/api/v1/entries')->to('api#entries');
  $r->post('/api/v3/entries')->to('api#entries');
  $r->get('/api/v2/authorization/request/:token')->to('api#auth_request');

  my $dash = $r->under('/dashboard')->to('auth#guard');
  $dash->get('/')->to('dashboard#index')->name('dashboard');
  $dash->post('/token')->to('dashboard#regenerate_token');
}

1;
__DATA__
@@ migrations
-- 1 up
CREATE TABLE invites (
  code       text PRIMARY KEY,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE users (
  id         serial PRIMARY KEY,
  email      text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE login_tokens (
  code       text PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE mail_log (
  id         bigserial PRIMARY KEY,
  email      text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX mail_log_email_idx ON mail_log (email, created_at);
-- 1 down
DROP TABLE mail_log, login_tokens, users, invites;
-- 2 up
ALTER TABLE users ADD COLUMN api_token text UNIQUE;
UPDATE users SET api_token = substr(md5(random()::text), 1, 20) WHERE api_token IS NULL;
CREATE TABLE readings (
  id              bigserial PRIMARY KEY,
  user_id         integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts              timestamptz NOT NULL,
  mg_dl           real NOT NULL,
  -- shortcut: one fixed source type until the real-payload check (O7) confirms Juggluco's fields
  source_type     text NOT NULL DEFAULT 'sensor',
  source_interval integer NOT NULL DEFAULT 15,
  raw             jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, ts, source_type)
);
CREATE INDEX readings_user_ts_idx ON readings (user_id, ts);
-- Bodies the parser could not read land here until the Juggluco field names are confirmed (O7).
CREATE TABLE payload_log (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  raw        jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- 2 down
DROP TABLE payload_log, readings;
ALTER TABLE users DROP COLUMN api_token;