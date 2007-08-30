#!/usr/bin/perl -w
use strict;

package RPC::Async::Server;

our $VERSION = "1.00";

=head1 NAME

RPC::Async::Server - server side of asynchronous RPC framework

=head1 SYNOPSIS

  use RPC::Async::Server;
  use IO::EventMux;
  
  my $mux = IO::EventMux->new;
  my $rpc = RPC::Async::Server->new($mux);
  init_clients($rpc);
  
  while ($rpc->has_clients()) {
      my $event = $rpc->io($mux->mux) or next;
  }
  
  sub rpc_add_numbers {
      my ($caller, %args) = @_;
      my $sum = $args{n1} + $args{n2};
      $rpc->return($caller, sum => $sum);
  }
  
  1;

=head1 DESCRIPTION

This module provides the magic that hides the details of doing asynchronous RPC
on the server side. It does not dictate how to implement initialisation or main
loop, although it requires the application to use IO::EventMux or emulate it.

When creating a new C<RPC::Async::Server> object with the C<new> method, you
are also telling it what package it should invoke callback functions in. If the
package argument is omitted, it will use the caller's package.

Users of this module are written as a kind of hybrid between a perl executable
program and a library module. They need a small wrapper program around them to
initialise communication with their clients somehow. The convention of
L<RPC::Async::Client> dictates that they call a method named init_clients as
described in L</SYNOPSIS>.

=head1 METHODS

=head2 C<rpc_*($caller, @args)> (callbacks)

The method named rpc_PROCEDURE will be called back from C<io> when the client
calls the method PROCEDURE. The first argument is an opaque handle to be used
when calling C<return>, and the remaining arguments are the ones given by the
client.

The return values from these methods are ignored. Return a value by calling
C<return> on the RPC server object. It is not necessary to call C<return>
before returning from this method, but it should be called eventually. If the
client sends invalid data, throw an exception to disconnect him. 

=head2 C<check_request($procedure, @args)> (callback)

If this method exists, it will be called to verify that C<$procedure> exists
and accepts C<@args>. This check is placed in an external function for a few
reasons: it allows the client to check its own request before sending it, and
it allows these checks to be turned off for performance.

Instead of implementing this method in the server, it is a good idea to
implement it in a base module inherited by the server. That allows the client
to share the same code.

=head2 C<check_response($procedure, @args)> (callback)

Same as C<check_request>, but for verifying the response going back to the
client.

=cut

use IO::EventMux;
use RPC::Async::Util qw(make_packet append_data read_packet call);
use RPC::Async::Coderef;

=head2 C<new($mux [, $package])>

Instantiate a new RPC server object that will call back methods in C<$package>.
If C<$package> is omitted, the caller's package will be used.

The C<$mux> object must be an instance of C<IO::EventMux> or something
compatible, which will be used for I/O. It is the responsibility of the caller
to poll this object and call C<io>, as detailed below.

=cut

sub new {
    my ($class, $mux, $package) = @_;

    if (not $package) {
        ($package) = caller;
    }
    #print __PACKAGE__, ": called from '$package'\n";

    my %self = (
        mux => $mux,
        package => $package,
        check_request  => UNIVERSAL::can($package, "check_request"),
        check_response => UNIVERSAL::can($package, "check_response"),
        buf => undef,
        clients => {},
    );

    return bless \%self, (ref $class || $class);
}

sub _decode_args {
    my ($self, $fh, @args) = @_;

    foreach my $arg (@args) {
        if (not ref $arg) {
            # do nothing
        
        } elsif (ref $arg eq "ARRAY") {
            $self->_decode_args($fh, @$arg);

        } elsif (ref $arg eq "HASH") {
            $self->_decode_args($fh, values %$arg);

        } elsif (ref $arg eq "REF") {
            $self->_decode_args($fh, $$arg);

        } elsif (ref $arg eq "CODE") {
            die __PACKAGE__.": coderef?";

        } elsif (UNIVERSAL::isa($arg, "RPC::Async::Coderef")) {
            my $id = $arg->id;
            $arg->set_call(sub {
                $self->{mux}->send($fh, make_packet([ $id, "call", @_ ]));
            });
            $arg->set_destroy(sub {
                return if !$self->{mux};
                $self->{mux}->send($fh, make_packet([ $id, "destroy" ]));
            });
        }
    }
}

