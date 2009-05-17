#!/usr/bin/env perl 
use strict;
use warnings;
use File::Slurp;
use Carp;
use Storable qw(thaw);

my $buffer = read_file('client-buffer.tmp', binmode => ':raw');

while(length($buffer) > 0) {
    deserialize_storable(\$buffer) or die "missing data\n";
}

sub deserialize_storable {
    croak "not a reference to the buffer" if (ref $_[0] ne 'SCALAR');
    croak "undefined variable in refrence" if !defined ${$_[0]};
    return if length(${$_[0]}) < 4;
    
    my $length = unpack("N", substr(${$_[0]}, 0, 4));
    if(length ${$_[0]} >= $length) {
        my $thawed = eval { thaw substr(${$_[0]}, 4, $length); };
        
        if($@) {
            for(my $i=0; $i<length(${$_[0]});$i++) {
                my $char = substr(${$_[0]}, $i, 1);
                #print sprintf("0x%02x(%03d)", ord($char), ord($char));
            }
            print "\n";
            die("Bad data in packet(".length(${$_[0]})."): $@");

        } elsif (ref $thawed eq "ARRAY" and @$thawed >= 1) {
            print "$length\n";
            # Remove deserialize part of buffer
            substr(${$_[0]}, 0, $length + 4) = '';
            return $thawed;
        }
    }
    
    return;
}
