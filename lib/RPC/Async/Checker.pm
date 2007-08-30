package RPC::Async::Checker;
use strict;
use warnings;

# FIXME: SHOULD BE REMOVED

our $VERSION = '1.0';

use base "Exporter";

our @EXPORT_OK = qw(check_named_args);

sub check_named_args($$@) {
    my ($checks, $procedure, @args) = @_;

    # TODO: check @args too

    return exists $checks->{$procedure};
}

1;

=head1 AUTHOR

Troels Liebe Bentsen <tlb@rapanden.dk>, Jonas Jensen <jbj@knef.dk>

=head1 COPYRIGHT

Copyright(C) 2005-2007 Troels Liebe Bentsen
Copyright(C) 2005-2007 Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

# vim: et sw=4 sts=4 tw=80
