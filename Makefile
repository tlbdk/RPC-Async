all: temptest

test:
	./Build test

humantest:
	echo "add_numbers n1=2 n2=3"|perl human-test.pl test-server.pl

.PHONY: test humantest
