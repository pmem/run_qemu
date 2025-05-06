#!/bin/bash -ex
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

: "${NDCTL:=/root/ndctl}"

cleanup()
{
	systemctl poweroff
}

trap cleanup EXIT

set_default_message_loglevel()
(
	local console_loglevel default_loglevel
	# Leave console level unchanged
	console_loglevel=$(awk '{print $1}' /proc/sys/kernel/printk)
	# One notch lower than WARNING not to pollute test results
	default_loglevel=5
	echo "$console_loglevel $default_loglevel" > /proc/sys/kernel/printk
)
set_default_message_loglevel

sleep 4
echo "======= auto-running $0 ========" > /dev/kmsg

cd "$NDCTL" || {
    printf '<0>FATAL: %s: no %s directory' "$0" "$NDCTL" > /dev/kmsg
    exit 1
}

rm -rf build
# run_qemu.sh has already "pre-"compiled ndctl in the mkosi chroot, so
# we don't need anything verbose here, stderr is enough.
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

dumpfile "$NDCTL"/build/meson-logs/testlog.txt
echo "======= meson-test.log ========" > /dev/kmsg
dumpfile "$logfile"
echo "======= Done $0 ========" > /dev/kmsg
