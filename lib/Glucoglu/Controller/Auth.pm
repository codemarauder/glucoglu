package Glucoglu::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Digest::SHA qw(sha256_hex);

# Codes use the alphabet without I, O, 0, 1 so that humans cannot misread them.
my @ALPHABET = ('A' .. 'H', 'J' .. 'N', 'P' .. 'Z', 2 .. 9);
my $RATE_LIMIT = 5;    # login mails per email address per hour
my $TTL        = '10 minutes';

sub guard ($self) {
  return 1 if $self->session('user_id');
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
    $uid = $db->query('INSERT INTO users (email) VALUES (?) RETURNING id', $email)->arrays->[0][0];
  }

  my $code = _gen_code();
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

sub _gen_code () {
  my $s = join '', map { $ALPHABET[int rand @ALPHABET] } 1 .. 10;
  return substr($s, 0, 5) . '-' . substr($s, 5);
}

1;