sub _handle_read {
    my ($self, $fh, $data) = @_;

    append_data \$self->{buf}, $data;

    while (my $thawed = read_packet(\$self->{buf})) {
        if (ref $thawed eq "ARRAY" and @$thawed >= 2) {
            my ($id, $procedure, @args) = @$thawed;

            if (!$self->{check_request}
                    or $self->{check_request}->($procedure, @args)) {
                my $caller = [ $fh, $id, $procedure ];
                $self->_decode_args($fh, @args);
                call($self->{package}, "rpc_$procedure", $caller, @args);
            } else {
                die "check_request failed\n";
            }

        } else {
            die "bad data in thawed packet\n";
        }
    }
}

=head2 C<add_client($socket)>

Add a client to the internal list of clients. This method is not usually called
directly.

=cut

sub add_client {
    my ($self, $sock) = @_;
    $self->{mux}->add($sock);
    $self->{clients}{$sock} = 1;
}

=head2 C<add_listener($socket)>

Add a listening socket. Connections to this socket will be automatically added
to the internal list of clients. This method is not usually called directly.

=cut

sub add_listener {
    my ($self, $sock) = @_;
    $self->{mux}->add($sock, Listen => 1);
    $self->{clients}{$sock} = 1;
}

=head2 C<return($caller, @args)>

Must be called exactly once for each callback to one of the C<rpc_*> methods.

=cut

sub return {
    my ($self, $caller, @args) = @_;
    my ($sock, $id, $procedure) = @$caller;

    if (!$self->{check_response}
            or $self->{check_response}->($procedure, @args)) {
        #print "return: sending: $id @args\n";
        $self->{mux}->send($sock, make_packet([ $id, @args ]));
    } else {
        die "return: check_response failed\n";
    }
}

=head2 C<io($event)>

This method is called in the program's main loop every time an event is
received from IO::EventMux::mux. If C<io> processed this event and determined
that it is not relevant to the caller, it returns C<undef>. Otherwise, the
event is returned. This leads to the calling style of

  my $event = $rpc->io($mux->mux) or next;

in the main loop. If more than one RPC server is in use, chain the calls like

  my $event = $mux->mux;
  $event = $rpc1->io($event) or next;
  $event = $rpc2->io($event) or next;

This method will invoke the C<rpc_*> callbacks as needed.

=cut

sub io {
    my ($self, $event) = @_;
    my $fh = $event->{fh};

    if ($fh && exists $self->{clients}{$fh} or
        $event->{type} eq "accepted" && $self->{clients}{$event->{parent_fh}}) {
        my $type = $event->{type};

        if ($type eq "read") {
            #print __PACKAGE__, ": got ", length $event->{data}, " bytes\n";

            eval { $self->_handle_read($fh, $event->{data}) };
            if ($@) {
                warn __PACKAGE__.": Disconnecting client for error: $@\n";
                $self->{mux}->kill($fh);
            }

        } elsif ($type eq "closed") {
            delete $self->{clients}{$fh};
            #print "Client $fh disconnected; ", int(keys %{$self->{clients}}),
            #        " clients left.\n"

        } elsif ($type eq "accepted") {
            $self->add_client($fh);
        }

        return undef;

    } else {
        return $event;
    }

}

=head2 C<has_clients()>

Returns true if and only if at least one client is still connected to this
server.

=cut

sub has_clients {
    my ($self) = @_;
    return scalar %{$self->{clients}};
}

1;
# vim: et sw=4 sts=4 tw=80
