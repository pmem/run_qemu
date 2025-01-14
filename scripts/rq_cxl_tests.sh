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

cd /root/ndctl || {
    printf '<0> FATAL: %s: no /root/ndctl directory' "$0" > /dev/kmsg
    exit 1
}

rm -rf build
meson setup build 2>/dev/kmsg
meson configure -Dtest=enabled -Ddestructive=enabled -Dasciidoctor=enabled build 2>/dev/kmsg
meson compile -C build 2>/dev/kmsg
meson install -C build 2>/dev/kmsg

echo "======= ${0##*/} ndctl build done ========" > /dev/kmsg

logfile="cxl-test-$(date +%Y-%m-%d--%H%M%S).log"

set +e
# disable make check here until ndctl re-enables it for libcxl
meson test -C build --suite cxl > "$logfile" 2>&1

# cat logfile > /dev/kmsg doesn't work (-EINVAL)
dumpfile()
{
	set +x
	while read -r line; do
		echo "$line" > /dev/kmsg
	done < "$1"
	set -x
}

dumpfile /root/ndctl/build/meson-logs/testlog.txt
echo "======= meson-test.log ========" > /dev/kmsg
dumpfile "$logfile"
echo "======= Done $0 ========" > /dev/kmsg
systemctl poweroff
