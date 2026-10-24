package Glucoglu::Controller::API;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON 'encode_json';

# Unit rule (D11): <=27.8 is mmol/L, >=40 is mg/dL. Between is impossible in both ranges.
my $MMOL_MAX  = 27.8;
my $MGDL_MIN  = 40;
my $MMOL_CONV = 18.018;

# POST /api/v1/entries — Juggluco pushes Nightscout-style JSON here:
#   [{"type":"sgv","date":<epoch ms>,"sgv":<value>}, ...]   (single object also accepted)
# shortcut: only the "sgv" and "date" fields are parsed until the real-payload check (O7)
# confirms Juggluco's exact fields; unreadable bodies are kept in payload_log meanwhile.
sub entries ($self) {
  my ($bearer) = ($self->req->headers->authorization // '') =~ /^Bearer\s+(\S+)$/i;
  my $token    = $self->param('token') // $bearer // '';
  return $self->render(json => {error => 'invalid token'}, status => 401) unless length $token;

  my $db  = $self->app->pg->db;
  my $uid = $db->query('SELECT id FROM users WHERE api_token = ?', $token)->arrays->[0][0];
  return $self->render(json => {error => 'invalid token'}, status => 401) unless $uid;

  my $json = $self->req->json;
  return $self->render(json => {error => 'invalid JSON body'}, status => 400) unless defined $json;

  my @items = ref $json eq 'ARRAY' ? @$json : ref $json eq 'HASH' ? ($json) : ();
  my ($inserted, $rejected) = (0, 0);
  for my $item (@items) {
    next unless ref $item eq 'HASH';
    my ($value, $ts) = ($item->{sgv}, $item->{date});
    if (!defined $value || !defined $ts || $ts !~ /^\d+$/) {
      $rejected++;
      next;
    }
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

  # O7: keep bodies that produced nothing, so the real field names can be confirmed before schema freeze
  $db->query('INSERT INTO payload_log (user_id, raw) VALUES (?, ?::jsonb)', $uid, encode_json($json))
    if !$inserted;

  $self->render(json => {inserted => $inserted, rejected => $rejected});
}

1;