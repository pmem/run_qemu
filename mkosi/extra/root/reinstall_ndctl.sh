#!/bin/sh

#shellcheck disable=SC3043

set -e
set -x

MYDIR=$(dirname "$0")

main()
{
	local ndctl_src="$1"
	test -n "$ndctl_src" || ndctl_src="$MYDIR"/ndctl

	cd "$ndctl_src"
	rm -rf build
	meson setup     -Dtest=enabled -Ddestructive=enabled build
	meson compile -C build
	meson install -C build
}

main "$@"
