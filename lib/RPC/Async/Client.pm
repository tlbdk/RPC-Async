#!/usr/bin/perl -w
use strict;

package RPC::Async::Client;

use Carp;
use Socket;
use RPC::Async::Util qw(make_packet append_data read_packet);
use RPC::Async::Coderef;
use Data::Dumper;

sub new {
    my ($class, $mux, $fh) = @_;

    my %self = (
        mux => $mux,
        requests => {},
        serial => -1,
        buf => undef,
        check_request => undef,
        check_response => undef,
        coderefs => {},
    );
    
    $mux->add($fh);
    $self{fh} = $fh;

    return bless \%self, (ref $class || $class);
}

sub AUTOLOAD {
    my $self = shift;
    if (@_ < 1) { return; }

    our $AUTOLOAD;
    my $procedure = $AUTOLOAD;
    $procedure =~ s/.*:://;

    return $self->call($procedure, @_);
}

sub call {
    my ($self, $procedure, @args) = @_;
    my $callback = pop @args;

    if ($self->{check_request}
            and not $self->{check_request}->($procedure, @args)) {
        croak "Invalid procedure or arguments in call to $procedure\n";
    }

    @args = $self->_encode_args(@args);

    my $id = $self->_unique_id;
    $self->{requests}{$id} = $callback;

    #print "RPC::Async::Client sending: $id $procedure @args\n";
    $self->{mux}->send($self->{fh}, make_packet([ $id, $procedure, @args ]));
}

sub check_request {
    $_[0]->{check_request} = $_[1] if @_ > 1;
    $_[0]->{check_request};
}

sub check_response {
    $_[0]->{check_response} = $_[1] if @_ > 1;
    $_[0]->{check_response};
}

sub disconnect {
    my ($self) = @_;
    $self->{mux}->kill($self->{fh});
}

sub has_requests {
    my ($self, $event) = @_;
    return scalar %{$self->{requests}};
}

sub has_coderefs {
    my ($self, $event) = @_;
    return scalar %{$self->{coderefs}};
}

sub io {
    my ($self, $event) = @_;

    if ($event->{fh} and $event->{fh} == $self->{fh}) {
        my $type = $event->{type};
        if ($type eq "read") {
            #print "RPC::Async::Client got ", length $event->{data}, " bytes\n";
            $self->_handle_read($event->{data});

        } elsif ($type eq "closed") {
            die __PACKAGE__ .": server disconnected\n";
        }

        return undef;

    } else {
        return $event;
    }
}

# For debugging
sub dump_requests {
    my ($self) = @_;
    return Dumper($self->{requests});
}

sub _handle_read {
    my ($self, $data) = @_;
    
    # TODO: Use buffering code in EventMux and remove functions from Util.pm
    append_data(\$self->{buf}, $data);
    while (my $thawed = read_packet(\$self->{buf})) {
        if (ref $thawed eq "ARRAY" and @$thawed >= 1) {
            my ($id, @args) = @$thawed;
            my $callback = delete $self->{requests}{$id};
            # TODO: test check_response

            if (defined $callback) {
                #print __PACKAGE__, ": callback(@args)\n";
                $callback->(@args);

            } elsif (exists $self->{coderefs}{$id}) {
                my ($command, @cb_args) = @args;
                if ($command eq "destroy") {
                    delete $self->{coderefs}{$id};
                } elsif ($command eq "call") {
                    $self->{coderefs}{$id}->(@cb_args);
                } else {
                    warn __PACKAGE__.": Unknown command for callback";
                }

            } else {
                warn __PACKAGE__.": Spurious reply to id $id\n";
            }
        } else {
            warn __PACKAGE__.": Bad data in thawed packet";
        }
    }
}

sub _unique_id {
    my ($self) = @_;

    $self->{serial}++;
    return $self->{serial} &= 0x7FffFFff;
}

sub _encode_args {
    my ($self, @args) = @_;

    return map {
        my $arg = $_;
        if (not ref $arg) {
            $arg;
        } elsif (ref $arg eq "ARRAY") {
            [ $self->_encode_args(@$arg) ];
        } elsif (ref $arg eq "HASH") {
            my %h;
            keys %h = scalar keys %$arg; # preallocate buckets
            foreach my $key (keys %$arg) {
                my ($v) = $self->_encode_args($arg->{$key});
                $h{$key} = $v;
            }
            \%h;
        } elsif (ref $arg eq "Regexp") {
           #TODO: Copy over regexp options /ig etc.
           $arg =~ /:(.*)\)$/;
           $1;
        } elsif (ref $arg eq "REF") {
            my ($v) = $self->_encode_args($$arg);
            \$v;
        } elsif (ref $arg eq "CODE") {
            my $id = $self->_unique_id;
            $self->{coderefs}{$id} = $arg;
            RPC::Async::Coderef->new($id);
        } else {
            $arg;
        }
    } @args;
}

1;
# vim: et sw=4 sts=4 tw=80
