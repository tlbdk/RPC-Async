#!/usr/bin/env perl -c
use strict;
use warnings;

use RPC::Async::Server;
use IO::EventMux;

my $mux = IO::EventMux->new;
my $rpc = RPC::Async::Server->new(Mux => $mux);
foreach my $fh (url_clients()) {
    $mux->add($fh);
    $rpc->add($fh);
}

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
}

sub rpc_add_numbers {
    my ($caller, %args) = @_;
    my $sum = $args{n1} + $args{n2};
    $rpc->return($caller, sum => $sum);
}

1;
