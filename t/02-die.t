use strict;
use warnings;

use Test::More tests => 5;
use RPC::Async::Client;
use IO::EventMux;

# Might not always work

my $mux = new IO::EventMux();

use Log::Sensible;
#Log::Sensible::level('trace');

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
    OnRestart => sub {
        my($trying, $reason) = @_;
        if($trying) {
            cmp_ok($reason, "=~", "fh is closing",
                "We try restarting");
        } else {
            cmp_ok($reason, "=~", "no more retries",
                "We fail restarting because no more retries");
        }
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
