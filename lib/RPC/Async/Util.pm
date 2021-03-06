package RPC::Async::Util;
use strict;
use warnings;
use Carp;

our $VERSION = '2.00';

=head1 NAME

RPC::Async::Util - util module of the asynchronous RPC framework

=cut

use base "Exporter";
use Class::ISA;
use Storable qw(nfreeze thaw);
use RPC::Async::Coderef;

our @EXPORT_OK = qw(queue_timeout expand encode_args decode_args unique_id);

=head1 METHODS

=cut

=head2 C<serialize_storable($object)>

Returns a storable serialized data from $object with 32bit network order
length bytes in the start of data.

=cut

sub serialize_storable {
    my $data = nfreeze($_[0]);
    $data = pack("N", length($data)).$data;
    croak "RPC: Freeze to small: ".Dumper($_[0]) if length($data) < 12;
    return $data;
}

=head2 C<deserialize_storable(\$data, $max_size)>

Returns a deserialized $object from reference to $data. $data needs to be encoded
with storable and start with 32bit network order length bytes. $data is cut by
the number of bytes consumed to generate the $object.

=cut

# TODO: Take maximum data size as a argument so we can throw 
sub deserialize_storable {
    croak "RPC: not a reference to the buffer" if (ref $_[0] ne 'SCALAR');
    croak "RPC: undefined variable in refrence" if !defined ${$_[0]};
    return if length(${$_[0]}) < 4;
    
    my $length = unpack("N", substr(${$_[0]}, 0, 4));
    croak "RPC: length bytes size is to big" if $length > $_[1];
    if(length ${$_[0]} >= $length) {
        my $thawed = eval { thaw substr(${$_[0]}, 4, $length); };
        
        if($@) {
            for(my $i=0; $i<length(${$_[0]});$i++) {
                my $char = substr(${$_[0]}, $i, 1);
                #print sprintf("0x%02x(%03d)", ord($char), ord($char));
            }
            #print "\n";
            die("RPC: Bad data in packet(".length(${$_[0]})."): $@");

        } elsif (ref $thawed eq "ARRAY" and @$thawed >= 1) {
            # Remove deserialize part of buffer
            substr(${$_[0]}, 0, $length + 4, '');
            return $thawed;
        }
    }
    
    return;
}

=head2 C<unique_id(\$serial))>

TODO: Write more

=cut

sub unique_id {
    ${$_[0]}++;
    return ${$_[0]} &= 0x7FffFFff;
}


=head2 C<output($fh, $type, $data)>

TODO: Write more

=cut

sub output {
    my ($fh, $type, $data) = @_;
    print uc($type)."($fh): $data";
}


=head2 C<queue_timeout($timeouts, $timeout, @info)>

TODO: Write more

=cut

sub queue_timeout {
    my ($timeouts, $timeout, @info) = @_;
    
    if(@{$timeouts} == 0 or $timeout >= $timeouts->[-1][0]) {
        # The queue is empty or item belongs in the end of the queue
        push(@{$timeouts}, [$timeout, @info]);
    } else {
        # Try to insert the item from the back
        for(my $i=int(@{$timeouts})-1; $i >= 0; $i--) {
            if($timeout >= $timeouts->[$i][0]) {
                # The item fits somewhere in the middle
                splice(@{$timeouts}, $i+1, 0, [$timeout, @info]);
                last;
            } elsif ($i == 0) {
                # The item was small than anything else
                unshift (@{$timeouts}, [$timeout, @info]);
            }
        }
    }
}

=head2 C<encode_args($self, \$args)>

TODO: Write more

=cut

sub encode_args {
    my ($self, $args, $filter) = @_;

    my $error = $filter 
        ? sub { $_[0] = "could not encode unknown : ".ref($_[0]); } 
        : sub { croak "RPC(encode): Unknown scalar type ".ref($_[0]); }; 

    return tree_filter($args, sub {
        my $type = ref($_[0]);
   
        if ($type eq "Regexp") {
            $_[0] = RPC::Async::Regexp->new($_[0]);

        } elsif ($type eq "CODE") {
            my $id = unique_id(\$self->{serial});
            $self->{coderefs}{$id} = $_[0];
            $_[0] = RPC::Async::Coderef->new($id);

        } elsif (UNIVERSAL::isa($_[0], "IO::Socket")) {
            # TODO: Allow this for unix domain sockets:
            #   * As pass fh over unix domain socket call
            #   * Path to unix domain socket and open in decode fase
            if($filter) { 
                $_[0] = 'could not encode IO::Socket';
            } else {
                croak "RPC: Cannot pass IO::Socket objects";
            }
            
            return 1;

        } elsif (UNIVERSAL::isa($_[0], "GLOB")) {
            # TODO: Allow this for unix domain sockets:
            #   * As pass fh over unix domain socket call
            #   * Path to unix domain socket and open in decode fase
            if($filter) { 
                $_[0] = 'could not encode GLOB';
            } else {
                croak "RPC: Cannot pass GLOB objects";
            }
            
            return 1;

        } else {
            return;
        }

    }, $error);
}

=head2 C<decode_args($self, $fh, \$args)>

TODO: Write more

=cut

sub decode_args {
    my ($self, $fh, $args, $filter) = @_;

    my $error = $filter 
        ? sub { $_[0] = "could not decode unknown : ".ref($_[0]); } 
        : sub { croak "RPC(decode): Unknown scalar type ".ref($_[0]); }; 

    return tree_filter($args, sub {
        my $type = ref($_[0]);

        if (UNIVERSAL::isa($_[0], "RPC::Async::Regexp")) {
            $_[0] = $_[0]->build();

        } elsif (UNIVERSAL::isa($_[0], "RPC::Async::Coderef")) {
            #use Data::Dumper; print Dumper({ obj => $$obj });
            my $id = $_[0]->id();

            # Setup the callbacks to push on the waiting queue
            $_[0]->set_call(sub {
                push(@{$self->{waiting}}, [$fh, $id, "call", @_])
            });
            $_[0]->set_destroy(sub {
                push(@{$self->{waiting}}, [$fh, $id, "destroy", @_])
            });

        } else {
            return;
        }

    }, $error);
}

