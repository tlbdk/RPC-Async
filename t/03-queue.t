use strict;
use warnings;
use Carp;

use Test::More tests => 7;
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
    Limit => 3,
    CloseOnIdle => 1,
    WaitPidTimeout => 0,
);

$rpc->connect("perl2://./test-server.pl");

$rpc->simple(sub {
    my @sent = grep { exists $_->{fh} } values %{$rpc->dump_requests()};
    print Dumper($rpc->dump_requests(), \@sent);
    is(int @sent + 1, 3, "Number of outstanding requests was 3");
    ok(!$@, "No exception was set");
});

$rpc->simple(sub { ok(!$@, "No exception was set"); });
$rpc->simple(sub { ok(!$@, "No exception was set"); });
$rpc->simple(sub { ok(!$@, "No exception was set"); });
$rpc->simple(sub { ok(!$@, "No exception was set"); });

while (my $event = $mux->mux($rpc->timeout())) {
    next if $rpc->io($event);
    print "type: $event->{type} : ".($event->{fh} or '')."\n";
    print "data: '$event->{data}'\n" if $event->{type} eq 'read';
}

ok(!$rpc->has_work, "Work queue is empty as it should be");

