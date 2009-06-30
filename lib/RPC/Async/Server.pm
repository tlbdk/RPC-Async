package RPC::Async::Server;
use strict;
use warnings;
use Carp;

# TODO: Validate that we catch exceptions when ever we do a callback

our $VERSION = '2.00';

my $DEBUG = 0;
my $TRACE = 0;
my $INFO = 0;

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
use RPC::Async::Util qw(expand decode_args queue_timeout unique_id);

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

    if (!$args{Package}) {
        $args{Package} = caller;
    }
    #print __PACKAGE__, ": called from '$package'\n";

    my $self = bless {
        package => $args{Package},
        mux => $args{Mux},
        metas => {}, # { $key => { $fh => 'data' } }
        fhs => {}, # { $fh => 'data' }
        serial => 0,
        timeouts => [], # [[time + $timeout, $id], ...]
        
        default_timeout => $args{Timeout} ? $args{Timeout} : 0,
        procedure_timeouts => {}, # { 'procedure_name' => timeout }  
   
        callers => {}, # { $fh => { $client_id => [ $retry_id, ... ] } } 
        retries => {}, #  { $id => { caller => $caller, callback => ... }

        default_return => $args{DelayedReturn} ? $args{DelayedReturn} : 0,  # { 'procedure_name' => 0 }
        procedure_returns => {}, # { 'procedure_name' => 1 }  

        max_request_size => defined $args{MaxRequestSize} 
            ? $args{MaxRequestSize} 
            : 10 * 1024 * 1024, # 10MB

        _deserialize => ref $args{DeSerialize} eq 'CODE' 
            ? $args{DeSerialize}
            : \&RPC::Async::Util::deserialize_storable,
        
        _serialize => ref $args{Serialize} eq 'CODE' 
            ? $args{Serialize} 
            : \&RPC::Async::Util::serialize_storable, 
    }, $class;

    return $self;
}

=head2 C<set_options($caller, %options)>

TODO: Write

=cut

sub set_options {
    my ($self, $procedure, %args) = @_;
    
    if(exists $args{Timeout}) {
        my $timeout = $args{Timeout};
        if(defined $timeout and $timeout >= 0) {
            $self->{procedure_timeouts}{$procedure} = $timeout;
        } else {
            delete $self->{procedure_timeouts}{$procedure}
        }
    # TODO: Implement 
    } elsif(exists $args{DelayedReturn}) {
        my $delayed = $args{DelayedReturn};
        if(defined $delayed) {
            $self->{procedure_returns}{$procedure} = $delayed;
        } else {
            delete $self->{procedure_returns}{$procedure}
        }

    } else {
        croak "No known options set";
    }
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
    push(@{$self->{waiting}}, [@$caller, 'result', @args]);
}

=head2 C<retry($caller, $timeout, $callback)>

Helper function to make it easier to do some timeout and retry handling on the
server. This can be useful when doing network IO and other cases where server
generated requests might get lost and needs to be retried. With C<retry()> you
can schedule a retry of a operation in $timeout seconds.

  # Send initial packet
  $mux->sendto($fh, $addr, $packet);

  # Resend the packet again after 3 seconds 
  $rpc->retry($caller, 3, sub {
    $mux->sendto($fh, $addr, $packet);
  });

All schedule retry functions are delete on C<return()> to $caller.

=cut

sub retry {
    my ($self, $caller, $timeout, $callback) = @_;

    print "Called retry on $caller for $timeout\n" if $TRACE;

    croak "caller is not an array ref" if ref $caller ne 'ARRAY';
    croak "callback is a coderef" if ref $callback ne 'CODE';

    my $id = unique_id(\$self->{serial});
    $self->{retries}{$id} = [$caller, $callback];

    queue_timeout($self->{timeouts}, $timeout + time, $id);
    
    my ($fh, $client_id) = @{$caller};
    push(@{$self->{callers}{$fh}{$client_id}}, $id);
}

=head2 C<timeout()>

