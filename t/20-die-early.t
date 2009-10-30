use strict;
use warnings;
use Carp;

use Test::More tests => 6;
use IO::EventMux;
use RPC::Async::URL;
use RPC::Async::Client;

use Log::Sensible;
Log::Sensible::level('trace');

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
    OnRestart => sub {
        my($trying, $reason, $status) = @_;
        
        if($trying) {
            cmp_ok($reason, "=~","Connection reset by peer",
                "We try restarting");
        } else {
            cmp_ok($reason, "=~", "no more retries",
                "We fail restarting because no more retries");
        }

        is($status, 255, "Exit status was 255");
    },
    Retries => 1,
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

asdasd
die;

do $module or die "Cannot load $module: $@\n";

|;

#my ($fh, $pid, $stdout, $stderr) = url_connect("perl2header://./test-server.pl", $cfd_rpc);
#$rpc->add($fh, 
#    Pid => $pid, 
#    Streams => {
#        stdout => $stdout,
#        stderr => $stderr,
#    },
#);
#$mux->add($fh);
$rpc->connect("perl2header://./test-server.pl", $cfd_rpc);

$rpc->simple(sub {
    is($@, "no more connect retries", "No exception was set");
});

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");
