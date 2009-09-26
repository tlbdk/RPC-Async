package RPC::Async::Client;
use strict;
use warnings;

use Misc::Logger;

our $VERSION = '2.00';

my $DEBUG = 0;
my $TRACE = 0;
my $INFO = 0;

# TODO: Retries should be able to limited to a number of retries
# within a period of time. Eg. You can fail 3 times in 1 hour, a quick way to
# implement this would be a timeout that resets the retries after number of
# minutes.

# TODO: Do a better implementation of connect() call and remove dependence on URL
# module. 

=head1 NAME

RPC::Async::Client - client side of asynchronous RPC framework

=head1 VERSION

This documentation refers to RPC::Async::Client version 2.00. 

=head1 SYNOPSIS

  use RPC::Async::Client;
  use IO::EventMux;
  
  my $mux = IO::EventMux->new;
  my $rpc = RPC::Async::Client->new(Mux => $mux);
  
  $rpc->connect('perl://./test-server.pl');

  $rpc->add_numbers(n1 => 2, n2 => 3,
      sub {
          my %reply = @_;
          print "2 + 3 = $reply{sum}\n";
      });
  
  while (my $event = $mux->mux($rpc->timeout())) {
      next if $rpc->io($mux->mux);
  }

  $rpc->disconnect;
  
=head1 DESCRIPTION

This module provides the magic that hides the details of doing asynchronous RPC
on the client side. It does not dictate how to implement initialisation or main
loop, although it requires the application to use L<IO::EventMux> for the
moment. Future version might allow to use other event loops handlers.

The procedures made available by the remote server can be called directly on the
L<RPC::Async::Client> instance or via the C<call()> method where they are
further documented.

=head1 METHODS

=cut

use Carp;
use Socket;
use RPC::Async::Util qw(decode_args encode_args queue_timeout unique_id);
use RPC::Async::Coderef;
use RPC::Async::Regexp;
use RPC::Async::URL;

use Scalar::Util qw(blessed);

use Data::Dumper; 

our $AUTOLOAD;
sub AUTOLOAD {
    my $self = shift;
    my $procedure = $AUTOLOAD;
    $procedure =~ s/.*:://;
   
    # TODO: Check who is the caller so we can do better errors for internal
    # function calls
    croak "Non-existing RPC::Client function $procedure(".($self or '').")"
        if !defined $self or !blessed($self);

    # Same as $self->call($procedure, @_) but caller now returns a level higher
    @_ = ($self, $procedure, @_);
    goto &call;
}

# Define empty DESTROY() so it is not cought in the AUTOLOAD
sub DESTROY { }

=head2 C<new( [%options] )>

Constructs an RPC::Async::Client object

The optional parameters for the handle will be taken from the RPC::Async::Client
object if not given here:

=over

=item Retries

Set the number of reconnect retries before the RPC::Async::Client gives up and
throws an error.

=item Timeout

The default timeout in number of seconds a RPC has to complete before the
function returns the call with a "timeout" error.

A value of 0 disables timeout handling and it will then be up to the server to
handle this.

The default can be overridden on a pr. function basis with the C<set_options()>
call.

=item CloseOnIdle

Specifies if servers should be disconnect when the RPC::Async::Client has no
more work.

The default is 0.

=item CloseTimeout

The number of seconds to wait for server to close before calling kill on it's
pid.

=item WaitpidTimeout

The number of seconds to wait after all server filehandles have been closed before
collecting the pid.

=item KillTimeout

The number of seconds to wait after kill -1 has been called on the server pid,
before either collecting the pid or doing a kill -9 on the pid.

=item Serialize

Overrides the default serialization  function. TODO: Write more   

=item DeSerialize

Overrides the default deserialization function. TODO: Write more   

=item Output

Overrides the default server output function when RPC::Async::Client is handling
the server STDOUT and STDERR. TODO: Write more   

=item MaxRequestSize

Sets the max request size that RPC::Client::Async can handle. This is used to
limit the amount of memmory that a request will take when doing the
deserialization.

The default value is 10MB.