Returns the next timeout in seconds.

NOTE: This function should always be called as it also does the data sending.

=cut

sub timeout {
    my ($self) = @_;
    my $timeouts = $self->{timeouts};
    
    # Handle timeouts
    my $time = time;
    my $timeout = undef;
    while(my $item = shift @{$timeouts}) {
        next if !exists $self->{retries}{$item->[1]};
        
        if($item->[0] <= $time) {
            if (my $retry = delete $self->{retries}{$item->[1]}) {
                eval { $retry->[1]->($retry->[0]); };
                if($@) {
                    if(ref $@ eq '' and $@ =~ /^CLIENT:\s*(.*?)\.?\n?$/s) {
                        print "Send croak to client\n" if $TRACE;
                        $self->error($retry->[0], $1);
                    } else {
                        CORE::die($@);
                    }
                }
            }
        
        } else {
            $timeout = $item->[0] - $time;
            # No more items timed out, put back on queue.
            unshift(@{$self->{timeouts}}, $item);
            last;
        }
    };

    # Send outstanding rpc packets
    my $mux = $self->{mux};
    while (my ($fh, $data) = $self->_data()) {
        print "Sending packed data: $fh\n" if $TRACE;
        $mux->send($fh, $data);
    }

    #use Data::Dumper; print Dumper($timeouts, $self->{retries}, $self->{waiting});
    #print("timeout(".time()."): ".(defined $timeout ? $timeout : 'undef')."\n");
    
    return $timeout;
}

=head2 C<error($caller, $str)>

Set the $@ in the scope of the client callback and in essence acts as a
exception on the client side, can be called instead of C<return()> and only
once. 

=cut

sub error {
    my ($self, $caller, $str) = @_;
   
    croak "caller is not an array ref" if ref $caller ne 'ARRAY';
    
    push(@{$self->{waiting}}, [@$caller, 'die', $str]);
}

=head2 C<on_close($caller, [$ref, ...])>

=cut

sub on_close {
    #TODO
}

=head2 C<meta($key, [$caller], [$value], [$type])>

Set or get a piece of metadata on a specific global key where RPC::Async will
cleanup up the metadata when the client disconnects. Setting undefined $value
will delete the key. If more clients use the same key an array of all client
values are returned. If $type is set the ref of type of will be used to store
the values per $key. Eg. {} will store the values in a hash making then uniq 
and [] in an array. The $type can not be changed after first use, the the key
needs to deleted and recreated.

Save $value :

  sub rpc_save {
    my($caller, $key, $value) = @_;
    $rpc->meta($key, $caller, $value); # Set $key to $value
    $rpc->meta($key, $caller, "$value1", []); # Override $key and add $value1 to an internal array
    $rpc->meta($key, $caller, "$value2", []); # Add $value1 to the internal array for key
    $rpc->return();
  }

Get $value :
  
  sub rpc_get {
    my($caller, $key) = @_;
    my @all_values = $rpc->meta($key);
    my @connection_value = $rpc->meta($key, $caller);
    
    # Delete all values on $key for this connection
    $rpc->meta($key, $caller, undef); 
    
    # Delete all values on $key
    $rpc->meta($key, undef); 
    
    $rpc->return(\@all_values, \@connection_value);
  }

=cut

