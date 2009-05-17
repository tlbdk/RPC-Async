use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name        => 'RPC::Async',
    license            => 'perl',
    dist_author        => 'Troels Liebe Bentsen <troels@infopro.dk>',
    dist_version_from  => 'lib/RPC/Async.pm',
    create_readme      => 1,
    create_makefile_pl => 'passthrough',
    requires => { 
        'perl'             => '>= 5.8.0',
        'IO::EventMux'     => '>= 2.02',
        'Privileges::Drop' => 0,
        'File::Basename'   => 0,
    },
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup => [ 
        'RPC-Async-*',
        'Makefile',
        'blib',
    ],
);

$builder->create_build_script();
