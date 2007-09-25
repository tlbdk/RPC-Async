#!/usr/bin/env perl -c
use strict;
use warnings;

use RPC::Async::Server;
use base "RPC_Async_Test";
use IO::EventMux;

use English;

my $mux = IO::EventMux->new;
my $rpc = RPC::Async::Server->new($mux);
init_clients($rpc);

while ($rpc->has_clients()) {
    $rpc->io($mux->mux);
}

print "RPC server: all clients gone\n";

sub rpc_add_numbers {
    my ($caller, %args) = @_;
    my $sum = $args{n1} + $args{n2};
    $rpc->return($caller, sum => $sum);
}

sub rpc_get_id {
    my ($caller) = @_;
    $rpc->return($caller, uid => $UID, gid => $GID, 
	    euid => $EUID, egid => $EGID);
}

sub rpc_callback {
    my ($caller, %args) = @_;
    my ($count, $wrap) = @args{qw(calls callback)};
    my $callback = ${$wrap->{key}[0]};

    $rpc->return($caller);

    for (1 .. $count) {
        $callback->call($count);
    }
}

1;
