use Mojo::Base -strict, -signatures;

use Test::More;
use Glucoglu::Random 'token';

my $alphabet = qr/^[A-HJ-NP-Z2-9]+$/;

is length token(),   12, 'default length is 12';
is length token(8),   8, 'given length';
is length token(30), 30, 'long token';
like token(200), $alphabet, 'only symbols from the 32-symbol alphabet';
isnt token(), token(), 'two calls give different tokens';

my %seen;
$seen{$_}++ for split //, join '', map { token(64) } 1 .. 50;
is scalar(keys %seen), 32, 'all 32 symbols appear';

done_testing;
