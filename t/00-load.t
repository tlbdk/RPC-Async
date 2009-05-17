use strict;
use warnings;

use Test::More tests => 1;

BEGIN {
    use_ok('RPC::Async');
}

diag( "Testing RPC::Async $RPC::Async::VERSION, Perl $], $^X" );
