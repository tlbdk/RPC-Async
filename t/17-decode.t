use strict;
use warnings;
use Carp;

use Test::More tests => 8;
use RPC::Async::Client;
use RPC::Async::URL;
use RPC::Async::Util qw(decode_args decode_args);
use IO::EventMux;

use Data::Dumper;
my $self = {};
my $fh = {};

my $coderef = RPC::Async::Coderef->new(1);

# Test basic stuff
is_deeply(decode_args($self, $fh, { test => 1 }), { test => 1 }, "We decode hashes");
is_deeply(decode_args($self, $fh, [1,2,3,4]), [1,2,3,4], "We decode arrays");
is_deeply(decode_args($self, $fh, \"hello"), \"hello", "We decode refs");
is_deeply(decode_args($self, $fh, RPC::Async::Regexp->new(qr/.*/)), qr/.*/, "We decode regexp");
is_deeply(decode_args($self, $fh, $coderef), $coderef, "We decode coderefs");
is_deeply(decode_args($self, $fh, 1), 1, "We decode scalars strings");

my %hash = (
    regexp => RPC::Async::Regexp->new(qr/test/),
    subref => $coderef,
    string => 'hello',
    number => 14,
);

is_deeply(decode_args($self, $fh, \%hash), {
    regexp => qr/test/,
    subref => $coderef,
    string => 'hello',
    number => 14,
}, "We decode anvanced hashes");

$hash{circular} = \%hash;

my $hash2 = decode_args($self, $fh, \%hash);

is_deeply($hash2, {
    regexp => qr/test/,
    subref => $coderef,
    string => 'hello',
    number => 14,
    circular => $hash2,
}, "We decode circular refrences");

