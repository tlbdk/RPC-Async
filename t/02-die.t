use strict;
use warnings;

use Test::More tests => 3;
use RPC::Async::Client;
use IO::EventMux;

# Might not always work

my $mux = new IO::EventMux();

my $rpc = RPC::Async::Client->new( 
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    CloseOnIdle => 1,
    Output => sub {
        my($fh, $type, $str) = @_;
        if($type eq 'stderr') {
            cmp_ok($str, "=~", "Died waiting after sleep at.*test-server.pl",
                "The server dies with an error as it should");
        }
        print "$type($fh)\: '$str'\n";
    },
    Retries => 0,
);

$rpc->connect("perl2://./test-server.pl");

$rpc->die(sleep => 2, sub {
    is($@, "no more connect retries", "We returned and got timeout as expected");
});

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");
