#!/usr/bin/perl -w
use strict;

package RPC::Async::Checker;

use base "Exporter";

our @EXPORT_OK = qw(check_named_args);

sub check_named_args($$@) {
    my ($checks, $procedure, @args) = @_;

    # TODO: check @args too

    return exists $checks->{$procedure};
}

1;
# vim: et sw=4 sts=4 tw=80
