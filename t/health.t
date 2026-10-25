use Mojo::Base -strict, -signatures;

use Test::More;
plan skip_all => 'set GLUCOGLU_DB_DSN to run against PostgreSQL' unless $ENV{GLUCOGLU_DB_DSN};

use Test::Mojo;
my $t = Test::Mojo->new('Glucoglu');

$t->get_ok('/health')->status_is(200)->content_is('ok');

# Database gone: 503, so the container health check fails.
$t->app->pg(Mojo::Pg->new('postgresql://nobody:x@127.0.0.1:1/none'));
$t->get_ok('/health')->status_is(503)->content_is('database unreachable');

done_testing;
