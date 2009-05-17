use strict;
use warnings;

use Test::More tests => 3;
use RPC::Async::Client;
use IO::EventMux;

plan skip_all => "Currently a developer-only test" if !$ENV{TEST_AUTHOR};

my $mux = IO::EventMux->new();
my $rpc = RPC::Async::Client->new( 
    Mux => $mux,
    CloseOnIdle => 1,
);

$rpc->connect("perl2://./test-server.pl");

my $callback = sub { 
    ok(!$@, "Call returned without error");
    die "$@" if $@;
};

my $id1 = $rpc->simple(arg1 => 1, $callback);
is_deeply($rpc->dump_requests(), { $id1 => { 
    callback => $callback,
    procedure => 'simple',
    args => [arg1 => 1],
}}, "dump_requests returned a structure we expected");

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");
