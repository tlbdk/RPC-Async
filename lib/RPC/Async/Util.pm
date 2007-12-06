package RPC::Async::Util;
use strict;
use warnings;

our $VERSION = '1.02';

use base "Exporter";
use Class::ISA;
use Storable qw(nfreeze thaw);

our @EXPORT_OK = qw(append_data read_packet make_packet expand);


# http://www.w3.org/TR/xmlschema-2/ Good source of data types
# FIXME: Write expand function for handling input/output defs like:
#          'uid|gid|euid|egid' =>  { uid => .... }
#
#          'latin1' => latin1string
#          'str|string|utf8' => utf8string
#          '(u)(integer|int)32?|longlong' => $1"integer64";
#          '(u)(integer|int)32?|long'     => $1."integer32";
#          '(u)(integer|int)16?|short'    => $1."integer16";
#          '(u)(integer|int)8?|byte|char' => $1."integer8";
#          'float'                        => 'float32';
#          'double|float64'               => 'float64';
#          'bin|data' => 'binary',
sub expand {
    my ($ref) = @_;
    return $ref;
}

sub append_data {
    my ($buf, $data) = @_;

    if (not defined $$buf) {
        $$buf = $data;
    } else {
        $$buf .= $data;
    }
}

sub read_packet {
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

sub make_packet {
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
