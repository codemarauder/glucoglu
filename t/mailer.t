# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
use Mojo::Base -strict, -signatures;

use Test::More;
use Glucoglu::Mailer;

my $m = Glucoglu::Mailer->new(from => 'glucoglu@example.org');
like $m->message_id, qr/^<\d+\.[A-HJ-NP-Z2-9]{8}\@example\.org>$/, 'TIME.TOKEN@DOMAIN from the From address';
isnt $m->message_id, $m->message_id, 'each mail gets a new id';

my $named = Glucoglu::Mailer->new(from => 'Glucoglu <noreply@mail.example.com>');
like $named->message_id, qr/\@mail\.example\.com>$/, 'domain taken from a "Name <addr>" From';

my $bare = Glucoglu::Mailer->new(from => 'nodomain');
like $bare->message_id, qr/\@localhost>$/, 'no domain: falls back to localhost';

done_testing;
