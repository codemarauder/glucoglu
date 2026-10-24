package Glucoglu::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use POSIX qw(strftime);
use Glucoglu::Metrics qw(agp agp_svg tier1 tz_offset);

# D10: every read query targets this user — session user, or an owner-granted share.
# The caregiver switcher (step 8) only has to add ?user_id= to the URL.
sub _target ($self) {
  my $uid    = $self->session('user_id');
  my $target = $self->param('user_id') // $uid;
  return $target if $target == $uid;
  return $target
    if $self->app->pg->db->query('SELECT 1 FROM shares WHERE owner_id = ? AND viewer_id = ?', $target, $uid)->array;
  return undef;    # no grant: pretend the page does not exist
}

sub index ($self) {
  my $target = $self->_target;
  return $self->reply->not_found unless defined $target;

  my $days = $self->param('days') // 14;
  $days = 14 unless $days =~ /^(7|14|30|90)$/;    # O2: default 14, options 7/30/90

  my $db = $self->app->pg->db;
  my $user = $db->query('SELECT api_token, tz FROM users WHERE id = ?', $target)->hash;

  # Standard metrics run on the periodic curve (history/stream). Spot values are
  # scan-biased (you scan when you feel off) and would skew TIR; they still show as "latest".
  my $rows = $db->query(
    'SELECT extract(epoch FROM ts)::bigint AS ts, mg_dl FROM readings
       WHERE user_id = ? AND ts >= to_timestamp(?) AND source_type IN (\'history\', \'stream\')
       ORDER BY ts', $target, time - $days * 86400
  )->hashes->to_array;
  my $count  = $db->query('SELECT count(*) FROM readings WHERE user_id = ?', $target)->arrays->[0][0];
  my $latest = $db->query(
    'SELECT mg_dl, extract(epoch FROM ts)::bigint AS ts FROM readings WHERE user_id = ? ORDER BY ts DESC LIMIT 1',
    $target)->hash;

  my $m   = tier1($rows, $days);
  my $off = tz_offset($user->{tz});
  my $svg = @$rows ? agp_svg(agp($rows, $off)) : '';

  $self->render(
    token        => $user->{api_token},
    count        => $count,
    m            => $m,
    svg          => $svg,
    days         => $days,
    target       => $target,
    latest       => $latest,
    latest_local => $latest ? strftime('%Y-%m-%d %H:%M', gmtime($latest->{ts} + $off)) : undef,
  );
}

sub regenerate_token ($self) {
  $self->app->pg->db->query('UPDATE users SET api_token = ? WHERE id = ?',
    $self->gen_token, $self->session('user_id'));
  $self->flash(notice => 'Ingest token regenerated. Update Juggluco.');
  $self->redirect_to('dashboard');
}

1;