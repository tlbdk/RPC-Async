#!/usr/bin/env perl -c
use strict;
use warnings;

use RPC::Async::Server;
use IO::EventMux;

use English;

my $mux = IO::EventMux->new;
my $rpc = RPC::Async::Server->new($mux);
init_clients($rpc);

while ($rpc->has_clients()) {
    $rpc->io($mux->mux);
}

print "RPC server: all clients gone\n";

sub def_add_numbers { $_[1] ? { n1 => 'int', n2 => 'int' } : { sum => 'int' }; }
sub rpc_add_numbers {
    my ($caller, %args) = @_;
    my $sum = $args{n1} + $args{n2};
    $rpc->return($caller, sum => $sum);
}

sub def_get_id { $_[1] ? { } : { 'uid|gid|euid|egid' => 'int' }; }
sub rpc_get_id {
    my ($caller) = @_;
    $rpc->return($caller, uid => $UID, gid => $GID, 
	    euid => $EUID, egid => $EGID);
}

sub def_callback { $_[1] ? { calls => 'int', callback => 'sub' } : { }; }
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
