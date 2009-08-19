use strict;
use warnings;
use Carp;

use Test::More tests => 2;
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
    EncodeError => 1,
);

$rpc->connect("perl2://./test-server.pl");

my $fh = url_listen("tcp://0.0.0.0:7741");
my ($fh2, $pid, $stdout, $stderr) = url_connect("perl2://./test-server.pl");

eval { $rpc->echo(fh => $fh,
    sub {
        fail("We should not return as we should fail before");
    }
); 
};
like($@, qr/RPC: Cannot pass IO::Socket objects/, "Got an error trying to send a fh");


while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

