package Glucoglu::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# Empty in step 1. Tier 1 metrics + AGP land in build step 4.
sub index ($self) { $self->render('dashboard/index') }

1;