#!/usr/bin/perl -cw
use strict;

package RPC_Async_Test;

use RPC::Async::Checker qw(check_named_args);

sub check_request {
    my ($procedure, @args) = @_;
    return check_named_args({
            add_numbers => {
                n1 => qr/^-?\d+$/,
                n2 => qr/^-?\d+$/,
            },
            get_id => {},
            callback => {
                calls => qr/^\d+$/,
                callback => undef, # TODO: sub ref
            },
        }, $procedure, @args);
}

sub check_response {
    my ($procedure, @args) = @_;
    return check_named_args({
            add_numbers => {
                sum => qr/^-?\d+$/,
            },
            get_id => {
                uid => qr/^\d+$/,
                gid => qr/^\d+$/,
                euid => qr/^\d+$/,
                egid => qr/^\d+$/,
            },
            callback => {
            },
        }, $procedure, @args);
}

1;
