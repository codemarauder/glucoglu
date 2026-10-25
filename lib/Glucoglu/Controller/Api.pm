package Glucoglu::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON 'encode_json';
use Digest::SHA 'sha1_hex';
use Glucoglu::Units 'to_mgdl';

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
# Fields verified against live Juggluco uploads (O7, 2026-10-24); unreadable bodies land in payload_log.
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
    my $mgdl = to_mgdl($value);    # unit rule D11, sensor-range limits
    if (!defined $mgdl) {
      $self->app->log->warn('rejected reading outside sensor range: ' . substr("$value", 0, 40));
      $rejected++;
      next;
    }
    # epoch is in ms (Nightscout format); UNIQUE (user_id, ts, source_type) dedups overlapping scans.
    # Uploader pushes Bluetooth stream values (Libre 2/2+/3), 1-minute interval (§3).
    $inserted += $db->query(
      'INSERT INTO readings (user_id, ts, mg_dl, source_type, source_interval, raw)
         VALUES (?, to_timestamp(?), ?, \'stream\', 1, ?::jsonb)
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