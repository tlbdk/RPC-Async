#!/usr/bin/env perl -c
use strict;
use warnings;
use Carp;

use lib "lib";

use IO::Handle;
STDOUT->autoflush(1);
STDERR->autoflush(1);

use RPC::Async::Server;
use IO::EventMux;

use English;

my $DEBUG = 1;
my $TRACE = 1;
my $INFO = 1;

my $mux = IO::EventMux->new;
my $rpc = RPC::Async::Server->new( 
    Mux => $mux,
    Timeout => 0,
    DelayedReturn => 1,
);

# FIXME: Implement
$rpc->set_options("rpc_timeout", Timeout => 1); # Return a timeout after 1 second
# FIXME: Implement
$rpc->set_options("rpc_nondelayed", DelayedReturn => 0); # Make normal return, return to client

unlink "server.tmp";

# TODO: Make check all rpc_* that they do not colide with client functions

# Add the filehandle(pipe) that url_connect call created
foreach my $fh (url_clients($rpc)) {
    print "add url_client: $fh\n" if $INFO;
    $mux->add($fh);
    $rpc->add($fh);
}

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    my $fh = ($event->{fh} or '');
    print "srv type($fh): $event->{type}\n" if $DEBUG;
}

my $sleep;
print "sleeping\n" if $sleep;
sleep $sleep if $sleep;

print "All clients quit, so shutting down\n" if $INFO;

sub rpc_timeout {
    my ($caller) = @_;
}

sub rpc_nondelayed {
    my ($caller) = @_;
    return "Now this is what caller gets";
}

sub rpc_retry_croak {
    my ($caller, $timeout) = @_;
    # Schedule retry in $timeout seconds
    $rpc->retry($caller, ($timeout or 1), sub {
        croak("CLIENT: We returned on retry");
    });
}

sub rpc_retry {
    my ($caller, $timeout) = @_;
    # Schedule retry in $timeout seconds
    $rpc->retry($caller, ($timeout or 1), sub {
        $rpc->return($caller, "We returned on retry");
    });
}

# Make it difficult to kill the server and keep stdout and stderr open with
# sleep after shutdown
sub rpc_hardkill {
    $SIG{HUP}  = 'IGNORE';
    $SIG{INT}  = 'IGNORE';
    $SIG{QUIT} = 'IGNORE';
    $SIG{TERM} = 'IGNORE';
    $sleep = 30;
    $rpc->return($_[0]);
}

sub rpc_simple {
    $rpc->return($_[0], 1);
}

# Named parameter with positional information because of name
sub def_add_numbers { $_[1] ? { n1 => 'int', n2 => 'int' } : { sum => 'int' }; }
sub rpc_add_numbers {
    my ($caller, %args) = @_;
    my $sum = $args{n1} + $args{n2};
    print "call to add_numbers\n";
    $rpc->return($caller, sum => $sum);
}

# Named parameter with positional information
sub def_callback { $_[1] ? { calls_01 => 'int', callback_02 => 'sub' } : { }; }
sub rpc_callback {
    my ($caller, %args) = @_;
    my ($count, $callback) = @args{qw(calls callback)};

    $rpc->return($caller, result => 0);

    for (1 .. $count) {
        $callback->call(result => $count);
    }
}

sub rpc_no_return {
    # DO nothing
}

sub rpc_exception {
    my ($caller, %args) = @_;
    
    if($args{type} eq 'croak') {
        print "croak($args{side}): $args{msg}\n";
        croak "$args{side}: $args{msg}";

    } elsif($args{type} eq 'die') {
        print "die($args{side}): $args{msg}\n";
        die "$args{side}: $args{msg}";
    }

    $rpc->return();
}

sub rpc_die {
    my ($caller, %args) = @_;
    sleep(defined $args{sleep} ? $args{sleep} : 1);
    die "Died waiting after sleep";
}

1;
