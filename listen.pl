#!/usr/bin/perl -wI lib
use strict;

use RPC::Async::Server;
use IO::URL;

@ARGV or die "Usage: $0 -u URL MODULE_FILE [ ARGS ]\n";

my @urls;
while ($ARGV[0] =~ /^-u(.*)/) {
    shift;
    push @urls, ($1 || shift);
}
shift if $ARGV[0] eq "--";

my $module = shift or die;

my @fhs = map { url_listen($_) } @urls;

sub init_clients {
    my ($rpc) = @_;
    foreach my $fh (@fhs) {
        $rpc->add_listener($fh);
    }
}

$0 = $module;

do $module or die "Cannot load $module: $@\n";