sub meta {
    my ($self, $key, $caller, $value, $type) = @_;
    croak "no key defined" if !defined $key;
    my $data;

    if (@_ == 2) { # Get all values on $key
        return if !exists $self->{metas}{$key};
        $data = $self->{metas}{$key}; 

    } elsif (@_ == 3) { # Get all values on $key for this $caller connection
        return delete $self->{metas}{$key} if !defined $caller;
        croak "caller is not an array ref" if ref $caller ne 'ARRAY';
        
        $data = $self->{metas}{$key}{$caller->[0]};

    } elsif (@_ == 4) { # Set new value on $key for this $caller
        croak "caller is not an array ref" if ref $caller ne 'ARRAY';
        if(!defined $value) {
            my $res = delete $self->{metas}{$key}{$caller->[0]};
            delete $self->{metas}{$key} if keys %{$self->{metas}{$key}} == 0;
            return $res;
        } else {
            $self->{metas}{$key}{$caller->[0]} = $value;
        }
    
    } elsif (@_ == 5) { # Add new value to $key on this $caller
        croak "caller is not an array ref" if ref $caller ne 'ARRAY';
        if(ref $type eq 'HASH') {
            $self->{metas}{$key}{$caller->[0]}{$value} = $value;
        } elsif(ref $type eq 'ARRAY') {
            push(@{$self->{metas}{$key}{$caller->[0]}}, $value);
        } else {
            $self->{metas}{$key}{$caller->[0]} = $value;
        }

    } else {
        croak "Called with wrong number of arguments: ".int(@_);
    }

    # Return values
    if(ref $data eq 'HASH' or ref $data eq 'ARRAY') {
        return map { 
            if(ref $_ eq 'ARRAY') {
                @{$_};
            } elsif(ref $_ eq 'HASH') {
                values %{$_}
            } else {
                $_;
            }
        } ref $data eq 'HASH' ? (values %{$data}) : @{$data};
    
    } elsif(ref $data eq '') {
        return $data; 
    }
   
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

    # Only do something on events that have a filehandle
    return if !defined $fh;
    #use Data::Dumper; print Dumper($event);

    if(exists $self->{fhs}{$fh}) {
        print "server io: $type\n" if $TRACE;

        if($type eq 'read') {
            # DeSerialize and call callbacks 
            eval { $self->_append($event->{fh}, $event->{data}); };
            if($@) {
                if(ref $@ eq '' and $@ =~ /^RPC:/) {
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
        my $packet = $self->{_deserialize}->(\$self->{fhs}{$fh}, 
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
            
            eval { $sub->($caller, @{decode_args($self, $fh, \@args)}); };
            if($@) {
                # Send our error back if this exceptions has CLIENT:
                if((ref $@ eq '') and ($@ =~ /^CLIENT:\s*(.*?)\.?\n?$/s)) {
                    $self->error($caller, $1);
                
                } else {
                    CORE::die($@);
                }

            } else {
                # Use custom timeout if we have it else use default timeout
                my $timeout = $self->{procedure_timeouts}{$procedure};
                $timeout = defined $timeout ? $timeout : 
                    $self->{default_timeout};

                if($timeout) {
                    $self->retry($caller, $timeout, sub {
                        $self->error($_[0], "timeout-server"); 
                    });
                }
            }
       
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
            # Set $@ in remote client callback
            $self->error($caller, 
                "No sub '$procedure' in package $self->{package}");
        }
    }
}

sub _data {
    my($self, $fh, $nbytes) = @_;

    return if !keys %{$self->{fhs}};

    if(my $response = shift @{$self->{waiting}}) {
        my($fh, $client_id, $type, @args) = @{$response};
        
        print "$fh : $client_id, $type\n" if $TRACE;
        
        # Skip this response if nobody wants it
        return if !exists $self->{fhs}{$fh};
        
        # Delete all retries that are scheduled
        while(my $id = shift @{$self->{callers}{$fh}{$client_id} or []}) {
            delete $self->{retries}{$id};
        }

        # Serialize data
        my $data = $self->{_serialize}->([$client_id, $type, @args]);

        return ($fh, $data);
    }

    return;
}

sub _close {
    my($self, $fh) = @_;
    delete $self->{fhs}{$fh};
    
    # Clean up meta data from meta() 
    foreach my $key (keys %{$self->{metas}}) {
        delete $self->{metas}{$key}{$fh};
        delete $self->{metas}{$key} if !keys%{$self->{metas}{$key}};
    }
    
    # Clean up retry ids from retry() 
    if (my $client_ids = delete $self->{callers}{$fh}) {
        foreach my $id (values %{$client_ids}) {
            delete $self->{retries}{$id};
        }
    }
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
