package RPC::Async::Coderef;
use strict;
use warnings;
use Carp;

our $VERSION = '1.05';

=head1 NAME

RPC::Async::Coderef - wrapper class to ensure that coderefs are unmapped and
discarded on the client side when garbage collected on the server side

=cut

use IO::EventMux;

=head1 METHODS

=head2 B<new($id)>

Constructs a new coderef object.

=cut

sub new {
    my ($class, $id) = @_;

    my %self = (
        id      => $id,
        call    => undef,
        destroy => undef,
        alive    => 1,
    );

    return bless \%self, (ref $class || $class);
}

=head2 B<id()>

Return id

=cut

sub id {
    my ($self) = @_;
    $self->{id};
}

=head2 B<alive()>

Returns true if the callback client is still connected and the coderef on the
client side is valid.

=cut

sub alive {
    my ($self) = @_;
    $self->{alive};
}

=head2 B<kill()>

Kill this object, used when the clients disconnects.

=cut

sub kill {
    my ($self) = @_;
    $self->{alive} = 0;
    $self->{destroy} = undef;
    $self->{call} = undef;
}

=head2 B<set_call($call)>

Set callback function

=cut

sub set_call {
    my ($self, $call) = @_;
    $self->{call} = $call;
}

=head2 B<set_destroy($destroy)>

Set destroy function

=cut

sub set_destroy {
    my ($self, $destroy) = @_;
    $self->{destroy} = $destroy;
}

=head2 B<call(@args)>

Call callback function with @args

=cut

sub call {
    my ($self, @args) = @_;
    croak "call on dead Coderef" if !$self->{alive};

    if ($self->{call}) {
        $self->{call}->(@args);
    } else {
        die __PACKAGE__.": callback not set";
    }
}

sub DESTROY {
    my ($self) = @_;
    print "destroy\n";
    if ($self->{destroy}) {
        $self->{destroy}->();
        $self->{destroy} = undef;
    }
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
