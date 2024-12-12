#!/bin/sh

set -e
set -x

MYDIR=$(dirname "$0")

main()
{
	cd "$MYDIR"
	rm -rf build
	meson setup build
	meson configure -Dtest=enabled -Ddestructive=enabled build
	meson compile -C build
	meson install -C build
}

main
