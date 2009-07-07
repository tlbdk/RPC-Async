#!/usr/bin/env perl
use strict;
use warnings;
use Carp;

use RPC::Async::Client;
use IO::EventMux;

# Needed when writing to a broken pipe 
$SIG{PIPE} = sub { # SIGPIPE
    croak "Broken pipe";
};

my $mux = IO::EventMux->new;
my $rpc = RPC::Async::Client->new( 
    Mux => $mux,
    CloseOnIdle => 1,
); 
$rpc->connect("perl2://./server.pl");

$rpc->add_numbers(n1 => 2, n2 => 3,
    sub {
        my %reply = @_;
        print "2 + 3 = $reply{sum}\n";
    });

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
}
