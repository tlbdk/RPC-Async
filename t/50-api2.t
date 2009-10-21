use strict;
use warnings;
use Carp;

use Test::More tests => 10;
use RPC::Async::Client;
use RPC::Async::URL;
use RPC::Async::Util qw(encode_args);
use IO::EventMux;

use Data::Dumper;

# Needed when writing to a broken pipe 
$SIG{PIPE} = sub { # SIGPIPE
    croak "Broken pipe";
};

my $mux = IO::EventMux->new();
my $rpc = RPC::Async::Client->new( 
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    CloseOnIdle => 1,
    Retries => 2,
    
    # TODO: Make a Test implementation of an actual algorithm
    RateLimitOnRemove => sub { # Called on remove
        my($self) = @_;
        shift(@{$self->{queue}});
    },
    RateLimitNext => sub {
        my($self) = @_;
        shift(@{$self->{queue}});
    },
    RateLimitAdd => sub {
        my($self, $id) = @_;
        push(@{$self->{queue}}, $id);
    },
);

my $id;

# Start 5 servers and do round robin
foreach(1 .. 1) {
    $rpc->connect("perl2://./test-server.pl",
        Output => sub {
            my($fh, $type, $str) = @_;
            print "$type($fh)\: '$str'";
        }
    );
}

# Try to call an invalid method
$id = $rpc->no_such_method(sub {
    cmp_ok($@, "=~", "No sub 'no_such_method' in package main", 
        "Invalid method call gives error");
});

is($id, 1, "We got the first ID 1");

# Try to call an invalid method
$id = $rpc->add_numbers(n1 => 1, n2 => 1, sub {
    my (%ans) = @_;
    is($ans{sum}, 2, "RPC call worked and sum was correct");
});

is($id, 2, "We got the first ID 2");

# This test should be the last one to test whether has_coderefs works
$id = $rpc->callback(calls => 1, 
    callback => sub {
        my (%ans) = @_;
        is($ans{result}, 1, "callback return");
    }, 
    sub {
        my (%ans) = @_;
        die "$@" if $@;
        is($ans{result}, 0, "normal return");
    }
);

is($id, 3, "We got the first ID 3");

$rpc->set_options('no_return', Timeout => 1);
$rpc->no_return(sub {
    is($@, 'timeout', "got timeout as expected");    
});

$rpc->set_options('die', Timeout => 1);
$rpc->die(sleep => 2, sub {
    is($@, "timeout", "We returned and got timeout as expected");
});

# Enter event loop
print "enter\n";

# TODO: Make min_timeout() sub, to support multiple rpc servers or make it part of EventMux.
while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

print Dumper({ dump_requests => $rpc->dump_requests() });
print Dumper({ dump_coderefs => $rpc->dump_coderefs() });
print "close\n";

