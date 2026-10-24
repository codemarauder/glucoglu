package Glucoglu;
use Mojo::Base 'Mojolicious', -signatures;

use Glucoglu::Mailer;
use Mojo::Pg;

has pg => sub ($app) { Mojo::Pg->new($app->config->{db}{dsn}) };

# Swappable in tests with a fake mailer: $app->mailer(Fake->new)
has mailer => sub ($app) { Glucoglu::Mailer->new(%{$app->config->{mail} // {}}) };

sub startup ($self) {
  $self->plugin('Config');
  $self->secrets($self->config->{secrets});
  $self->sessions->secure(1) if $self->mode eq 'production';

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

  my $dash = $r->under('/dashboard')->to('auth#guard');
  $dash->get('/')->to('dashboard#index')->name('dashboard');
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