use strict;
use warnings;
use Carp;

use Test::More tests => 8;
use RPC::Async::Client;
use RPC::Async::URL;
use RPC::Async::Util qw(encode_args decode_args);
use IO::EventMux;

use Data::Dumper;
my $self = {};

# Test basic stuff
is_deeply(encode_args($self, { test => 1 }), { test => 1 }, "We encode hashes");
is_deeply(encode_args($self, [1,2,3,4]), [1,2,3,4], "We encode arrays");
is_deeply(encode_args($self, \"hello"), \"hello", "We encode refs");
is_deeply(encode_args($self, qr/.*/), RPC::Async::Regexp->new(qr/.*/), "We encode regexp");
is_deeply(encode_args($self, sub{ 1; }), RPC::Async::Coderef->new(1), "We encode coderefs");
is_deeply(encode_args($self, 1), 1, "We encode scalars strings");

my %hash = (
    regexp => qr/test/,
    subref => sub {},
    string => 'hello',
    number => 14,
);

is_deeply(encode_args($self, \%hash), {
    regexp => RPC::Async::Regexp->new(qr/test/),
    subref => RPC::Async::Coderef->new(2),
    string => 'hello',
    number => 14,
}, "We encode anvanced hashes");

$hash{circular} = \%hash;

my $hash2 = encode_args($self, \%hash);

is_deeply($hash2, {
    regexp => RPC::Async::Regexp->new(qr/test/),
    subref => RPC::Async::Coderef->new(3),
    string => 'hello',
    number => 14,
    circular => $hash2,
}, "We encode circular refrences");

