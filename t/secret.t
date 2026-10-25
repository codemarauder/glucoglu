use Mojo::Base -strict, -signatures;

use Test::More;
use File::Temp;

# Start the app in a child process with a given mode and secret setting.
# Returns the exit status and the output.
my $script = File::Temp->new(SUFFIX => '.pl');
print $script q{use Mojo::Base -strict; use Mojo::Server; Mojo::Server->new->build_app('Glucoglu'); print "started\n";};
close $script;
my $out_file = File::Temp->new;

sub start_app ($mode, $secret) {
  local $ENV{MOJO_MODE}       = $mode;
  local $ENV{GLUCOGLU_SECRET} = $secret;    # undef removes the variable
  system("$^X -Ilib $script > $out_file 2>&1");
  my $status = $? >> 8;
  seek $out_file, 0, 0;
  my $out = do { local $/; <$out_file> } // '';
  truncate $out_file, 0;
  return ($status, $out);
}

subtest 'production without GLUCOGLU_SECRET refuses to start' => sub {
  my ($status, $out) = start_app('production', undef);
  isnt $status, 0, 'exit status is non-zero';
  like $out, qr/GLUCOGLU_SECRET is not set/, 'says which variable is missing';
  unlike $out, qr/started/, 'app did not start';
};

SKIP: {
  skip 'set GLUCOGLU_DB_DSN to run the start-up cases', 2 unless $ENV{GLUCOGLU_DB_DSN};

  subtest 'production with GLUCOGLU_SECRET starts' => sub {
    my ($status, $out) = start_app('production', 'test-secret');
    is $status, 0, 'exit status is zero';
    like $out, qr/started/, 'app started';
  };

  subtest 'development without GLUCOGLU_SECRET still starts' => sub {
    my ($status, $out) = start_app('development', undef);
    is $status, 0, 'exit status is zero';
    like $out, qr/started/, 'app started';
  };
}

done_testing;
