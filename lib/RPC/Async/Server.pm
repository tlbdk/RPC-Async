package RPC::Async::Server;
use strict;
use warnings;
use Carp;

our $VERSION = '2.00';

my $DEBUG = 1;
my $TRACE = 1;
my $INFO = 1;

=head1 NAME

RPC::Async::Server - server side of asynchronous RPC framework

=head1 VERSION

This documentation refers to RPC::Async::Server version 2.00. 

=head1 SYNOPSIS

  use RPC::Async::Server;
  use IO::EventMux;
 
  my $fh = new ...;

  my $mux = IO::EventMux->new;
  my $rpc = RPC::Async::Server->new();
  $mux->add($fh);
  $rpc->add($fh);
  
  while (my $event = $mux->mux()) {
      next if $rpc->io($event);
  }
  
  sub rpc_add_numbers {
      my ($caller, %args) = @_;
      my $sum = $args{n1} + $args{n2};
      $rpc->return($caller, sum => $sum);
  }
  
  1;

=head1 DESCRIPTION

TODO: Update to new api

This module provides the magic that hides the details of doing asynchronous RPC
on the server side. It does not dictate how to implement initialisation or main
loop, although it requires the application to use IO::EventMux.

When creating a new C<RPC::Async::Server> object with the C<new> method, you
are also telling it what package it should invoke callback functions in. If the
package argument is omitted, it will use the caller's package.

Users of this module are written as a kind of hybrid between a perl executable
program and a library module. They need a small wrapper program around them to
initialise communication with their clients somehow. The convention of
L<RPC::Async::Client> dictates that they call a method named url_clients as
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

=cut

use IO::EventMux;
use RPC::Async::Util qw(expand decode_args);
use RPC::Async::Coderef;

=head2 C<new([%args])>

Instantiate a new RPC server object that will call back methods in C<$package>.
If C<$package> is omitted, the caller's package will be used.

The C<$mux> object must be an instance of C<IO::EventMux> or something
compatible, which will be used for I/O. It is the responsibility of the caller
to poll this object and call C<io>, as detailed below.

=over

=item Serialize

Overrides the default serialization  function. TODO: Write more   

=item DeSerialize

Overrides the default deserialization function. TODO: Write more   

=item MaxRequestSize

Sets the max request size that RPC::Client::Async can handle. This is used to
limit the amount of memmory that a request will take when doing the
deserialization.

The default value is 10MB.

=back

=cut

sub new {
    my ($class, %args) = @_;

    *_serialize =\&RPC::Async::Util::serialize_storable;
    *_deserialize = \&RPC::Async::Util::deserialize_storable;

    if($args{Serialize}) {
        croak "Argument Serialize is not a code ref" 
            if !ref $args{Serialize} eq 'CODE';
        
        *_serialize = $args{Serialize};
    }

    if($args{DeSerialize}) {
        croak "Argument DeSerialize is not a code ref" 
            if !ref $args{DeSerialize} eq 'CODE';

        *_deserialize = $args{DeSerialize};
    }
    
    if (!$args{Package}) {
        $args{Package} = caller;
    }
    #print __PACKAGE__, ": called from '$package'\n";

    my $self = bless {
        package => $args{Package},
        mux => $args{Mux},
        fhs => {},
        max_request_size => defined $args{MaxRequestSize} ?
            $args{MaxRequestSize} : 10 * 1024 * 1024, # 10MB
    }, $class;

    return $self;
}

=head2 C<add($fh)>

Add a client fh to the internal list of clients.

=cut

sub add {
    my ($self, $fh) = @_;
    $self->{fhs}{$fh} = '';
}

=head2 C<return($caller, @args)>

Must be called exactly once for each callback to one of the C<rpc_*> methods.

=cut

sub return {
    my ($self, $caller, @args) = @_;
    
    croak "caller is not an array ref" if ref $caller ne 'ARRAY';

    # TODO: Replace 'type' with CONSTANTS
    push(@{$self->{waiting}}, [@$caller, 'result', @args])
}

=head2 C<die($caller, $str)>

Set the $@ in the scope of the client callback and in essence acts as a
exception on the client side, can be called instead of C<return()> and only
once. 

=cut

sub die {
    my ($self, $caller, @args) = @_;
    
    croak "caller is not an array ref" if ref $caller ne 'ARRAY';

    push(@{$self->{waiting}}, [@$caller, 'die', @args])
}




=head2 C<io($event)>

This method is called in the program's main loop every time an event is received
from IO::EventMux::mux. If the event is relevant to RPC::Async::Server it
returns C<undef>. Otherwise 1 is returned. This leads to the calling style of

  next if $rpc->io($mux->mux);

