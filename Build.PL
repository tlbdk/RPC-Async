use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name       => 'RPC::Async',
    license           => 'perl',
    dist_author       => 'Jonas Jensen <jonas@infopro.dk>'
                        .',Troels Liebe Bentsen <troels@infopro.dk>',
    dist_version_from => 'lib/RPC/Async.pm',
    create_readme     => 1,
    build_requires => {
        'Test::More' => 0,
    },
    requires => { 
        'IO::EventMux' => '1.0'
    },
    add_to_cleanup => [ 
        'RPC-Async-*',
        'blib',
    ],
);

$builder->create_build_script();