=item EncodeError

By default all arguments are filtered for data types that can't be serialized
for one reasons or another, and a string of "could not encode <type>" is used
instead. By setting EncodeError an exception is thrown instead.

=back

=cut

sub new {
    croak "Odd number of elements in %args" if ((@_ - 1) % 2);
    my ($class, %args) = @_;

    my $self = bless {
        requests => {}, # { $id => { callback => sub {}, ... }, ... }
        serial => 0,
        coderefs => {}, # { $id => sub { ... }, ... }
        fhs => {}, # { $fh => $fh, .. }
        rrs => [], # [ $fh, ... ]
        inputs => {}, # { $fh => 'data', ... } Input buffer
        
        timeouts => [], # [[time + $timeout, $id], ...]

        max_request_size => defined $args{MaxRequestSize} ?
            $args{MaxRequestSize} : 10 * 1024 * 1024, # 10MB

        # Connect retries
        connect_args  => {},
        connect_retries => defined $args{Retries} ? $args{Retries} : 0,

        # Connect timeouts
        default_timeout => defined $args{Timeout} ? $args{Timeout} : 0,
        procedure_timeouts => {},
        
        # Rate limitation
        default_limit => defined $args{Limit} ? $args{Limit} : 0, # TODO: Rename to SentLimit
        outstanding => 0, 
       
        # TODO: implement code that uses this.
        limit_key => '', # 
        key_queue => {}, # { key => [$id, ...] }
        waiting => [], # [ $id, ...]

        # Server extra output handling: eg. stdout, stderr
        extra_streams => {}, # { $stream_fh => [$rpc_fh, $type], ... }
        extra_fhs => {}, # { $rpc_fh => { $stream_fh => $type, ... } }

        mux => $args{Mux},

        close_on_idle => defined $args{CloseOnIdle} ? $args{CloseOnIdle} : 0,

        close_timeout => defined $args{CloseTimeout} ? $args{CloseTimeout} : 1,
        waitpid_timeout => defined $args{WaitPidTimeout} ? 
            $args{WaitPidTimeout} : 1,
        kill_timeout => defined $args{KillTimeout} ? $args{KillTimeout} : 1,
        
        pids => {}, # { $fh => $pid, ... }
        waitpid_ids => {}, # { $fh => $id }

        filter_args => $args{EncodeError} ? 0 : 1,

        _output => ref $args{Output} eq 'CODE' 
            ? $args{Output}
            : \&RPC::Async::Util::output,
        
        _deserialize => ref $args{DeSerialize} eq 'CODE' 
            ? $args{DeSerialize}
            : \&RPC::Async::Util::deserialize_storable,
        
        _serialize => ref $args{Serialize} eq 'CODE' 
            ? $args{Serialize} 
            : \&RPC::Async::Util::serialize_storable, 
    
    }, $class;

    unlink "client.tmp";
    unlink "client-input.tmp";
    unlink "client-buffer.tmp";

    return $self;
}

=head2 C<call($procedure, @args, $subref)>

Performs a remote procedure call. Rather than using this directly, this package
enables some AUTOLOAD magic that allows calls to remote procedures directly on
the L<RPC::Async::Client> instance.

Arguments are passed in key/value style by convention, although any arguments
may be given. The last argument a remote procedure call is a subroutine
reference to be executed upon completion of the call. This framework makes no
guarantees as to when, if ever, this sub will be called. Specifically, remote
procedures may return in a different order than they were called in.

Fairly complex data structures may be given as arguments, except for circular
ones. In particular, subroutine references are allowed.

Each call is given a uniq id that is returned and can be used to identify the
specific call on both client and server.

=cut

