package Glucoglu::Units;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Scalar::Util 'looks_like_number';
our @EXPORT_OK = qw(to_mgdl);

# D11: sensor range 40-500 mg/dL = 2.2-27.8 mmol/L. Outside both ranges: reject.
sub to_mgdl ($v) {
  return undef unless defined $v && looks_like_number($v);
  return $v * 18.018 if $v >= 2.2 && $v <= 27.8;
  return $v          if $v >= 40  && $v <= 500;
  return undef;
}

1;
