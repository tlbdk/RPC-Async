use strict;
use warnings;

use Test::More tests => 1;
use RPC::Async::Client;
use IO::EventMux;

my $mux = IO::EventMux->new();

my $rpc = RPC::Async::Client->new($mux, "perl://./test-server.pl") or die;

my $coderef = sub {
    my (%ans) = @_;
    use Data::Dumper; print Dumper(\%ans);
    fail "Should not be called as the timeout should be reached first";
};

my $id = $rpc->hang($coderef);

while ($rpc->has_requests) {
    my $event = $mux->mux(0);
    $rpc->io($event);

    if($event->{type} eq 'timeout') {
        is_deeply($rpc->dump_requests() , { $id => { 
            callback => $coderef,
            procedure => 'hang',
            args => [],
        }}, "hang() was the one left in requests");
        last;
    }
}

$rpc->disconnect;

