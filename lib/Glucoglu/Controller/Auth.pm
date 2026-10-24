package Glucoglu::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Digest::SHA qw(sha256_hex);

my $RATE_LIMIT = 5;    # login mails per email address per hour
my $TTL        = '10 minutes';

sub guard ($self) {
  my $uid = $self->session('user_id');
  if ($uid) {
    # A session can outlive its user (admin delete, DB wipe): log it out, never 500.
    return 1
      if $self->app->pg->db->query('SELECT 1 FROM users WHERE id = ?', $uid)->arrays->[0][0];
    $self->session(expires => 1);
  }
  $self->redirect_to('login');
  return 0;
}

sub login_form ($self) { $self->render('auth/login') }

sub request ($self) {
  my $email = lc($self->param('email') // '');
  $email =~ s/^\s+|\s+$//g;
  my $invite = uc($self->param('invite') // '');
  $invite =~ s/\s+//g;

  # shortcut: simple email regex; the real check is the code that reaches the mailbox.
  return $self->render('auth/login', error => 'Enter a valid email address.')
    unless $email =~ /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

  my $db = $self->app->pg->db;

  my $sent = $db->query(
    "SELECT count(*) FROM mail_log WHERE email = ? AND created_at > now() - interval '1 hour'",
    $email
  )->arrays->[0][0] // 0;
  return $self->render('auth/login', error => 'Too many attempts. Try again in an hour.')
    if $sent >= $RATE_LIMIT;

  # ->arrays->[0][0] is undef when there is no row; ->array->[0] would die on an empty result
  my $uid = $db->query('SELECT id FROM users WHERE email = ?', $email)->arrays->[0][0];
  if (!$uid) {
    return $self->render('auth/login', error => 'Enter an invite code. It is needed on first login only.')
      unless length $invite;
    my $used = $db->query(
      'UPDATE invites SET used_at = now() WHERE code = ? AND used_at IS NULL RETURNING code',
      $invite
    )->array;
    return $self->render('auth/login', error => 'That invite code is not valid.') unless $used;
    $uid = $db->query('INSERT INTO users (email, api_token) VALUES (?, ?) RETURNING id',
      $email, $self->gen_token)->arrays->[0][0];
  }

  my $code = $self->_gen_code;
  my $norm = $code =~ s/-//gr;    # verify strips separators; hash the same normalized form
  my $url  = $self->app->config->{base_url} . "/auth/" . $code;
  $db->query(
    "INSERT INTO login_tokens (code, user_id, expires_at) VALUES (?, ?, now() + interval '$TTL')",
    sha256_hex($norm), $uid
  );

  my $sent_ok = $self->app->mailer->send_login($email, $code, $url);
  return $self->render('auth/login', error => 'The mail could not be sent. Please try again.')
    unless $sent_ok;

  $db->insert('mail_log', {email => $email});
  $self->flash(sent_to => $email);
  $self->redirect_to('/login/check');
}

sub check_form ($self) { $self->render('auth/check') }

sub verify ($self) {
  my $in = uc $self->param('code') // '';
  $in =~ s/[^A-Z2-9]//g;    # strip dashes, spaces, anything the user pasted around the code

  # The UPDATE is the lock: only one request can mark the token used.
  my $user = $self->app->pg->db->query(
    'UPDATE login_tokens SET used_at = now()
       WHERE code = ? AND used_at IS NULL AND expires_at > now()
       RETURNING user_id', sha256_hex($in)
  )->hash;

  if (!$user) {
    $self->flash(error => 'That code is not valid. Get a new one.');
    return $self->redirect_to('login');
  }
  $self->session(user_id => $user->{user_id});
  $self->session(expiration => 30 * 86400);
  $self->redirect_to('dashboard');
}

sub logout ($self) {
  $self->session(expires => 1);
  $self->redirect_to('login');
}

sub _gen_code ($self) {
  my $s = $self->gen_token(10);
  return substr($s, 0, 5) . '-' . substr($s, 5);
}

1;