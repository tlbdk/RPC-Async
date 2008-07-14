use strict;
use warnings;

use Test::More tests => 2;
use RPC::Async::Client;
use IO::EventMux;
use Data::Dumper;

my $mux = new IO::EventMux();

my ($rpc) = RPC::Async::Client->new($mux, "perl://./test-server.pl");

my $queued = 0;
my $notqueued = 0;
my $count = 0;

foreach(1..200) {
    $rpc->sleep(count => $count, sub {
        my (%ans) = @_;
        if($ans{queued}) {
            $queued++;
        } else {
            $notqueued++;
        }
    });
}

while ($rpc->has_requests) {
    my $event = $mux->mux(10);
    $rpc->io($event);
}

is($queued, 100, "The number of request that was queued should be 10");
is($notqueued, 100, "The number of request that did not get queued should be 10");

$rpc->disconnect;

