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

# /dev/kmsg has a 1024 bytes limit ("invalid write")
#
# When testing this limit interactively, /bin/printf may hit it while
# the shell's built-in printf command may not. That's because the shell
# may read or write less than 1024 bytes at a time. It's unpredictable
# which is why we need "-n $maxlen"
dumpfile()
{
( set +x
	local filename; filename=$(basename "$1")
	local filenamelen
	filenamelen=$(printf '%s' "$filename" | wc -c)
	local maxlen; maxlen=$((1024-filenamelen-6))
	while IFS= read -t 60 -n "$maxlen" -r line; do
		printf '<5>%s: %s\n' "$filename" "$line" > /dev/kmsg
	done < "$1"
)
}

dumpfile "$NDCTL"/build/meson-logs/testlog.txt
echo "======= meson-test.log ========" > /dev/kmsg
dumpfile "$logfile"
echo "======= Done $0 ========" > /dev/kmsg
