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

./autogen.sh
./configure --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib64 --enable-test --enable-destructive "$@"
make clean
make -j12
make install
echo "======= ${0##*/} ndctl build done ========" > /dev/kmsg

mod_list=(
	cxl_mock_mem
	cxl_pmem
	cxl_pci
	cxl_acpi
	cxl_core
	cxl_test
)

modprobe -a -r "${mod_list[@]}" > /dev/kmsg 2>&1
modprobe -a "${mod_list[@]}" > /dev/kmsg 2>&1
echo "======= ${0##*/} Module reload done ========" > /dev/kmsg

logfile="cxl-test-$(date +%Y-%m-%d--%H%M%S).log"

set +e
# disable make check here until ndctl re-enables it for libcxl
#make TESTS=libcxl check > "$logfile" 2>&1

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
echo "======= make-check.log ========" > /dev/kmsg
dumpfile "$logfile"
echo "======= Done $0 ========" > /dev/kmsg
systemctl poweroff
