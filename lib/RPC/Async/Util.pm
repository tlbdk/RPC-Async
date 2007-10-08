#!/usr/bin/env perl
use strict;
use warnings;

our $VERSION = '1.02';

package RPC::Async::Util;

use base "Exporter";
use Class::ISA;
use Storable qw(nfreeze thaw);

our @EXPORT_OK = qw(call append_data read_packet make_packet);

{
my %sub_pointers = (); # TODO: does this improve performance?
sub call($$@) {
    my ($package, $sub, @args) = @_;

    my $fqsub = "$package\::$sub";
    my $ptr = $sub_pointers{$fqsub};

    if (exists $sub_pointers{$fqsub}) {
        $ptr = $sub_pointers{$fqsub};

    } else {
        #print "RPC::Async::Util: First call to $fqsub\n";
        $ptr = UNIVERSAL::can($package, $sub);
        if (!$ptr) {
            warn "No sub '$sub' in package '$package'";
        }
        $sub_pointers{$fqsub} = $ptr;
    }

    if ($ptr) {
        return $ptr->(@args);
    } else {
        return undef;
    }
}
}

sub append_data($$) {
    my ($buf, $data) = @_;

    if (not defined $$buf) {
        $$buf = $data;
    } else {
        $$buf .= $data;
    }
}

sub read_packet($) {
    my ($buf) = @_;

    return if not defined $$buf or length $$buf < 4;

    my $length = unpack("N", $$buf);
    die if $length < 4; # TODO: catch this
    return if length $$buf < $length;

    my $frozen = substr $$buf, 4, $length - 4;
    if (length $$buf == $length) {
        $$buf = undef;
    } else {
        $$buf = substr $$buf, $length;
    }

    return thaw $frozen;
}

sub make_packet($) {
    my ($ref) = @_;

    my $frozen = nfreeze($ref);
    return pack("N", 4 + length $frozen) . $frozen;
}

=head1 AUTHOR

Jonas Jensen <jbj@knef.dk>, Troels Liebe Bentsen <tlb@rapanden.dk> 

=head1 COPYRIGHT

Copyright(C) 2005-2007 Troels Liebe Bentsen

Copyright(C) 2005-2007 Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
# vim: et sw=4 sts=4 tw=80
