#!/bin/sh

[ -d snakeoil-datalogger-1.0 ] || exit
[ -f snakeoil-datalogger_1.0.orig.tar.gz ] && rm snakeoil-datalogger_1.0.orig.tar.gz

tar cvzf snakeoil-datalogger_1.0.orig.tar.gz snakeoil-datalogger-1.0/*

cd snakeoil-datalogger-1.0

# (A)
debuild -us -uc

# (B)
# dpkg-buildpackage -A -uc