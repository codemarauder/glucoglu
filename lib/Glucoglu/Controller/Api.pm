package Glucoglu::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON 'encode_json';
use Digest::SHA 'sha1_hex';

# Unit rule (D11): <=27.8 is mmol/L, >=40 is mg/dL. Between is impossible in both ranges.
my $MMOL_MAX  = 27.8;
my $MGDL_MIN  = 40;
my $MMOL_CONV = 18.018;

# Resolve the ingest user: ?token= query, Authorization: Bearer (Nightscout V3),
# or api-secret: sha1(token) header (Nightscout V1 — Juggluco's default mode).
sub _uid ($self, $db) {
  my ($bearer) = ($self->req->headers->authorization // '') =~ /^Bearer\s+(\S+)$/i;
  my $token    = $self->param('token') // $bearer // '';
  return $db->query('SELECT id FROM users WHERE api_token = ?', $token)->arrays->[0][0]
    if length $token;
  my $secret = lc($self->req->headers->header('api-secret') // '');
  return undef unless length $secret;
  # shortcut: linear scan is fine for invite-scale instances, index a secret column past a few hundred users
  for my $row (@{$db->query('SELECT id, api_token FROM users')->arrays}) {
    return $row->[0] if sha1_hex($row->[1]) eq $secret;
  }
  return undef;
}

# Nightscout V3 handshake (Juggluco "test V3"): GET /api/v2/authorization/request/<secret>
# must answer {"token": ..., "exp": <unix seconds>}. We return the ingest token itself,
# so the existing Bearer check in entries() accepts what Juggluco sends afterwards.
sub auth_request ($self) {
  my $token = $self->stash('token');
  my $uid   = $self->app->pg->db->query('SELECT id FROM users WHERE api_token = ?', $token)->arrays->[0][0];
  return $self->render(json => {error => 'invalid token'}, status => 401) unless $uid;
  $self->render(json => {token => $token, exp => time + 8 * 3600});
}

# POST /api/v1/entries — Juggluco pushes Nightscout-style JSON here:
#   [{"type":"sgv","date":<epoch ms>,"sgv":<value>}, ...]   (single object also accepted)
# shortcut: only the "sgv" and "date" fields are parsed until the real-payload check (O7)
# confirms Juggluco's exact fields; unreadable bodies are kept in payload_log meanwhile.
sub entries ($self) {
  my $db  = $self->app->pg->db;
  my $uid = $self->_uid($db);
  return $self->render(json => {error => 'invalid token'}, status => 401) unless $uid;

  my $json = $self->req->json;
  return $self->render(json => {error => 'invalid JSON body'}, status => 400) unless defined $json;

  my @items = ref $json eq 'ARRAY' ? @$json : ref $json eq 'HASH' ? ($json) : ();
  my ($inserted, $rejected, $parsed, $from, $to) = (0, 0, 0, undef, undef);
  for my $item (@items) {
    next unless ref $item eq 'HASH';
    my ($value, $ts) = ($item->{sgv}, $item->{date});
    if (!defined $value || !defined $ts || $ts !~ /^\d+$/) {
      $rejected++;
      next;
    }
    $parsed++;
    $from = $ts if !defined $from || $ts < $from;
    $to   = $ts if !defined $to   || $ts > $to;
    my $mgdl = $value <= $MMOL_MAX ? $value * $MMOL_CONV
              : $value >= $MGDL_MIN ? $value
              : undef;
    if (!defined $mgdl) {
      $self->app->log->warn("rejected reading between unit ranges: $value");
      $rejected++;
      next;
    }
    # epoch is in ms (Nightscout format); UNIQUE (user_id, ts, source_type) dedups overlapping scans
    $inserted += $db->query(
      'INSERT INTO readings (user_id, ts, mg_dl, raw) VALUES (?, to_timestamp(?), ?, ?::jsonb)
         ON CONFLICT (user_id, ts, source_type) DO NOTHING',
      $uid, $ts / 1000, $mgdl, encode_json($item)
    )->rows;
  }

  # O7: keep bodies we could not read at all, so the real field names can be confirmed before schema freeze.
  # Dedup conflicts and understood-but-rejected values are not captured; they are normal traffic.
  $db->query('INSERT INTO payload_log (user_id, raw) VALUES (?, ?::jsonb)', $uid, encode_json($json))
    if !$parsed;

  $self->app->log->info(sprintf 'ingest uid=%s items=%d inserted=%d rejected=%d from=%s to=%s',
    $uid, scalar @items, $inserted, $rejected,
    defined($from) ? scalar(gmtime $from / 1000) : '-', defined($to) ? scalar(gmtime $to / 1000) : '-');
  $self->render(json => {inserted => $inserted, rejected => $rejected});
}

1;