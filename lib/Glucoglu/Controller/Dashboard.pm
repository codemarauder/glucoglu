package Glucoglu::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($self) {
  my $db    = $self->app->pg->db;
  my $uid   = $self->session('user_id');
  my $token = $db->query('SELECT api_token FROM users WHERE id = ?', $uid)->hash->{api_token};
  my $count = $db->query('SELECT count(*) FROM readings WHERE user_id = ?', $uid)->arrays->[0][0];
  $self->render(token => $token, count => $count);
}

sub regenerate_token ($self) {
  $self->app->pg->db->query('UPDATE users SET api_token = ? WHERE id = ?',
    $self->gen_token, $self->session('user_id'));
  $self->flash(notice => 'Ingest token regenerated. Update Juggluco.');
  $self->redirect_to('dashboard');
}

1;