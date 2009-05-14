#!/usr/bin/env perl
use strict;
use warnings;
use Carp;

# Old RPC::Rsync

use lib "lib";

use RPC::Async::Client;
use RPC::Async::URL;
use IO::EventMux;

use Time::HiRes qw(tv_interval gettimeofday);
use List::Util qw(sum max min);

use Data::Dumper;

my $DEBUG = 0;
my $TRACE = 0;

# Needed when writing to a broken pipe 
$SIG{PIPE} = sub { # SIGPIPE
    croak "Broken pipe";
};

my $mux = IO::EventMux->new();

#while(1) {
    benchmark_stat(3, 10000, $mux, 1, Timeout => 3, Retries => 0);
#}

sub benchmark_stat {
    my ($runs, $requests, @args) = @_;
    
    my @results;
    foreach my $run (1 .. $runs) {
        my $time = benchmark($requests, @args);
        push(@results, $time);
        print "$run\: $time\n";
    }

    my $max = max(@results);
    my $min = min(@results);
    my $avg = sum(@results) / $runs;

    my $req_max = $requests / $max;
    my $req_min = $requests / $min;
    my $req_avg = $requests / $avg;

    print "\n";
    print "Max Time: $max, Requests/sec: $req_max\n";
    print "Min Time: $min, Requests/sec: $req_min\n";
    print "Avg Time: $avg, Requests/sec: $req_avg\n";
}

sub benchmark {
    my ($requests, $mux, $servers, %options) = @_;
    
    print "Starting 1 server\n" if $DEBUG;
    my $rpc = RPC::Async::Client->new($mux, "perl://./test-server.pl") or die;

    my $t0 = [gettimeofday];
    my $elapsed; 
    my $count = 0;
    foreach (1 .. $requests) {
        # Try to call an invalid method
        $rpc->simple(sub {
            die "Simple returned errro: $@" if $@;
            if(++$count >= $requests) {
                $elapsed = tv_interval($t0);
            }
        });
    }

    while ($rpc->has_requests || $rpc->has_coderefs) {
        my $event = $mux->mux();
        print "$event->{type}\n" if $TRACE;
        $rpc->io($event);
    }
    
    $rpc->disconnect();
    return $elapsed;
}

