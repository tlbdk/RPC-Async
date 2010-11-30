package RPC::Async::Regexp;
use strict;
use warnings;
use Carp;

our $VERSION = '2.00';

=head1 NAME

RPC::Async::Regexp - wrapper class to ensure that the regular expressions qr//
syntax is preserved after deserialization.

=cut

=head1 METHODS

=head2 B<new($regexp, [options])>

Constructs a new Regexp object.

=cut

sub new {
    my ($class, $regexp, $options) = @_;

    if(ref $regexp eq 'Regexp') {
        if($regexp =~ /^\(\?([^-]*)-[^:]*:(.*)\)$/s) {
            $regexp = $2;
            $options = $1;
        } else {
            croak "Could not parse Regexp: $regexp";
        }
    }
    
    # Escape /
    $regexp =~ s/\//\\\//gs;

    my $self = bless {
        regexp => $regexp,
        options => $options,
    }, $class;
   
    return $self;
}

=head2 B<build()>

Return a normal perl regexp with the correct options set

=cut

sub build {
    my ($regexp) = ($_[0]->{regexp} =~ /^(.*)$/);
    my ($options) = ($_[0]->{options} =~ /^(.*)$/);

    my $re = eval("qr/$regexp/$options"); ## no critic
    croak "Could not build $_[0]->{regexp} : $@" if $@;
    return $re;
}

1;

=head1 AUTHOR

Troels Liebe Bentsen <tlb@rapanden.dk>

=head1 COPYRIGHT

Copyright(C) 2009 Troels Liebe Bentsen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

# vim: et sw=4 sts=4 tw=80