sub call {
    my ($self, $procedure, @args) = @_;
    my $callback = pop @args;
    
    croak "Called RPC function $procedure without callback" 
        if ref $callback ne 'CODE';

    if($self->{quitting}) {
        # In error state, all retries failed
        $@ = 'no more connect retries';
        $callback->();
    
    } else {
        #use Data::Dumper; print Dumper(\@args);
        my $id = unique_id(\$self->{serial});
        $self->{requests}{$id} = { 
            callback => $callback, 
            procedure => $procedure,
            args => encode_args($self, \@args, $self->{filter_args}),
            caller => [ caller() ],
        };
        push(@{$self->{waiting}}, $id);
        return $id;
    }
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
    while(my $item = shift @{$self->{timeouts}}) {
        next if !exists $self->{requests}{$item->[1]};
        
        if($item->[0] <= $time) {
            if (my $request = delete $self->{requests}{$item->[1]}) {
                $self->{outstanding}--;
                $@ = 'timeout';
                $request->{callback}->();
            }
        
        } else {
            $timeout = $item->[0] - $time;
            # No more items timed out, put back on queue.
            unshift(@{$self->{timeouts}}, $item);
            last;
        }
    };

    # Send outstanding rpc packets
    while (my ($fh, $data) = $self->_data()) {
        # DEBUG CODE
        #use File::Slurp;
        #write_file('client.tmp', { binmode => ':raw', append => 1 }, "<start>".$data."<end>");

        trace("Sending packed data: $fh");
        $self->{mux}->send($fh, $data);
    }

    # Check if we still have outstanding requests else close connection to server
    if($self->{close_on_idle} and !$timeout and !$self->has_work) {
        $self->{quitting} = 1;
        #use Data::Dumper; print Dumper($self->{timeouts}, $timeout);
        debug("timeout: no more work");
        foreach my $fh (values %{$self->{fhs}}) {
            trace("kill $fh");
            $self->{mux}->kill($fh);
        }
    }

    #print Dumper($self->{requests});
    #print Dumper($timeouts, $timeout);
    #print("timeout(".time()."): ".(defined $timeout ? $timeout : 'undef')."\n");

    return $timeout;
}


=head2 C<set_options($procedure, %options)>

Sets procedure specific options.

=over

=item Timeout

Sets the number of seconds before a specific RPC procedure times out. If 0 is
given then no timeout handling is done on the client side. A value smaller than
0 can be used to revert the procedure to default timeout handling.

=back

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
    } else {
        croak "No known options set";
    }
}


=head2 C<connect($url, @args)>

Simple wrapper to make it easy to connect to a server. TODO: write more

=cut

sub connect {
    my($self, $url, @args) = @_;
    my $mux = $self->{mux};

    if($url =~ /perl(?:root)?2/) {
        my ($fh, $pid, $stdout, $stderr) = url_connect($url, @args);
        $self->add($fh, 
            Pid => $pid, 
            Streams => {
                stdout => $stdout,
                stderr => $stderr,
            },
        );
        $mux->add($fh);
        $mux->add($stdout);
        $mux->add($stderr);
        trace("Added $fh, OUT:$stdout, ERR:$stderr");
        $self->{connect_args}{$fh} = [$url, @args];
        
        return $fh;
    } else {
        croak "unknown url type : $url";
    }
}


=head2 C<add($fh, %options)>

Add new filehandles to RPC::Async::Client. TODO: write more

=over

=item Pid

The pid of the server that is connected to the $fh.

=item Stream => { $type => $stram_fh }

Other filehandles or streams related to the server, such as STDOUT or STDERR.
TODO: Write about output()

=back

=cut

sub add {
    my ($self, $fh, %args) = @_;
   
    # Reset quitting as we are now adding a new server
    $self->{quitting} = 0;

    if(keys %args) {
        if($args{Pid}) {
            $self->{pids}{$fh} = $args{Pid};
        }
        if($args{Streams}) {
            foreach my $type (keys %{$args{Streams}}) {
                my $stream_fh = $args{Streams}{$type};
                $self->{extra_streams}{$stream_fh} = [$fh, $type];
                $self->{extra_fhs}{$fh}{$stream_fh} = $type;
            }
        }
    }
    
    $self->{fhs}{$fh} = $fh;
    push(@{$self->{rrs}}, $fh);
}

