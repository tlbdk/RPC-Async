use strict;
use warnings;
use Carp;

use Test::More tests => 6;
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

my $rpc2 = RPC::Async::Client->new( 
    Mux => $mux,
    Timeout => 0,
    Limit => 0,
    CloseOnIdle => 1,
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

do $module or die "Cannot load $module: $@\n";

|;

my ($fh, $pid) = url_connect("perlheader://./test-server.pl", $cfd_rpc);
$mux->add($fh);
$rpc->add($fh);

$rpc->set_meta("Value from client 1", sub {
    ok(!$@, "We did not get an exception 1");

    my $fh = url_connect("unix://./socks/test-server.sock");
    $mux->add($fh);
    $rpc2->add($fh);
});

# Timeout after 1 sec, TODO: Timing issue, we should do something better than this
$rpc->server_timeout(sub{});

$rpc2->set_meta("Value from client 2", sub {
    ok(!$@, "We did not get an exception 2");

    $rpc2->get_meta(sub {
        my @result = sort @_;
        print Dumper(\@_);
        is_deeply(\@result, ["Value from client 1", "Value from client 2"], 
            "We got our values back");
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

# Wait for server to quit
kill 1, $pid; 
is(waitpid($pid, 0), $pid, "The pid was colleted without any problems");

