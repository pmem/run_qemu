#!/bin/bash -ex
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

cleanup()
{
	systemctl poweroff
}

trap cleanup EXIT

sleep 4
echo "======= auto-running $0 ========" > /dev/kmsg

cd /root/ndctl || exit

rm -rf build
meson setup build 2>/dev/kmsg
meson configure -Dtest=enabled -Ddestructive=enabled -Dasciidoctor=enabled build 2>/dev/kmsg
meson compile -C build 2>/dev/kmsg
meson install -C build 2>/dev/kmsg

mod_list=( 
	nfit_test
)

modprobe -r "${mod_list[@]}"

logfile="ndctl-test-$(date +%Y-%m-%d--%H%M%S).log"

set +e
meson test -C build > "$logfile" 2>&1

# cat logfile > /dev/kmsg doesn't work (-EINVAL)
dumpfile()
{
	set +x
	while read -r line; do
		echo "$line" > /dev/kmsg
	done < "$1"
	set -x
}

dumpfile test/test-suite.log
echo "======= meson-test.log ========" > /dev/kmsg
dumpfile "$logfile"
echo "======= Done $0 ========" > /dev/kmsg
systemctl poweroff
