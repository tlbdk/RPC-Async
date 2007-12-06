use strict;
use warnings;

use Test::More tests => 1;
use RPC::Async::Client;
use IO::EventMux;
use English;
use Data::Dumper;

pass "Skip for now"; exit;

my $mux = IO::EventMux->new();

# Set the user for the server to run under.
$ENV{'IO_URL_USER'} ||= 'root';

my $rpc = RPC::Async::Client->new($mux, "perl://./test-server.pl") or die;

$rpc->methods(defs => 1, sub {
    my (%ans) = @_;
    print Dumper(\%ans)
    #foreach my $method (keys %{$ans{methods}}) {
    #    print "$method\n";
    #}

});


while ($rpc->has_requests) {
    my $event = $mux->mux;
    $rpc->io($event);
}

$rpc->disconnect;
