package Glucoglu::Mailer;
use Mojo::Base -base, -signatures;

use Net::SMTP;
use POSIX qw(strftime);

has [qw(host port user pass from)];

# SMTP relay. Port 465 speaks TLS from the start; 25/587 use STARTTLS.
# shortcut: LF line endings instead of CRLF; our relay accepts them. Upgrade if we ever hit a strict relay.
sub send_login ($self, $email, $code, $url) {
  my $port = $self->port // 587;
  my $smtp = $port == 465
    ? Net::SMTP->new(Host => $self->host, Port => $port, SSL => 1, Timeout => 15)
    : Net::SMTP->new(Host => $self->host, Port => $port, Timeout => 15);
  return undef unless $smtp;
  return undef if $port != 465 && !$smtp->starttls;
  if (length($self->user // '')) { $smtp->auth($self->user, $self->pass) or return undef }
  $smtp->mail($self->from) or return undef;
  $smtp->to($email)        or return undef;
  $smtp->data;
  $smtp->datasend( join "\n",
    "From: Glucoglu <@{[$self->from]}>",
    "To: $email",
    "Subject: Your Glucoglu login code",
    "Date: " . strftime('%a, %d %b %Y %H:%M:%S %z', localtime),
    "Content-Type: text/plain; charset=UTF-8",
    "",
    "Open this link to log in:",
    $url,
    "",
    "Or type this code into the login page:",
    $code,
    "",
    "The link and the code stop working in 10 minutes.",
  );
  my $ok = $smtp->dataend;
  $smtp->quit;
  return $ok;
}

1;