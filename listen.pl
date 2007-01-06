#!/usr/bin/perl -wI lib
use strict;
use RPC::Async::Server;
use IO::URL;

my $module = shift;
@ARGV or die "Usage: $0 MODULE_FILE URL1 [ URL2 ... ]";

my @fhs = map { url_listen($_) } @ARGV;

sub init_clients {
    my ($rpc) = @_;
    foreach my $fh (@fhs) {
        $rpc->add_listener($fh);
    }
}

$0="$module";

do $module or die "Cannot load $module: $@\n";

