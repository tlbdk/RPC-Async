use strict;
use warnings;
use Carp;

use Test::More tests => 5;
use RPC::Async::Client;
use IO::EventMux;
use RPC::Async::URL;

# Needed when writing to a broken pipe 
$SIG{PIPE} = sub { # SIGPIPE
    croak "Broken pipe";
};

my $mux = new IO::EventMux();

my $rpc = RPC::Async::Client->new( 
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    CloseOnIdle => 1,
    Retries => 0,
);

$rpc->connect("perl2://./test-server.pl");

my $rpc2 = RPC::Async::Client->new( 
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    Output => sub {
        my($fh, $type, $str) = @_;
        like($str, qr/Can't locate DIEDIEDIE.pm/, "The server dies with an error as it should");
    },
);

my $cfd_rpc = q|
use warnings;
use strict;

use FindBin;
BEGIN { chdir $FindBin::Bin }

use RPC::Async::URL;
use RPC::Async::Server;
use Sys::Prctl qw(prctl_name);
use IO::Handle;

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $fd = shift;
my $module = shift;
if (not defined $fd) { die "Usage: $0 FILE_DESCRIPTOR MODULE_FILE [ ARGS ]"; }

open my $sock, "+<&=", $fd or die "Cannot open fd $fd\n";

sub url_clients {
    my ($rpc) = @_;
    my $listen = url_listen("unix://./socks/test-server.sock");
    return ($sock, $listen);
}

$0="$module";
prctl_name($module);

use DIEDIEDIE;

|;

my ($fh, $pid, $stdout, $stderr) = url_connect(
    "perl2header://./test-server.pl", $cfd_rpc
);

$rpc2->add($fh, 
    Pid => $pid, 
    Streams => {
        stdout => $stdout,
        stderr => $stderr,
    },
);
$mux->add($stdout);
$mux->add($stderr);
$mux->add($fh);

$rpc->server_timeout(sub {
    like($@, qr/^timeout/,"Got timeout as expected");
    $rpc2->test(sub{
        is($@, "no more connect retries", "Got error as expected");
    });
});

while (my $event = $mux->mux($rpc->timeout(), $rpc2->timeout())) {
    next if $rpc->io($event);
    next if $rpc2->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");
ok(!$rpc2->has_work, "Work queue is empty as it should be");