in the main loop. If more than one RPC server is in use, chain the calls like

  my $event = $mux->mux;
  next if $rpc1->io($event);
  next if $rpc2->io($event);

This method will invoke the C<rpc_*> callbacks as needed.

=cut

sub io {
    my ($self, $event) = @_;
    my $mux = $self->{mux};
    my($type, $fh, $data) = ($event->{type}, $event->{fh}, $event->{data});

    return if !defined $fh;
    #use Data::Dumper; print Dumper($event);

    if(exists $self->{fhs}{$fh}) {
        print "do_io: $type\n" if $TRACE;

        if($type eq 'read') {
            # DeSerialize and call callbacks 
            eval { $self->_append($event->{fh}, $event->{data}); };
            if($@) {
                if($@ =~ /^RPC:/) {
                    print "killed connection because of '$@\'n";
                    $self->_close($fh); # Close client and drop outstanding requests
                    $mux->kill($fh);
                } else {
                    # Rethrow exception
                    CORE::die $@;
                }
            }

        } elsif($type eq 'closing') {
            # Close the client if the connection is closed
            $self->_close($fh); 
        
        } elsif($type eq 'error') {
            print Dumper($event);
            $self->_close($fh); 
            $mux->kill($fh);
        }

        # Send outstanding rpc packets
        while (my ($fh, $data) = $self->_data()) {
            print "Sending packed data: $fh\n" if $TRACE;
            # DEBUG CODE
            #use File::Slurp;
            #write_file('server.tmp', { binmode => ':raw', append => 1 }, $data);
            $mux->send($fh, $data);
        }

        return 1;
    
    } elsif($type eq 'accepted' and exists $self->{fhs}{$event->{parent_fh}}) {
        print "Added $fh from parent_fh $fh\n" if $TRACE;
        $self->add($fh);

    } else {
        return;
    }
}

=head2 C<has_clients()>

Returns true if and only if at least one client is still connected to this
server.

=cut

sub has_clients {
    my ($self) = @_;
    return scalar %{$self->{fhs}};
}

sub _append {
    my ($self, $fh, $data) = @_;
    croak "RPC: fh is undefined" if !defined $fh;
    croak "RPC: fh $fh not managed by RPC::Client" if !exists $self->{fhs}{$fh};
    croak "RPC: data is undefined" if !defined $data;

    $self->{fhs}{$fh} .= $data;

    while(length($self->{fhs}{$fh}) > 0) {
        my $packet = _deserialize(\$self->{fhs}{$fh}, 
            $self->{max_request_size}); 
        
        # Drop out of loop if we need more data 
        last if !$packet; 
        
        my ($id, $procedure, @args) = @{$packet};
        
        my $caller = [ $fh, $id ];

        # Set main ref and package ref to package if not main.
        my $main = \%main::;
        my $package = $self->{package} eq 'main'
            ? $main : $main->{$self->{package}};
       
        #use Data::Dumper;
        #print Dumper($main);

        if(exists $package->{"rpc_$procedure"}) {
            my $sub = *{$package->{"rpc_$procedure"}}{CODE};
            $sub->($caller, @{decode_args($self, $fh, \@args)});
       
        # TODO : Make this more flexible so other ways of getting reflection
        # information is possible
        } elsif($procedure eq 'reflection') {
            my %procedures = map { /^rpc_(.+)/; $1 => {} }
                             grep {$_ =~ /^rpc_/} keys %{$package};
            
            foreach my $procedure (keys %procedures) {
                if(exists $package->{"def_$procedure"}) {
                    my $sub = *{$package->{"def_$procedure"}}{CODE};
                    if($sub) {
                        $procedures{$procedure}{in}
                            = expand($sub->($caller, 1), 1);
                        $procedures{$procedure}{out}
                            = expand($sub->($caller, 0));
                    }
                } else {
                    $procedures{$procedure} = undef; 
                }
            }
            
            $self->return($caller, %procedures);

        } else {
            $self->die($caller, 
                "No sub '$procedure' in package '$self->{package}'");
        }
    }
}

sub _data {
    my($self, $fh, $nbytes) = @_;

    return if !keys %{$self->{fhs}};

    if(my $response = shift @{$self->{waiting}}) {
        my($fh, $id, $type, @args) = @{$response};
        
        # Serialize data
        my $data = _serialize([$id, $type, @args]);

        return ($fh, $data);
    }

    return;
}

sub _close {
    my($self, $fh) = @_;
    delete $self->{fhs}{$fh};
}

1;

=head1 AUTHOR

Troels Liebe Bentsen <tlb@rapanden.dk>, Jonas Jensen <jbj@knef.dk>

=head1 COPYRIGHT

Copyright(C) 2005-2009 Troels Liebe Bentsen

Copyright(C) 2005-2007 Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

# vim: et sw=4 sts=4 tw=80
