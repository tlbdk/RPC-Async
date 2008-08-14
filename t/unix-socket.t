use strict;
use warnings;

use Test::More tests => 2;
use RPC::Async::Client;
use IO::EventMux;
use RPC::Async::URL;
use English;

my $mux = IO::EventMux->new();

# Set the user for the server to run under.
$ENV{'IO_URL_USER'} ||= 'root';

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

sub init_clients {
    my ($rpc) = @_;
    $rpc->add_client($sock);
    $rpc->add_listener(url_listen("unix://./socks/test-server.sock"));

    if(wantarray) {
        return ($sock, get_listeners());
    } else {
        return $sock;
    }
}

$0="$module";
prctl_name($module);

do $module or die "Cannot load $module: $@\n";

|;

my ($fh, $pid) = url_connect("perlheader://./test-server.pl", $cfd_rpc);
my $rpc1 = RPC::Async::Client->new($mux, $fh);

my $rpc2 = RPC::Async::Client->new($mux, url_connect("unix://./socks/test-server.sock"));

$rpc1->add_numbers(n1 => 1, n2 => 2, sub {
    my %reply = @_;
    is(1 + 2, $reply{sum}, "Addition of 1 and 2");
});

$rpc2->add_numbers(n1 => 1, n2 => 2, sub {
    my %reply = @_;
    is(1 + 2, $reply{sum}, "Addition of 1 and 2");
});

while ($rpc1->has_requests || $rpc1->has_coderefs || $rpc2->has_requests || $rpc2->has_coderefs) {
    my $event = $mux->mux;
    $rpc1->io($event);
    $rpc2->io($event);
}

$rpc1->disconnect;
$rpc2->disconnect;
