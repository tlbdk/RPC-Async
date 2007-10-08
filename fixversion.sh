#!/bin/sh
find ./lib -name '*.pm'|xargs perl -i -pe "s/our\s*\\\$VERSION\s*=\s*'?\"?[^']*[^\"]*'?\"?\s*\;/our \\\$VERSION = '$1';/si;"
grep 'our \$VERSION' ./lib -R
