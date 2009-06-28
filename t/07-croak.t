use strict;
use warnings;
use Carp;

use Test::More tests => 2;
use RPC::Async::Client;
use IO::EventMux;

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
        print "$type($fh)\: '$str'";
    },
);

$rpc->connect("perl2://./test-server.pl",
);

$rpc->exception(
    type => 'croak', 
    side => "CLIENT", 
    msg => 'Croak on client side', 
    sub {
        is($@, "Croak on client side at t/07-croak.t in RPC::Async::Client->exception() line 38\n", 
            "We returned and got timeout as expected");
    }
);

$rpc->exception(
    type => 'die', 
    side => "CLIENT", 
    msg => 'Die on client side', 
    sub {
        is($@, "Die on client side at t/07-croak.t in RPC::Async::Client->exception() line 48\n", 
            "We returned and got timeout as expected");
    }
);

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}
