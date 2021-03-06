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

mod_list=( 
	nfit_test
	device_dax
	dax_pmem
	dax_hmem
	nd_pmem
	dax_pmem_core
	kmem
	nfit
	nd_blk
	nd_btt
	nd_e820
	libnvdimm
	nfit_test_iomap
)

ndctl disable-namespace all
ndctl disable-region all
modprobe -a -r "${mod_list[@]}"
modprobe -a "${mod_list[@]}"
ndctl enable-region all
ndctl wait-scrub

logfile="ndctl-test-$(date +%Y-%m-%d--%H%M%S).log"

set +e
make check > "$logfile" 2>&1
ndctl wait-scrub

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
