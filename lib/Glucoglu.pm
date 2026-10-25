package Glucoglu;
use Mojo::Base 'Mojolicious', -signatures;

use Glucoglu::Mailer;
use Glucoglu::Random ();
use Mojo::Pg;

has pg => sub ($app) { Mojo::Pg->new($app->config->{db}{dsn}) };

# Swappable in tests with a fake mailer: $app->mailer(Fake->new)
has mailer => sub ($app) { Glucoglu::Mailer->new(%{$app->config->{mail} // {}}) };

sub startup ($self) {
  $self->plugin('Config');
  $self->secrets($self->config->{secrets});
  $self->sessions->secure(1) if $self->mode eq 'production';

  # 12 chars from the 32-symbol alphabet = 2^60: not brute-forceable online, still typeable on a phone.
  $self->helper(gen_token => sub ($c, $len = 12) {
    Glucoglu::Random::token($len);
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
  $dash->get('/settings')->to('dashboard#settings')->name('settings');
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
-- 3 up
-- Schema freeze (build step 3). New columns and tables only; changes go into later migrations.
ALTER TABLE users ADD COLUMN tz   text NOT NULL DEFAULT 'UTC';        -- per-user time zone, set at registration (D13)
ALTER TABLE users ADD COLUMN unit text NOT NULL DEFAULT 'mgdl' CHECK (unit IN ('mgdl','mmol'));  -- display unit only; storage is always mg/dL (D11)
ALTER TABLE users ADD COLUMN tier text NOT NULL DEFAULT 'free';      -- billing stub (§9), no payment processing in v1
ALTER TABLE readings ALTER COLUMN source_type SET DEFAULT 'stream';
CREATE TABLE meals (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts         timestamptz NOT NULL,
  carbs      real,
  note       text,
  source     text NOT NULL DEFAULT 'pwa',    -- pwa | juggluco amount
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, ts)
);
CREATE TABLE insulin (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts         timestamptz NOT NULL,
  units      real NOT NULL CHECK (units > 0),
  kind       text NOT NULL CHECK (kind IN ('rapid','long')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, ts, kind)
);
-- shortcut: IOB may stay empty in v1 (computable from insulin doses); the table exists for received/computed values
CREATE TABLE iob (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts         timestamptz NOT NULL,
  units      real NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, ts)
);
CREATE TABLE exercise (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts         timestamptz NOT NULL,
  minutes    real,
  note       text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, ts)
);
CREATE TABLE notes (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts         timestamptz NOT NULL,
  body       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notes_user_ts_idx ON notes (user_id, ts);
-- Lab A1c: entry accepts % (DCCT) or mmol/mol (IFCC); stored as % (app converts before insert)
CREATE TABLE lab_a1c (
  id         bigserial PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts         timestamptz NOT NULL,
  percent    real NOT NULL CHECK (percent BETWEEN 3 AND 20),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, ts)
);
-- Caregiver sharing, read-only (D10): every read query checks session = target or a grant exists here
CREATE TABLE shares (
  owner_id   integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  viewer_id  integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, viewer_id),
  CHECK (owner_id <> viewer_id)
);
-- 3 down
DROP TABLE shares, lab_a1c, notes, exercise, iob, insulin, meals;
ALTER TABLE users DROP COLUMN tz, DROP COLUMN unit, DROP COLUMN tier;