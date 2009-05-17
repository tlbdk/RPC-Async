use strict;
use warnings;
use Carp;

use Test::More tests => 2;
use RPC::Async::Client;
use RPC::Async::URL;
use RPC::Async::Util qw(encode_args);
use IO::EventMux;

use Data::Dumper;

# TODO: Make good test to see everything is done in the correct order

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
#    Retries => 1,
);

$rpc->connect("perl2://./test-server.pl",
    Output => sub {
        my($fh, $type, $str) = @_;
        print "$type($fh)\: '$str'";
    }
);

$rpc->hardkill(sub {
    ok(!$@, "Could set the server in hard kill mode");
});

while (my $event = $mux->mux($rpc->timeout())) {
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    next if $rpc->io($event);
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

print Dumper({ 
    dump_requests => $rpc->dump_requests(),
    dump_coderefs => $rpc->dump_coderefs(),
    dump_timeouts => $rpc->dump_timeouts(),
});
print Dumper();

ok(!$rpc->has_work, "Work queue is empty as it should be");

print "close\n";

