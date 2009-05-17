use strict;
use warnings;
use Carp;

use Test::More tests => 4;
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
);

my ($fh, $pid) = url_connect("perl://./test-server.pl");
$mux->add($fh);
$rpc->add($fh);

$rpc->simple(sub {
    pass("The rpc call returned");
    ok(!$@, "No exception was set");
});

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

# Wait for server to quit
is(waitpid($pid, 0), $pid, "The pid was colleted without any problems");
