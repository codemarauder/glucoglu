# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
package Glucoglu::Random;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
our @EXPORT_OK = qw(token);

# No I, O, 0, 1: humans cannot misread them. 32 symbols, so byte % 32 has no bias.
my @ALPHABET = ('A' .. 'H', 'J' .. 'N', 'P' .. 'Z', 2 .. 9);

sub token ($len = 12) {
  open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
  read($fh, my $bytes, $len) == $len or die "urandom: short read";
  return join '', map { $ALPHABET[ord($_) % 32] } split //, $bytes;
}

1;
