use strict;
use warnings;
use Carp;

use Test::More tests => 3;
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
    WaitPidTimeout => 0,
);

$rpc->connect("perl2://./test-server.pl");

$rpc->set_meta("Value from client", sub {
    print "$@\n";
    ok(!$@, "We did not get an exception");
});

$rpc->get_meta(sub {
    is($_[0], "Value from client", "We got our value back");
});

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

