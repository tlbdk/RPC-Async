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

$rpc->retry(sub {
    ok(!$@, "No exception was set");
    is($_[0], 'We returned on retry', "The retry returned without timeout");
});

while (my $event = $mux->mux($rpc->timeout())) {
    # TODO: Check that we don't eat timeout type events
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

