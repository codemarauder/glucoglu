# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
package Glucoglu::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use POSIX qw(floor strftime);
use Glucoglu::Metrics qw(agp agp_svg deltas tier1 today_svg tz_offset);

# D10: every read query targets this user — session user, or an owner-granted share.
# The caregiver switcher (step 8) only has to add ?user_id= to the URL.
sub _target ($self) {
  my $uid    = $self->session('user_id');
  my $target = $self->param('user_id') // $uid;
  return undef unless $target =~ /^\d+$/;    # not a user id: not found, never sent to the database
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
  # source_type is needed: the metrics keep one source per 15-min slot (L1).
  my $rows = $db->query(
    'SELECT extract(epoch FROM ts)::bigint AS ts, mg_dl, source_type FROM readings
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

  # Today view (§6): current value and deltas always come from today's readings;
  # only the graph pages back (?day=N), the rest of the card stays on "now".
  my $now      = time;
  my $midnight = floor(($now + $off) / 86400) * 86400 - $off;
  my $today    = $db->query(
    'SELECT extract(epoch FROM ts)::bigint AS ts, mg_dl, source_type FROM readings
       WHERE user_id = ? AND ts >= to_timestamp(?) ORDER BY ts', $target, $midnight
  )->hashes->to_array;

  # Deltas look back 30 min past midnight, so Δ15 still works just after 00:00.
  # The graph keeps $today (midnight onward).
  my $recent = $db->query(
    'SELECT extract(epoch FROM ts)::bigint AS ts, mg_dl FROM readings
       WHERE user_id = ? AND ts >= to_timestamp(?) ORDER BY ts', $target, $midnight - 1800
  )->hashes->to_array;
  my $dlt = @$recent ? deltas($recent, $now) : undef;

  # Last 24 h summary (rolling, now minus 24 h; the graph above starts at midnight).
  # Same rows as the AGP metrics: history and stream, no spot scans.
  my $rows24 = $db->query(
    'SELECT extract(epoch FROM ts)::bigint AS ts, mg_dl, source_type FROM readings
       WHERE user_id = ? AND ts >= to_timestamp(?) AND source_type IN (\'history\', \'stream\')
       ORDER BY ts', $target, $now - 86400
  )->hashes->to_array;
  my $m24 = tier1($rows24, 1);

  my $day  = $self->param('day') // 0;
  $day = 0 unless $day =~ /^\d+$/ && $day <= 90;
  my $dayrows = $day == 0 ? $today : $db->query(
    'SELECT extract(epoch FROM ts)::bigint AS ts, mg_dl, source_type FROM readings
       WHERE user_id = ? AND ts >= to_timestamp(?) AND ts < to_timestamp(?) ORDER BY ts',
    $target, $midnight - $day * 86400, $midnight - $day * 86400 + 86400
  )->hashes->to_array;
  my $today_svg = @$dayrows ? today_svg($dayrows, $off) : '';

  # Traffic-light bands (Battelino 2019 Table 2): target / partial / off-target per metric
  my $grade = sub ($m) {
    return $m->{n} ? (
      tir    => $m->{tir}    > 70   ? 'good' : $m->{tir}    >= 50  ? 'warn' : 'bad',
      tar180 => $m->{tar180} < 25   ? 'good' : $m->{tar180} <= 50  ? 'warn' : 'bad',
      tar250 => $m->{tar250} < 5    ? 'good' : $m->{tar250} <= 10  ? 'warn' : 'bad',
      tbr70  => $m->{tbr70}  < 4    ? 'good' : $m->{tbr70}  <= 10  ? 'warn' : 'bad',
      tbr54  => $m->{tbr54}  < 1    ? 'good' : $m->{tbr54}  <= 2   ? 'warn' : 'bad',
      cv     => $m->{cv}     <= 36   ? 'good' : $m->{cv}     <= 50  ? 'warn' : 'bad',
    ) : ();
  };
  my %grade = $grade->($m);
  my %g24   = $grade->($m24);

  $self->render(
    token        => $user->{api_token},
    count        => $count,
    m            => $m,
    g            => \%grade,
    m24          => $m24,
    g24          => \%g24,
    svg          => $svg,
    days         => $days,
    target       => $target,
    latest       => $latest,
    latest_local => $latest ? strftime('%Y-%m-%d %H:%M', gmtime($latest->{ts} + $off)) : undef,
    dlt          => $dlt,
    today_svg    => $today_svg,
    day          => $day,
    day_label    => strftime('%a %d %b', gmtime($midnight - $day * 86400 + $off)),
  );
}

# Settings: session user only — a caregiver with a shares grant must never see the ingest token.
sub settings ($self) {
  my $uid  = $self->session('user_id');
  my $db   = $self->app->pg->db;
  my $user = $db->query('SELECT api_token FROM users WHERE id = ?', $uid)->hash;
  $self->render(
    token => $user->{api_token},
    count => $db->query('SELECT count(*) FROM readings WHERE user_id = ?', $uid)->arrays->[0][0],
  );
}

sub regenerate_token ($self) {
  $self->app->pg->db->query('UPDATE users SET api_token = ? WHERE id = ?',
    $self->gen_token, $self->session('user_id'));
  $self->flash(notice => 'Ingest token regenerated. Update Juggluco.');
  $self->redirect_to('settings');
}

1;