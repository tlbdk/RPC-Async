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
    FilterArguments => 1,
);

$rpc->connect("perl2://./test-server.pl");

my $fh = url_listen("tcp://0.0.0.0:7741");
my ($fh2, $pid, $stdout, $stderr) = url_connect("perl2://./test-server.pl");

$rpc->echo(fh => $fh, fh2 => $fh2, stderr => $stderr, stdout => $stdout,
    sub {
        my %args = @_;
        ok(!$@, "No exception was set");
        is_deeply(\%args, {
            fh => "could not encode IO::Socket", 
            fh2 => "could not encode GLOB", 
            stderr => "could not encode GLOB", 
            stdout => "could not encode GLOB", 
        });
    }
);

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