=head2 C<io($event>

Inspect an L<IO::EventMux> event. All such events must be passed through here
in order to handle asynchronous replies. If the event was handled, 1 is
returned. Otherwise undef is returned.

=cut

sub io {
    my ($self, $event) = @_;
    my $mux = $self->{mux};
    my($type, $fh, $data) = ($event->{type}, $event->{fh}, $event->{data});
    
    # Only do something on events that have a filehandle
    return if !defined $fh;
    
    # Check if this fh is handled by RPC
    if(exists $self->{fhs}{$fh}) {
        trace("client io: $type");

        if($type eq 'read') {
            # DeSerialize and call callbacks 
            eval { $self->_append($fh, $data); };
            # TODO: Check for RPC: call to limit 
            if($@) {
                if(ref $@ eq '' and $@ =~ /^RPC:/) {
                    error("killed connection because of '$@'");
                    # Try to reconnect if this was unexpected
                    $mux->kill($fh);
                    $self->_try_reconnect($fh, 'read');
                } else {
                    # Rethrow exception
                    CORE::die $@;
                }
            }

        } elsif($type eq 'closing' or $type eq 'closed') {
            # Try to reconnect if this was unexpected
            $self->_try_reconnect($fh, 'closing');
       
            # Check if all extra fh's are closed for this server 
            if(keys %{$self->{extra_fhs}{$fh}} == 0) {
                debug("main: last file handle for this server");
                # Collect server pid
                $self->_waitpid_timeout($fh, $self->{waitpid_timeout}, 1);
            
            } elsif(my $timeout = $self->{close_timeout}) {
                # Kill the server
                $self->_kill_timeout($fh, $timeout, 1);
            }


        } elsif($type eq 'error') {
            # Close the server if the connection is closed
            debug(Dumper({error_event => $event}));
            # Try to reconnect if this was unexpected
            $mux->kill($fh);
            $self->_try_reconnect($fh, 'errro');
        }
        
        return 1;

    } elsif(my $item = $self->{extra_streams}{$fh}) {
        if($type eq 'read') {
            $self->{_output}->($item->[0], $item->[1], $data);
        
        } elsif($type eq 'closed') {
            delete $self->{extra_streams}{$fh};
            delete $self->{extra_fhs}{$item->[0]}{$fh};

            # Check if all extra fh's are close for this server 
            if(keys %{$self->{extra_fhs}{$item->[0]}} == 0) {
                debug("extra: last file handle for this server");
                # Collect pid for this server
                $self->_waitpid_timeout($item->[0], 
                    $self->{waitpid_timeout}, 1);
            }
        }
        
        return 1;
    
    } else {
        return;
    }
}


=head2 has_work

Returns true if the RPC::Async::Client still has work to do such as waiting for outstanding requests, coderefs or for a server to terminate.

=cut

sub has_work {
    my ($self) = @_;
    return (scalar %{$self->{coderefs}} or scalar %{$self->{requests}}); 
}

=head2 has_requests

Returns true if there is at least one request pending. Usually, this means that
we should not terminate yet.

=cut

sub has_requests {
    my ($self) = @_;
    return scalar %{$self->{requests}};
}

=head2 has_coderefs

Returns true if the remote side holds a reference to a subroutine given to it
in an earlier call. Depending on the application, this may be taken as a hint
that we should not terminate yet. This information is obtained via interaction
with Perl's garbage collector on the server side.

=cut

sub has_coderefs {
    my ($self) = @_;
    return scalar %{$self->{coderefs}};
}

=head2 dump_requests

Returns requests that are pending as HASH ref. For debugging only.

=cut

sub dump_requests {
    my ($self) = @_;
    return $self->{requests};
}


=head2 dump_timeouts

Returns timeouts that are pending as ARRAY ref. For debugging only.

=cut

sub dump_timeouts {
    my ($self) = @_;
    return $self->{timeouts};
}

=head2 dump_coderefs

Returns coderefs that are pending as HASH ref. For debugging only.

=cut

sub dump_coderefs {
    my ($self) = @_;
    return $self->{coderefs};
}

## Private subs ##

sub _append {
    my ($self, $fh, $data) = @_;
    croak "RPC: fh is undefined" if !defined $fh;
    croak "RPC: fh $fh not managed by RPC::Client" if !exists $self->{fhs}{$fh};
    croak "RPC: data is undefined" if !defined $data;
    
    # DEBUG CODE
    #use File::Slurp;
    #write_file('client-input.tmp', { binmode => ':raw', append => 1 }, $data);

    $self->{inputs}{$fh} .= $data;
    
    #write_file('client-buffer.tmp', { binmode => ':raw' }, $self->{inputs}{$fh});
        
    while(length($self->{inputs}{$fh}) > 0) {
        my $packet = $self->{_deserialize}->(\$self->{inputs}{$fh},
            $self->{max_request_size});
        
        # Drop out of loop if we need more data 
        last if !$packet; 

        my ($id, $type, $args) = @{$packet};
        my @args = eval { @{decode_args($self, $fh, $args)} };
        # TODO : Check if we get an exception and do something with it.

        croak "RPC: Not a valid id" if !(defined $id or $id =~ /^\d+$/);
       
        #print Dumper({id => $id, type => $type, args => \@args});
        
        if (my $request = delete $self->{requests}{$id}) {
            $self->{outstanding}--;

            # Save exception state
            my $old_exception = $@;
            
            # We got an exception
            if($type eq 'die') { 
                $@ = shift @args;
                if($@ =~ s/^(.*) at .*? line \d+/$1/s) { 
                    # Get orignal rpc call caller information
                    my ($package, $file, $line) = @{$request->{caller}};
                    my $procedure = $request->{procedure};

                    $@ = "$@ at $file in ".__PACKAGE__
                        ."->$procedure() line $line\n";
                }
            }
            $request->{callback}->(@args);
            
            # Restore exception state
            $@ = $old_exception;

        } elsif (exists $self->{coderefs}{$id}) {
            if ($type eq "destroy") {
                delete $self->{coderefs}{$id};
            } elsif ($type eq "call") {
                $self->{coderefs}{$id}->(@args);
            } else {
                croak "Unknown type for callback: $type";
            }

        } else {
            warn "Spurious reply to id $id\n" if $DEBUG;
        }
    }

    return;
}

sub _data {
    my($self) = @_;

    # Don't give output if we have no connected servers
    return if !keys %{$self->{fhs}};

    my $limit = $self->{default_limit};
    return if $limit > 0 and $self->{outstanding} >= $limit; 

    if(my $id = shift @{$self->{waiting}}) {
        my $request = $self->{requests}{$id} or die "Unknown id waiting: $id";

        # TODO: Check in key_queue if we have a limit_key on the request that
        # match and we can queue a new item from key_queue on @waiting.

        # Find fh to use
        my $n = $self->{serial} % int @{$self->{rrs}};
        my $fh = $self->{rrs}[$n];
        
        # Serialize data
        my $data = $self->{_serialize}->([$id, $request->{procedure}, 
            @{$request->{args}}]);
      
        # Registre the fh to the id
        $request->{fh} = $fh;   
    
        # Use custom timeout if we have it else use default timeout
        my $timeout = $self->{procedure_timeouts}{$request->{procedure}};
        $timeout = defined $timeout ? $timeout : $self->{default_timeout};
        
        # Add id to timeout queue with now time + $timeout
        queue_timeout($self->{timeouts}, time + $timeout, $id) if $timeout;

        # Increment outstanding requests counter
        $self->{outstanding}++;

        return ($fh, $data);
    }

    return;
}

sub _waitpid_timeout {
    my($self, $fh, $timeout, $signal, $last_signal) = @_;
    my $pid = $self->{pids}{$fh} or return;

    while(my $id = shift @{$self->{waitpid_ids}{$fh}}) {
        debug("delete $id");
        delete $self->{requests}{$id};
    }

    # Queue timeout to collect pid 
    my $id  = unique_id(\$self->{serial});
    $self->{requests}{$id} = { 
        callback => sub {
            $self->_waitpid($fh, $signal, $last_signal);
        },
        procedure => '_waitpid',
    };
    queue_timeout($self->{timeouts}, time + $timeout, $id);
    push(@{$self->{waitpid_ids}{$fh}}, $id);
    debug("waitpid id: $id");
}

sub _waitpid {
    my($self, $fh, $signal, $last_signal) = @_;
    my $pid = $self->{pids}{$fh} or return;
    
    my $res = waitpid($pid, 1); # WNOHANG
    my $status = $? >> 8;
    debug("waitpid($pid): $status - $res");

    if($pid != $res) {
        $self->_kill($fh, $signal, $last_signal);
    } else {
        delete $self->{pids}{$fh};
        # Delete the id waiting in requests if we cought the waitpid before
        while(my $id = shift @{$self->{waitpid_ids}{$fh}}) {
            debug("collected pid $pid on id $id");
            delete $self->{requests}{$id};
        }
    }
}

sub _kill_timeout {
    my($self, $fh, $timeout, $signal, $last_signal) = @_;
    my $pid = $self->{pids}{$fh} or return;
 
    # Queue timeout to collect pid 
    my $id = unique_id(\$self->{serial});
    $self->{requests}{$id} = { 
        callback => sub {
            $self->_kill($fh, $signal, $last_signal);
        },
        procedure => '_kill',
    };
    queue_timeout($self->{timeouts}, time + $timeout, $id);
    push(@{$self->{waitpid_ids}{$fh}}, $id);
    debug("kill id: $id");
}

sub _kill {
    my($self, $fh, $signal, $last_signal) = @_;
    my $pid = $self->{pids}{$fh} or return;

    # Die if kill -9 failed 
    die "Could not kill($pid, 9)" if $last_signal and $last_signal == 9;

    # Kill pid 
    kill $signal, $pid; 
    debug("kill($signal, $pid)");
    
    # Try to waitpid and kill with 9 if that did not work
    $self->_waitpid_timeout($fh, $self->{kill_timeout}, 9, $signal);
}

sub _try_reconnect {
    my ($self, $fh, $type) = @_;
    my $connect_args = $self->{connect_args}{$fh};

    debug("try_reconnect($type): $fh");
    
    # Close server filehandle and put requests back in waiting queue
    $self->_close($fh); 
   
    # Try reconnection if we have requests waiting
    if ($connect_args and !$self->{quitting}) {
        if(--$self->{connect_retries} > 0) {
            debug("reconnect($type): $connect_args->[0]");
            $self->connect(@{$connect_args});
        } else {
            $self->{quitting} = 1;
            foreach my $id (keys %{$self->{requests}}) {
                my $request = delete $self->{requests}{$id};
                
                $@ = 'no more connect retries';
                $request->{callback}->();
            }
            # Empty waiting so we don't try to send some data
            $self->{waiting} = [];
        }
    } else {
        $self->{quitting} = 1;
    }
}

sub _close {
    my($self, $fh) = @_;
    
    # Remove all fh refrences from our requests
    foreach my $id (keys %{$self->{requests}}) {
        next if !exists $self->{requests}{$id}{fh}; # Skip internal and queued requests
        if($self->{requests}{$id}{fh} eq $fh) {
            delete $self->{requests}{$id}{fh}; 
            push(@{$self->{waiting}}, $id);
        }
    }
    
    # Remake the Round Robin array without the closed $fh
    @{$self->{rrs}} = grep { $_ ne $fh } @{$self->{rrs}};

    # Cleanup
    delete $self->{fhs}{$fh};
    delete $self->{inputs}{$fh};
    delete $self->{connect_args}{$fh};

    return $fh;
}

=head1 DIAGNOSTICS

TODO: Errors and warnings that the application can generate

=head1 AUTHOR

Troels Liebe Bentsen <tlb@rapanden.dk>, Jonas Jensen <jbj@knef.dk>

=head1 COPYRIGHT

Copyright(C) 2005-2009 Troels Liebe Bentsen

Copyright(C) 2005-2007 Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;

# vim: et sw=4 sts=4 tw=80
