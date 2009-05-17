use strict;
use warnings;

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
    }
);

$rpc->connect("perl2://./test-server.pl",
);

$rpc->set_options('die', Timeout => 1);
$rpc->die(sleep => 2, sub {
    is($@, "timeout", "We returned and got timeout as expected");
});

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}
