package RPC::Async::URL;
use strict;
use warnings;

our $VERSION = '1.02';

=head1 NAME

RPC::Async::URL - Utility functions to handle URLs

=head1 SYNOPSIS

    use RPC::Async::URL;

    my $socket1 = url_connect("tcp://1.2.3.4:5678");
    my $socket2 = url_connect("exec://dir/file.pl --my-option");

=head1 METHODS

=cut

use Carp;

use Fcntl;
use English;
use File::Basename;
use Privileges::Drop;

use base "Exporter";
our @EXPORT = qw(url_connect url_disconnect url_listen url_explode 
    url_absolute);

use Socket;
use IO::Socket::INET;

# FIXME: update documentation to reflect changes.

=head2 B<url_connect($url)>

Turns an URL into a socket. Currently supported schemes are tcp://HOST:PORT and
exec://SHELL_COMMAND. A program executed with exec will have the option
--connected_fd=NUMBER on its command line, where NUMBER is the file descriptor
of a stream socket.

=cut

sub url_connect {
    my ($url, @args) = @_;

    if(ref $url ne '') {
        return $url;
    
    } elsif ($url =~ m{^tcp://(\d+\.\d+\.\d+\.\d+):(\d+)$}) {
        my ($ip, $port, $option, $timeout) = ($1, $2, @args);
        return (IO::Socket::INET->new(
            Proto    => 'tcp',
            PeerAddr => $ip,
            PeerPort => $port,
            Blocking => ($option?0:1),
            Timeout  => $timeout,
        ) or croak "Connecting to $url: $!");

    } elsif ($url =~ m{^unix(?:_(dgram))?://(.+)$}) {
        my ($dgram, $file, $nonblocking) = ($1, $2, @args);
        return (IO::Socket::UNIX->new(
            ($dgram?(Type => SOCK_DGRAM):()),
            Blocking  => ($nonblocking?0:1),
            Peer => $file,
        ) or croak "Connecting to $url: $!");
    
    } elsif ($url =~ m{^udp://(\d+\.\d+\.\d+\.\d+)?:?(\d+)?$}) {
        my ($ip, $port, $option) = ($1, $2, @args);
        return (IO::Socket::INET->new(
            Proto    => 'udp',
            Type => SOCK_DGRAM,
            ($ip?(PeerAddr => $ip):()),
            ($port?(PeerPort => $port):()),
            Blocking => ($option?0:1),
        ) or croak "Connecting to $url: $!");

       
    } elsif ($url =~ m{^(perl|perlroot|open2perl|open2perlroot)://(.+)$}) {
        my ($type, $path, $header, @callargs) = ($1, $2, @args);
        
        if(!defined $header) {
            # TODO: rename process to something a little more elegant then this.
            $header = q(
            use warnings;
            use strict;
            
            my $fd = shift;
            my $module = shift;
            if (not defined $fd) { die "Usage: $0 FILE_DESCRIPTOR MODULE_FILE [ ARGS ]"; }
            
            open my $sock, "+<&=", $fd or die "Cannot open fd $fd\n";
            
            sub init_clients {
                my ($rpc) = @_;
                $rpc->add_client($sock);
                return $sock;
            }
            
            $0="$module";
            
            do $module or die "Cannot load $module or $module did not return 1: $@\n";
            );
        }

        -e "$path" or die "File $path does not exist\n";
        my ($parent, $child);
        {
            local $^F = 1024; # avoid close-on-exec flag being set
            socketpair($parent, $child, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
                or die "socketpair: $!";
        }
        
        my ($readerOUT, $readerERR, $writerOUT, $writerERR);
        if($type =~ /open2/) {
            pipe $readerOUT, $writerOUT or die;
            pipe $readerERR, $writerERR or die;
        }

        my $client_pid = fork; 
        if ($client_pid == 0) {
            # child process
            close $parent;
            if($type =~ /open2/) {
                close $readerOUT or die;
                close $readerERR or die;
                open STDOUT, ">&", $writerOUT or die;
                open STDERR, ">&", $writerERR or die;
            }
            
            if($type !~ /perlroot/) {
                # FIXME: This should be done by drop_privileges function
                if($UID == 0 or $GID == 0) {
                    my $user = $ENV{SUDO_USER} || $ENV{RPC_ASYNC_URL_USER}
                        or die "RPC_ASYNC_URL_USER environment variable not set";
                    drop_privileges($user);
                }
            }

            my ($file, $dir) = fileparse $path;

            chdir $dir;
            # TODO: Do diff against default and only add what is not std. 
            exec $^X, (map { '-I'.$_ } @INC), "-we", $header, 
            fileno($child), 
                $file, @callargs;
            die "executing perl: $!\n";
        }
        close $child;
        if($type =~ /open2/) {
            close $writerOUT;
            close $writerERR;
        }

        fcntl $parent, F_SETFD, FD_CLOEXEC;

        if(wantarray) {
            return ($parent, $client_pid, $readerOUT, $readerERR);
        } else {
            return $parent;
        }

    } elsif ($url =~ m{^(open2)://(.+)$}) {
        my ($dir, $file) = ($1, $2);
        my ($type, $cmd, @callargs) = ($1, $2, @args);
        
        pipe my $readerOUT, my $writerOUT or die;
        pipe my $readerERR, my $writerERR or die;

        my $pid = fork;
        if ($pid == 0) {
            close $readerOUT or die;
            close $readerERR or die;
            
            open STDOUT, ">&", $writerOUT or die;
            open STDERR, ">&", $writerERR or die;
            exec $cmd, @callargs;
            die;
        }

        close $writerOUT;
        close $writerERR;
        return ($readerOUT, $readerERR, $pid);
    
    } elsif ($url =~ m{^cfd://(\d+)$}) {
        my ($fd) = ($1);

        open my $sock, "+<&=", $fd
            or die "Listening on $url: $!";
        return $sock;
    
    } else {
        croak "Cannot parse url: $url";
    }
}

# Make path absolute
sub url_absolute {
    my ($cwd, @urls) = @_;
    
    my @results;
    foreach my $url (@urls) {
        if($url =~ /^([^:]+\:\/\/)(.+)$/) {
            push(@results, "$1$cwd/$2");
        } else {
            return;
        }
    }
    
    if(wantarray) {
        return @results;
    } else {
        return $results[0];
    }
}

sub url_disconnect {
    my ($fh, $pid) = @_;
    waitpid $pid, 0 if $pid;
}

# TODO: add all types
sub url_explode {
    my ($url) = @_;

    if ($url =~ m{^(tcp|udp)://(\d+\.\d+\.\d+\.\d+):(\d+)$}) {
        return ($1,$2,$3);
    }
    
    return;
}

sub url_listen {
    my ($url, $nonblocking) = @_;
    
    if ($url =~ m{^tcp://(\d+\.\d+\.\d+\.\d+):(\d+)$}) {
        my ($ip, $port) = ($1, $2);
        return (IO::Socket::INET->new(
            Proto     => 'tcp',
            LocalAddr => $ip,
            LocalPort => $port,
            Blocking  => ($nonblocking?0:1),
            ReuseAddr => 1,
            Listen    => SOMAXCONN,
        ) or croak "Listening to $url: $!");

    } elsif ($url =~ m{^unix(?:_(dgram))?://(.+)$}) {
        my ($dgram, $file) = ($1, $2);
        unlink($file);
        return (IO::Socket::UNIX->new(
            ($dgram?(Type => SOCK_DGRAM):()),
            (!$dgram?(Listen => SOMAXCONN):()),
            Blocking  => ($nonblocking?0:1),
            Local => $file,
        ) or croak "Listening to $url: $!");

    } elsif ($url =~ m{^udp://(\d+\.\d+\.\d+\.\d+)?:?(\d+)?$}) {
        my ($ip, $port) = ($1, $2);
        return (IO::Socket::INET->new(
            Proto     => 'udp',
            ($ip?(LocalAddr => $ip):()),
            ($port?(LocalPort => $port):()),
            Blocking  => ($nonblocking?0:1),
            ReuseAddr => 1,
        ) or croak "Listening to $url: $!");
        
    } else {
        croak "Cannot parse url: $url";
    }
}

1;

=head1 AUTHOR

Jonas Jensen <jonas@infopro.dk>, Troels Liebe Bentsen <troels@infopro.dk>

=cut

=head1 COPYRIGHT

Copyright(C) 2005-2007 Troels Liebe Bentsen

Copyright(C) 2005-2007 Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

# vim: et sw=4 sts=4 tw=80