sub tree_filter {
    my ($args, $filter, $error) = @_;
    my $result;

    my %refs;
    
    my @walk = (\$args);
    while(my $obj = shift @walk) {
        my $type = ref($$obj);

        if($filter->($$obj, \%refs)) {
            # Handled by filter - do nothing 
   
        } elsif($$obj and exists $refs{$$obj}) {
            $$obj = $refs{$$obj}; # Handle cicular refrences
        
        } elsif ($type eq 'SCALAR' or $type eq '') {
            # IGNORE - just a simple copy
    
        } elsif ($type eq 'HASH') { # Hash
            $$obj = $refs{$$obj} = {%{$$obj}};  # Copy the hash, save old ref
            push(@walk, map { \$_ } values %{$$obj});
        
        } elsif ($type eq 'ARRAY') { # Array
            $$obj = $refs{$$obj} = [@{$$obj}];  # Copy the array, save old ref
            push(@walk, map { \$_ } @{$$obj});
        
        } else {
            $error->($$obj);
        }
        
        # Make sure we make a ref to the first we are working with
        $result = $$obj if !defined $result; 
    }
    
    #use Data::Dumper; print Dumper($args);
    return $result;
}



=head2 expand($ref, $in)

Expands and normalizes the def_* input and output definitions to a unified
order and naming convention.

=cut

sub expand {
    my ($ref, $in) = @_;
    
    treewalk($ref,
        sub { 
            if($in and ${$_[0]} =~ s/^(.+?)_(\d+)$/$2$1/) {
                return ${$_[0]};
            } elsif($in) {
                my $count = 0;
                return map { sprintf "%02d$_", $count++ } split /\|/, ${$_[0]};
            } else {
                return split /\|/, ${$_[0]};
            }
        }, 
        sub{ 
            no warnings 'uninitialized'; # So we can use $1 even when we got no match
            ${$_[0]} =~ s/^(?:latin1)/latin1string/;
            ${$_[0]} =~ s/^(?:str(?:ing)?)|(:?utf8)/utf8string/;
            ${$_[0]} =~ s/^(?:(u)?int(?:eger)?(?:8))|(?:byte)|(?:char)/$1integer8/;
            ${$_[0]} =~ s/^(?:(u)?int(?:eger)?(?:16))|(?:short)/$1integer16/;
            ${$_[0]} =~ s/^(?:(u)?int(?:eger)?(?:(:)|(?:32)|$))|(?:long)/$1integer32$2/; # Default to 32bit
            ${$_[0]} =~ s/^(?:(u)?int(?:eger)?(?:64))|(?:longlong)/$1integer64/;
            ${$_[0]} =~ s/^(?:float)?(?:(:)|(?:32)|$)/float32$1/; # Default to 32bit
            ${$_[0]} =~ s/^(?:float64)|(?:double)/float64$1/;
            ${$_[0]} =~ s/^(?:bin)|(?:data)/binary/;
            ${$_[0]} =~ s/^(?:bool)/boolean/;
        } 
    );

    return $ref;
}

#use Misc::Common qw(treewalk); # FIXME: Put in own module instead

=head2 treewalk($tree, $replace_key, $replace_value)

Sub used to walk a tree structure.

=cut

sub treewalk {
    my ($tree, $replace_key, $replace_value) = @_;
    $replace_key = $replace_key?$replace_key:sub{};
    $replace_value = $replace_value?$replace_value:sub{};

    my @walk = ($tree);
    while(my $branch = shift @walk) {
        if(ref($branch) eq 'HASH') {
            foreach my $key (keys %{$branch}) {
                my $newkey = $key;
                if(my @results = grep { $_ } $replace_key->(\$newkey)) {
                    if(@results > 1) {
                        if (ref($branch->{$newkey}) eq '') {
                            $replace_value->(\$branch->{$key});
                            foreach my $result (@results) {
                                $branch->{$result} = $branch->{$key};
                            }
                        } else {
                            foreach my $result (@results) {
                                $branch->{$result} = $branch->{$key};
                            }
                        }
                        $newkey = $results[0];
                        delete($branch->{$key});

                    } elsif($newkey ne $key) {
                        $branch->{$newkey} = $branch->{$key};
                        delete($branch->{$key});
                    }
                }

                if (ref($branch->{$newkey}) eq 'HASH') {
                    push(@walk, $branch->{$newkey});
                } elsif (ref($branch->{$newkey}) eq 'ARRAY') {
                    push(@walk, $branch->{$newkey});
                } else {
                    $replace_value->(\$branch->{$newkey});
                }

            }
        } elsif(ref($branch) eq 'ARRAY') {
            for(my $i=0;$i<int(@{$branch});$i++) { 
                if(ref($branch->[$i]) eq 'ARRAY') {
                    push(@walk, $branch->[$i]);
                } elsif(ref($branch->[$i]) eq 'HASH') {
                    push(@walk, $branch->[$i]);
                } else {
                    $replace_value->(\$branch->[$i]);
                }
            }
        }
    }
}

=head1 AUTHOR

Jonas Jensen <jbj@knef.dk>, Troels Liebe Bentsen <tlb@rapanden.dk> 

=head1 COPYRIGHT

Copyright(C) 2005-2009 Troels Liebe Bentsen

Copyright(C) 2005-2007 Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
# vim: et sw=4 sts=4 tw=80
