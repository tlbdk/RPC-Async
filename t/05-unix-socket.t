use strict;
use warnings;
use Carp;

use Test::More tests => 5;
use RPC::Async::Client;
use IO::EventMux;
use RPC::Async::URL;
use List::Util qw(min);
use English;

my $mux = IO::EventMux->new();
my $rpc1 = RPC::Async::Client->new(
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    CloseOnIdle => 1,
);
my $rpc2 = RPC::Async::Client->new(
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    CloseOnIdle => 1,
);

# Needed when writing to a broken pipe 
$SIG{PIPE} = sub { # SIGPIPE
    croak "Broken pipe";
};

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

do $module or die "Cannot load $module: $@\n";

|;

my ($fh, $pid) = url_connect("perlheader://./test-server.pl", $cfd_rpc);
$mux->add($fh);
$rpc1->add($fh);

$rpc1->add_numbers(n1 => 1, n2 => 2, sub {
    my %reply = @_;
    is(1 + 2, $reply{sum}, "Addition of 1 and 2");
    # Connect to socket as we know know the server is up
    my $fh = url_connect("unix://./socks/test-server.sock");
    $mux->add($fh);
    $rpc2->add($fh);
});

$rpc2->simple(sub {
    pass("RPC call on socket returned");
});

while (my $event = $mux->mux($rpc1->timeout(), $rpc2->timeout())) {
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    next if $rpc1->io($event);
    next if $rpc2->io($event);
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc1->has_work, "Work queue is empty as it should be");
ok(!$rpc2->has_work, "Work queue is empty as it should be");

# Wait for server to quit
kill 1, $pid; 
is(waitpid($pid, 0), $pid, "The pid was colleted without any problems");
