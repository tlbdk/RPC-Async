#!/usr/bin/perl -w
use strict;

package RPC::Async::Client;

use Carp;
use Socket;
use IO::URL;
use RPC::Async::Util qw(make_packet append_data read_packet);
use RPC::Async::Coderef;
use Data::Dumper;

# FIXME: rename process to something a little more elegant then this.
my $cfd_rpc = q(
use warnings;
use strict;
use RPC::Async::Server;

my $fd = shift;
my $module = shift;
if (not defined $fd) { die "Usage: $0 FILE_DESCRIPTOR MODULE_FILE [ ARGS ]"; }

open my $sock, "+<&=", $fd or die "Cannot open fd $fd\n";

sub init_clients {
    my ($rpc) = @_;
    $rpc->add_client($sock);
}

$0="$module";

do $module or die "Cannot load $module: $@\n";
);

sub new {
    my ($class, $mux, $url, @args) = @_;

    my %self = (
        mux => $mux,
        requests => {},
        serial => -1,
        buf => undef,
        check_request => undef,
        check_response => undef,
        coderefs => {},
    );
    
    if ($url !~ /^(perl|perlroot):/) { 
        die "TODO: Only perl and perlroot protocol implemented";
    }

    my ($fh, $pid) = url_connect($url, $cfd_rpc, @args);
    $mux->add($fh, LineBuffered => 0);

    $self{fh} = $fh;
    $self{on_disconnect} = sub {
        
        # FIXME: Remove when everything is converted.
        if(UNIVERSAL::can($mux, "_my_send")) {
            $mux->disconnect($fh);
        } else {
            # OLD EventMux
            $mux->disconnect($fh, 1);
        }
        waitpid($pid, 0) if $pid;
    };

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

    if ($self->{on_disconnect}) {
        $self->{on_disconnect}->($self);
    }
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

        } elsif ($type eq "disconnect") {
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
    
    # FIXME: Use buffering code in EventMux and remove functions from Util.pm
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
