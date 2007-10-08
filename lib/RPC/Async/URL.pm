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

use base "Exporter";
our @EXPORT = qw(url_connect url_disconnect url_listen url_explode drop_privileges);

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
        ) or carp "Connecting to $url: $!");

    } elsif ($url =~ m{^unix(?:_(dgram))?://(.+)$}) {
        my ($dgram, $file, $nonblocking) = ($1, $2, @args);
        return (IO::Socket::UNIX->new(
            ($dgram?(Type => SOCK_DGRAM):()),
            Blocking  => ($nonblocking?0:1),
            Peer => $file,
        ) or carp "Connecting to $url: $!");
    
    } elsif ($url =~ m{^udp://(\d+\.\d+\.\d+\.\d+)?:?(\d+)?$}) {
        my ($ip, $port, $option) = ($1, $2, @args);
        return (IO::Socket::INET->new(
            Proto    => 'udp',
            Type => SOCK_DGRAM,
            ($ip?(PeerAddr => $ip):()),
            ($port?(PeerPort => $port):()),
            Blocking => ($option?0:1),
        ) or carp "Connecting to $url: $!");

       
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
            }
            
            $0="$module";
            
            do $module or die "Cannot load $module: $@\n";
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
            
            if($type !~ /perlroot/) { drop_privileges(); }

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
        carp "Cannot parse url: $url";
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
    
    return undef;
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
            Listen    => 5,
        ) or carp "Listening to $url: $!");

    } elsif ($url =~ m{^unix(?:_(dgram))?://(.+)$}) {
        my ($dgram, $file) = ($1, $2);
        unlink($file);
        return (IO::Socket::UNIX->new(
            ($dgram?(Type => SOCK_DGRAM):()),
            (!$dgram?(Listen => 5):()),
            Blocking  => ($nonblocking?0:1),
            Local => $file,
        ) or carp "Listening to $url: $!");

    } elsif ($url =~ m{^udp://(\d+\.\d+\.\d+\.\d+)?:?(\d+)?$}) {
        my ($ip, $port) = ($1, $2);
        return (IO::Socket::INET->new(
            Proto     => 'udp',
            ($ip?(LocalAddr => $ip):()),
            ($port?(LocalPort => $port):()),
            Blocking  => ($nonblocking?0:1),
            ReuseAddr => 1,
        ) or carp "Listening to $url: $!");
        
    } else {
        carp "Cannot parse url: $url";
    }
}

=head2 B<drop_privileges()>

Drops privileges to the user defined in $ENV{'RPC_ASYNC_URL_USER'} 
or the caller if called with sudo.

=cut

sub drop_privileges {
    # Check if we are root and stop if we are not.
    if($UID != 0 and $EUID != 0 
            and $GID != 0 and $EGID != 0) {
        
        return ($UID, $GID);
    }
    
    my $user = $ENV{SUDO_USER} || $ENV{RPC_ASYNC_URL_USER}
        or die "RPC_ASYNC_URL_USER environment variable not set";

    my ($uid, $gid, $home, $shell) = (getpwnam($user))[2,3,7,8];
    
    if(!defined $uid or !defined $gid) {
        die("Could not find uid and gid user:$user");
    }
    
    $ENV{USER} = $user;
    $ENV{LOGNAME} = $user;
    $ENV{HOME} = $home;
    $ENV{SHELL} = $shell;

    # TODO add groups the the user we change to are in.
    my @gids = ();
    # Find out what pointer types to try with for gid_t(little og big endian)
    my @p = ((unpack("c2", pack ("i", 1)))[0] == 1 ? ("v", "V", "i") 
        : ("n", "N", "i"));
    foreach my $c (@p) {
        # FIXME: can be generated with "cd /usr/include;find . -name '*.h' -print | xargs h2ph"
        require "sys/syscall.ph";
        my $res = syscall (&SYS_setgroups, @gids+0, pack ("$c*", @gids));
        if($res == -1) {
            die("Could not clear groups: $!");
        }
    } 

    foreach(1..2) {
        $UID = $uid;
        $GID = $gid;
        $EUID = $uid;
        $EGID = "$gid $gid";
    }

    if($UID != $uid or $EUID != $uid 
            or $GID != $gid or $EGID != $gid) {
        
        die("Could not set current uid:$UID, gid:$GID, euid=$EUID, egid=$EGID "
            ."to uid:$uid, gid:$gid");
    }

    return ($uid, $gid);
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
