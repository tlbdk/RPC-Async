all: temptest

temptest:
	perl t/cfd.t

test:
	@perl -e 'use Test::Harness qw(&runtests); runtests @ARGV' t/*.t

humantest:
	echo "add_numbers n1=2 n2=3"|perl human-test.pl test-server.pl

.PHONY: temptest test humantest
