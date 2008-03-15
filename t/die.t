use strict;
use warnings;

use Test::More tests => 1;
use RPC::Async::Client;
use IO::EventMux;

my $mux = new IO::EventMux();

my ($rpc, $pid, $out, $err) = 
    RPC::Async::Client->new($mux, "perl2://./test-server.pl");
$mux->add($out);
$mux->add($err);

my $coderef = sub {
    my (%ans) = @_;
    use Data::Dumper; print Dumper(\%ans);
    fail "Should not be called as the timeout should be reached first";
};

my $id = $rpc->die($coderef);

while (1) {
    my $event = $mux->mux(10);
    eval { $rpc->io($event); };

    if($event->{type} eq 'read' and $event->{fh} eq $err) {
        cmp_ok($event->{data}, "=~", "I DIE at test-server.pl",  
            "The server dies with an error as it should");
        last;
    }
}

$rpc->disconnect;

