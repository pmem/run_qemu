#!/bin/bash -Ee
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

# default config
: "${builddir:=./qbuild}"
rootpw="root"
rootfssize="10G"
espsize="512M"
nvme_size="1G"
efi_mem_size="2"   #in GiB
legacy_pmem_size="2"   #in GiB
pmem_size="16384"  #in MiB
pmem_label_size=2  #in MiB
pmem_final_size="$((pmem_size + pmem_label_size))"
: "${qemu:=qemu-system-x86_64}"
: "${gdb:=gdb}"
: "${ndctl:=$(readlink -e ~/git/ndctl)}"
selftests_home=root/built-selftests
mkosi_bin="mkosi"
mkosi_opts=("-i" "-f")
console="ttyS0"
accel="kvm"

# some canned hmat defaults - make configurable as/when needed
# terminology:
# local = attached directly to the socket in question
# far = memory controller is on 'this' socket, but distinct numa node/pxm domain
# cross = memory controller across sockets
# mem = memory node and pmem = NVDIMM node, as before
# Units: lat(ency) - nanoseconds, bw - MB/s
local_mem_lat=5
local_mem_bw=2000
far_mem_lat=10
far_mem_bw=1500
cross_mem_lat=20
cross_mem_bw=1000
# local_pmem is not a thing. In these configs we always give pmems their own node
far_pmem_lat=30
far_pmem_bw=1000
cross_pmem_lat=40
cross_pmem_bw=500

# similarly, some canned SLIT defaults
local_mem_dist=10
far_mem_dist=12
cross_mem_dist=21
far_pmem_dist=17
cross_pmem_dist=28

# CXL device params
cxl_addr="0x4c00000000"
cxl_backend_size="512M"
cxl_t3_size="256M"
cxl_label_size="128K"

num_build_cpus="$(($(getconf _NPROCESSORS_ONLN) + 1))"
rsync_opts=("--delete" "--exclude=.git/" "--exclude=build/" "-L" "-r")

qemu_dir=$(dirname "$(dirname "$qemu")")
if [[ $qemu_dir != . ]]; then
	qemu_img="$qemu_dir/qemu-img"
	if [ ! -f "$qemu_img" ]; then
		qemu_img="$qemu_dir/build/qemu-img"
	fi
	qmp="$qemu_dir/scripts/qmp/qmp-shell"
else
	qemu_img="qemu-img"
	# Allows to not find the command qmp-shell
	set +Ee
	qmp=$(command -v qmp-shell)
	# Do not leave qmp variable empty
	if [ -z "$qmp" ]; then
		qmp="qmp"
	fi
	# Back to the original setup
	set -Ee
fi

fail()
{
	# shellcheck disable=SC2059
	printf "$@"
	printf '\n'
	exit 1
}

script_dir="$(cd "$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")" && pwd)"
parser_generator="${script_dir}/parser_generator.m4"
parser_lib="${script_dir}/run_qemu_parser.sh"
if [ ! -e "$parser_lib" ] || [ "$parser_generator" -nt "$parser_lib" ]; then
	if command -V argbash > /dev/null; then
		argbash --strip user-content "$parser_generator" -o "$parser_lib"
	else
		fail "error: please install argbash"
	fi
fi
# shellcheck source=run_qemu_parser.sh
. "${script_dir}/run_qemu_parser.sh" || fail "Couldn't find $parser_lib"

if [ ${_arg_working_dir:0:1} == "-" ]; then
	printf "Invalid option '%s'\n" "$_arg_working_dir"
	printf "Try 'run_qemu.sh --help' for more information.\n"
	exit 1
fi

cxl_test_script="$script_dir/scripts/rq_cxl_tests.sh"
cxl_results_script="$script_dir/scripts/rq_cxl_results.sh"
nfit_test_script="$script_dir/scripts/rq_nfit_tests.sh"
nfit_results_script="$script_dir/scripts/rq_nfit_results.sh"

# /etc/os-release is what mkosi "detect_distribution()" uses too.
get_os()
{
    awk -F= 'BEGIN  { notfound=1 }
             /^ID=/ { print $2; notfound=0; exit }
             END    { exit notfound }'     /etc/os-release
}

# distro:  if any, user input passed to mkosi configuration line: "Distribution=$distro"
# rev:     if any, user input passed to mkosi configuration line: "Release=$rev"
# _distro: variable private to this script. Defaults to build OS like mkosi does.
if [ -n "$distro" ]; then
    _distro=${distro}
    distribution_def="Distribution=$distro"
else
    _distro=$(get_os)
    distribution_def=''
fi

if [ -n "$rev" ]; then
    release_def="Release=$rev"
else
    release_def=''
fi

# distro specific variables
distro_vars="${script_dir}/${_distro}_vars.sh"

# shellcheck source=fedora_vars.sh
# shellcheck source=arch_vars.sh
# shellcheck source=ubuntu_vars.sh
[ -f "$distro_vars" ] && source "$distro_vars"

pushd "$_arg_working_dir" > /dev/null || fail "couldn't cd to $_arg_working_dir"

set_valid_mkosi_ver()
{
	"$mkosi_bin" --version
	mkosi_ver="$("$mkosi_bin" --version | awk '/mkosi/{ print $2 }')"
	# drop the "~devel" suffix present in __version__ when running from
	# pre-v25 versions
	mkosi_ver="${mkosi_ver%%~*}"
	# only look at the major version
	mkosi_ver="${mkosi_ver%%.*}"
	# Make sure we got a number
	test "$mkosi_ver" -eq "$mkosi_ver" ||
		fail 'mkosi version %s is not a number' "$mkosi_ver"
}
set_valid_mkosi_ver

# [Packages] was renamed to [Content] in v11, see mkosi/NEWS.md
test "$mkosi_ver" -ge 11 ||
	fail 'mkosi version 11 or above is required, found %s' "$mkosi_ver"

kill_guest()
{
	# sometimes this can be inadvertently re-entrant
	sleep 1

	if [ -e "$qmp_sock" ]; then
		"$qmp" "$qmp_sock" <<< "quit" > /dev/null
		if (( _arg_quiet < 3 )); then
			echo "run_qemu: Killed guest via QMP"
		fi
	fi
}

guest_alive()
{
	[ -e "$qmp_sock" ]
}

loop_teardown()
{
	loopdev="$(sudo losetup --list | grep "$_arg_rootfs" | awk '{ print $1 }')"
	if [ -b "$loopdev" ]; then
		sudo umount "${loopdev}p1" || true
		sudo umount "${loopdev}p2" || true
		sudo losetup -d "$loopdev"
	fi
}

cleanup()
{
	if [ -x "$qmp" ]; then
		kill_guest
	fi
	loop_teardown
	set +x
}

# In POSIX theory, the shell automatically saves for us the $? of the
# "last command before the trap"; see special built-in 'exit' in
# "2. Shell Command Language" on opengroup.org. However this is
# too subtle (two concurrent '$?' now?) and difficult to trace,
# especially when set -e interferes!  So, just save that $? ourselves
# and show it clearly in --debug / set -x mode.
trap 'exit_handler $?' EXIT
exit_handler()
{
	# 42 "breadcrumb" if forgotten and missing
	local err="${1-42}"
	# "set -e" can trigger _twice_ and abort the EXIT handler again!
	#   https://unix.stackexchange.com/questions/667368/bash-change-exit-status-in-trap
	# So, don't let some cleanup failure hide the real $err:
	cleanup || true
	exit "$err"
}

set_topology()
{
	case "$1" in
	1S|tiny)
		num_nvmes=0
		num_nodes=1
		num_mems=0
		num_pmems=0
		num_efi_mems=0
		num_legacy_pmems=0
		;;
	2S0|small0)
		num_nvmes=0
		num_nodes=2
		num_mems=0
		num_pmems=2
		num_efi_mems=0
		num_legacy_pmems=0
		;;
	2S|small)
		num_nvmes=0
		num_nodes=2
		num_mems=2
		num_pmems=2
		num_efi_mems=1
		num_legacy_pmems=1
		;;
	2S4|med*)
		num_nvmes=0
		num_nodes=2
		num_mems=4
		num_pmems=4
		num_efi_mems=1
		num_legacy_pmems=2
		;;
	4S|large)
		num_nvmes=0
		num_nodes=4
		num_mems=4
		num_pmems=4
		num_efi_mems=2
		num_legacy_pmems=2
		;;
	8S|huge)
		num_nvmes=0
		num_nodes=8
		num_mems=8
		num_pmems=8
		num_efi_mems=2
		num_legacy_pmems=2
		;;
	16S|insane)
		num_nvmes=0
		num_nodes=16
		num_mems=0
		num_pmems=16
		num_efi_mems=2
		num_legacy_pmems=2
		;;
	16Sb|broken)
		num_nvmes=0
		num_nodes=16
		num_mems=0
		num_pmems=32
		num_efi_mems=2
		num_legacy_pmems=2
		;;
	gcp)
		num_nvmes=0
		num_nodes=1
		num_mems=0
		num_pmems=0
		num_efi_mems=0
		num_legacy_pmems=0
		;;
	*)
		printf "error: invalid preset: %s\n" "$1"
		exit 1
		;;
	esac

	# After presets override individuals
	if [[ "$_arg_nvmes" ]]; then
		num_nvmes="$_arg_nvmes"
	fi
	if [[ "$_arg_nodes" ]]; then
		num_nodes="$_arg_nodes"
	fi
	if [[ "$_arg_mems" ]]; then
		num_mems="$_arg_mems"
	fi
	if [[ "$_arg_pmems" ]]; then
		num_pmems="$_arg_pmems"
	fi
	if [[ "$_arg_efi_mems" ]]; then
		num_efi_mems="$_arg_efi_mems"
	fi
	if [[ "$_arg_legacy_pmems" ]]; then
		num_legacy_pmems="$_arg_legacy_pmems"
	fi
}

process_options_logic()
{
	if [[ $_arg_debug == "on" ]]; then
		set -x
	fi
	if [[ $_arg_cxl_test_run == "on" ]]; then
		_arg_cxl="on"
		_arg_cxl_debug="on"
		_arg_cxl_test="on"
		if [[ ! $_arg_autorun ]]; then
			_arg_autorun="$cxl_test_script"
		fi
		if [[ ! $_arg_post_script ]]; then
			_arg_post_script="$cxl_results_script"
		fi
		if [[ ! $_arg_log ]]; then
			_arg_log="/tmp/rq_${_arg_instance}.log"
		fi
		if [[ $_arg_timeout == "0" ]]; then
			_arg_timeout="15"
		fi
	fi
	if [[ $_arg_cxl_test == "on" ]]; then
		check_ndctl_dir
	fi
	if [[ $_arg_nfit_test_run == "on" ]]; then
		_arg_nfit_test="on"
		set_topology "med"
		if [[ ! $_arg_autorun ]]; then
			_arg_autorun="$nfit_test_script"
		fi
		if [[ ! $_arg_post_script ]]; then
			_arg_post_script="$nfit_results_script"
		fi
		if [[ ! $_arg_log ]]; then
			_arg_log="/tmp/rq_${_arg_instance}.log"
		fi
		if [[ $_arg_timeout == "0" ]]; then
			_arg_timeout="20"
		fi
	fi
	if [[ $_arg_git_qemu == "on" ]]; then
		qemu=~/git/qemu/x86_64-softmmu/qemu-system-x86_64
		qemu_img=~/git/qemu/qemu-img
		qmp=~/git/qemu/scripts/qmp/qmp-shell
		# upstream changed where binaries go recently
		if [ ! -f "$qemu_img" ]; then
			qemu=~/git/qemu/build/qemu-system-x86_64
			qemu_img=~/git/qemu/build/qemu-img
		fi
		if [ ! -x "$qemu" ]; then
			fail "expected to find $qemu"
		fi
	fi
	if [[ $_arg_curses == "on" ]]; then
		dispmode="-curses"
	else
		dispmode="-nographic"
	fi

	set_topology "$_arg_preset"

	if [[ $_arg_nfit_test == "on" ]]; then
		if (( _arg_quiet < 3 )); then
			printf "setting preset to 'med' for nfit_test\n"
		fi
		set_topology "med"
	fi
	if [[ "$_arg_mirror" ]]; then
		mkosi_opts+=(-m "$_arg_mirror")
	fi
	if [[ $_arg_kcmd_replace && ! -f "$_arg_kcmd_replace" ]]; then
		fail "File not found: $_arg_kcmd_replace"
	fi
	if [[ $_arg_kcmd_append && ! -f "$_arg_kcmd_append" ]]; then
		fail "File not found: $_arg_kcmd_append"
	fi
	if [[ $_arg_gdb_qemu == "on" ]] && [[ $gdb == "gdb" ]]; then
		gdb_extra=("-ex" "handle SIGUSR1 noprint nostop")
	fi
	if [[ $_arg_timeout -gt 0 ]]; then
		if [[ ! -x "$qmp" ]]; then
			fail " --timeout requires 'qmp-shell'. $qmp not found"
		fi
		_arg_qmp="on"
	fi
	if [[ $_arg_qmp == "on" ]]; then
		qmp_sock="/tmp/run_qemu_qmp_$_arg_instance"
	fi
	# canonicalize _arg_log here so that relative paths don't end up in
	# builddir which can be surprising.
	if [[ $_arg_log ]]; then
		_arg_log=$(realpath "$_arg_log")
	fi
	if [[ $_arg_gcp == "on" ]]; then
		# GCP wants 1GiB aligned images.
		# 10G - ~256M (ESP) to make the resulting image exactly 10GiB
		rootfssize=10468941824
		rootpw="$(openssl rand -base64 12)"
		console="ttyS0,38400n8d"
		set_topology "gcp"
	fi

	num_cxl_pmems="$_arg_cxl_pmems"
	if (( $num_cxl_pmems > 4 )); then
		echo "error: a maximum of 4 CXL memdevs allowed"
		exit 1
	fi
	num_cxl_vmems="$((4 - $num_cxl_pmems))"

	if [[ $_arg_kvm = "off" ]]; then
		accel="tcg"
	fi

	# For legacy reasons the "$ndctl" variable has been the "real" switch
	# as --ndctl-build is ON by default - and true most of the time.
	if [ -n "$ndctl" ]; then
		check_ndctl_dir
	fi
}

make_install_kernel()
{
	local inst_path="$1"

	test -n "$kver" || { # can't use fail() when inlined with declare -f
		>&2 printf 'ERROR: Undefined $kver in make_install_kernel()\n'
		exit 1
	}

	cat arch/x86_64/boot/bzImage > "$inst_path"/vmlinuz-"$kver"
	cp System.map "$inst_path"/System.map-"$kver"
	ln -fs vmlinuz-"$kver" "$inst_path"/vmlinuz
	ln -fs System.map-"$kver" "$inst_path"/System.map
}

install_build_initrd()
{
	inst_prefix="$builddir/mkosi.extra"
	inst_path="$builddir/mkosi.extra/boot"

	make INSTALL_HDR_PATH="$inst_prefix/usr" headers_install
	make_install_kernel "$inst_path"

	# Much of the script relies on a kernel named vmlinuz-$kver. This is
	# distro specific as the default from Linux is simply "vmlinuz". Adjust
	# that here.
	[ ! -f "$inst_path/vmlinuz-$kver" ] && cp "$inst_path/vmlinuz" "$inst_path/vmlinuz-$kver"

	# mkosi 13 onwards uses 'kernel-install add <uname> to install the kernel,
	# and it expects a /lib/modules/$kver/vmlinuz
	cp "$inst_path/vmlinuz-$kver" "$inst_prefix/lib/modules/$kver/vmlinuz"

	dracut --force --verbose \
		--no-hostonly \
		--show-modules \
		--kver="$kver" \
		--kmoddir "$inst_prefix/lib/modules/$kver/" \
		--kernel-image "./vmlinux" \
		--add "bash systemd kernel-modules fs-lib" \
		--omit "iscsi fcoe fcoe-uefi" \
		--omit-drivers "nfit libnvdimm nd_pmem" \
		"$inst_path/initramfs-$kver.img"
}

__build_kernel()
{
	inst_prefix="$builddir/mkosi.extra"
	inst_path="$builddir/mkosi.extra/boot"
	mod_inst_param="INSTALL_MOD_PATH=$(readlink -f "$inst_prefix")"

	quiet=""
	if (( _arg_quiet >= 1 )); then
		quiet="--quiet"
	fi

	mkdir -p "$inst_path"
	# /lib -> /usr/lib
	mkdir -p "${inst_prefix}/usr/lib"
	ln -sf usr/lib "${inst_prefix}/lib"

	if [[ $_arg_defconfig == "on" ]]; then
		make $quiet olddefconfig
		make $quiet prepare
	fi
	kver=$(make -s kernelrelease)
	test -n "$kver"
	make $quiet -j"$num_build_cpus"

	# Install Modules Strip = ims
	local ims=""
	if [[ $_arg_strip_modules == "on" ]]; then
		ims="INSTALL_MOD_STRIP=1"
	fi
	make $quiet -j"$num_build_cpus" "$mod_inst_param" $ims modules_install
	if [[ $_arg_nfit_test == "on" ]]; then
		test_path="tools/testing/nvdimm"

		make $quiet -j"$num_build_cpus" M="$test_path"
		make $quiet "$mod_inst_param" M="$test_path" $ims modules_install
	fi
	if [[ $_arg_cxl_test == "on" ]]; then
		test_path="tools/testing/cxl"

		make $quiet -j"$num_build_cpus" M="$test_path"
		make $quiet "$mod_inst_param" M="$test_path" $ims modules_install
	fi

	if [[ $_arg_kern_selftests == "on" ]]; then
		selftests_dir=$(readlink -f "$inst_prefix")/$selftests_home
		make $quiet -j"$num_build_cpus" -C tools/testing/selftests install INSTALL_PATH="$selftests_dir"
	fi

	if [[ $_arg_gdb == "on" ]]; then
		make $quiet scripts_gdb
	fi

	if (( _arg_quiet >= 1 )); then
		install_build_initrd > /dev/null
	else
		install_build_initrd
	fi

	initrd="mkosi.extra/boot/initramfs-$kver.img"
}

build_kernel()
{
	if (( _arg_quiet >= 2 )); then
		__build_kernel > /dev/null
	else
		__build_kernel
	fi
}

setup_autorun()
{
	local prefix="$1"
	local bin_dir="/usr/local/bin"
	local systemd_dir="/etc/systemd/system/"
	local systemd_unit="$systemd_dir/rq_autorun.service"

	if [[ ! $_arg_autorun ]]; then
		autorun_file="$prefix/$systemd_unit"
		rm -f "${autorun_file:?}"
		return
	fi

	mkdir -p "$prefix/$bin_dir"
	mkdir -p "$prefix/$systemd_dir"

	cp -L "$_arg_autorun" "$prefix/$bin_dir"
	chmod +x "$prefix/$bin_dir/${_arg_autorun##*/}"

	# TODO: is a target really necessary?
	cat <<- EOF > "$prefix/$systemd_dir/rq-custom.target"
		[Unit]
		Description=run_qemu Custom Target
		After=multi-user.target

		[Install]
		WantedBy=default.target
	EOF

	cat <<- EOF > "$prefix/$systemd_unit"
		[Unit]
		Description=run_qemu autorun script
		After=multi-user.target

		[Service]
		Type=simple
		User=root
		Group=root
		PAMName=login
		KeyringMode=shared
		ExecStart=$bin_dir/${_arg_autorun##*/}

		[Install]
		RequiredBy=rq-custom.target
		WantedBy=default.target
	EOF

	# Only when building image, not when updating it.
	if [ "$(basename "$prefix")" != 'mnt' ]; then
		systemd_preset enable rq-custom.target
		systemd_preset enable rq_autorun.service
	fi
}

get_loopdev()
{
	local loopdev num_loopdev

	loopdev="$(sudo losetup --list | grep "$_arg_rootfs" | awk '{ print $1 }')"
	num_loopdev="$(wc -l <<< "$loopdev")"
	if (( num_loopdev != 1 )); then
		{ lsblk -f || true
		sudo losetup --list
		echo "Expected 1 loopdev for $_arg_rootfs, found $num_loopdev."
		echo "Try 'sudo losetup -D' to remove any stale loopdevs"
		} >&2
		exit 1
	fi
	test -b "$loopdev" || fail "%s is not a block device" "$loopdev"
	printf '%s' "$loopdev"
}

# mount_rootfs <partnum>
mount_rootfs()
{
	partnum="$1"
	mp="mnt"

	pushd "$builddir" > /dev/null || exit 1
	test -s "$_arg_rootfs"
	mkdir -p "$mp"

	sudo losetup -Pf "$_arg_rootfs"
	# The -P scan is performed in the background (this can be observed with a simple
	# 'ls -l /dev/disk/by-loop-ref/')
	sleep 2

	loopdev=$(get_loopdev)
	looppart="${loopdev}p${partnum}"

	sleep 1
	sudo mount "$looppart" "$mp"
	popd > /dev/null || exit 1 # back to kernel tree
}

# umount_rootfs <partnum>
umount_rootfs()
{
	partnum="$1"
	mp="mnt"

	loopdev=$(get_loopdev "$partnum")
	looppart="${loopdev}p${partnum}"

	sync
	sudo umount "$looppart"
	sudo rm -rf "$mp"
	sudo losetup -d "$loopdev"
}

declare -a kcmd
build_kernel_cmdline()
{
	root="$1"

	# standard options
	kcmd=( 
		"selinux=0"
		"audit=0"
		"console=tty0"
		"console=$console"
		"root=$root"
		"ignore_loglevel"
		"rw"
		"initcall_debug"
		"log_buf_len=20M"
		"memory_hotplug.memmap_on_memory=force"
	)
	if [[ $_arg_gdb == "on" ]]; then
		kcmd+=( 
			"nokaslr"
		)
	fi
	if [[ $_arg_cxl_debug == "on" ]]; then
		kcmd+=( 
			"cxl_acpi.dyndbg=+fplm"
			"cxl_pci.dyndbg=+fplm"
			"cxl_core.dyndbg=+fplm"
			"cxl_mem.dyndbg=+fplm"
			"cxl_pmem.dyndbg=+fplm"
			"cxl_port.dyndbg=+fplm"
			"cxl_region.dyndbg=+fplm"
			"cxl_test.dyndbg=+fplm"
			"cxl_mock.dyndbg=+fplm"
			"cxl_mock_mem.dyndbg=+fplm"
		)
	fi
	if [[ $_arg_dax_debug == "on" ]]; then
		kcmd+=(
			"dax.dyndbg=+fplm"
			"dax_cxl.dyndbg=+fplm"
			"device_dax.dyndbg=+fplm"
		)
	fi
	if [[ $_arg_nfit_debug == "on" ]]; then
		kcmd+=( 
			"libnvdimm.dyndbg=+fplm"
			"nfit.dyndbg=+fplm"
			"nfit_test.dyndbg=+fplm"
			"nd_pmem.dyndbg=+fplm"
			"nd_btt.dyndbg=+fplm"
			"dax.dyndbg=+fplm"
			"dax_hmem.dyndbg=+fplm"
			"nfit_test_iomap.dyndbg=+fplm"
		)
	fi
	if [[ $_arg_nfit_test == "on" ]]; then
		num_efi_mems=0
		num_legacy_pmems=0
		kcmd+=( 
			"memmap=3G!6G,1G!9G"
			"efi_fake_mem=2G@10G:0x40000"
		)
	fi

	tot_mem="$(((_arg_mem_size / 1024) * (num_mems + num_nodes)))"  # in GiB
	if (( num_legacy_pmems > 0 )); then
		reserve_efi="$((num_efi_mems * efi_mem_size))"  # in GiB
		reserve_pmem="$((num_legacy_pmems * legacy_pmem_size))"  # in GiB
		start="$((tot_mem - reserve_efi - reserve_pmem))"  #in GiB
		declare -a legacy_pmems
		cur="$start"
		for (( i = 0; i < num_legacy_pmems; i++ )); do
			cur=$((cur + (i * legacy_pmem_size)))
			legacy_pmems[$i]="${legacy_pmem_size}G!${cur}G"
		done
		pmems_str="$(printf "%s," "${legacy_pmems[@]}")"
		pmems_str="${pmems_str%,}"
		kcmd+=( "memmap=$pmems_str" )
	fi

	if (( num_efi_mems > 0 )); then
		reserve="$((num_efi_mems * efi_mem_size))"  # in GiB
		start="$((tot_mem - reserve))"  #in GiB
		declare -a efi_mems
		cur="$start"
		for (( i = 0; i < num_efi_mems; i++ )); do
			cur=$((cur + (i * efi_mem_size)))
			efi_mems[$i]="${efi_mem_size}G@${cur}G:0x40000"
		done
		efi_mems_str="$(printf "%s," "${efi_mems[@]}")"
		efi_mems_str="${efi_mems_str%,}"
		kcmd+=( "efi_fake_mem=$efi_mems_str" )
	fi

	# process kcmd replacement
	if [[ $_arg_kcmd_replace ]]; then
		mapfile -t kcmd < <(options_from_file "$_arg_kcmd_replace")
	fi

	# process kcmd appends
	if [[ $_arg_kcmd_append ]]; then
		mapfile -t kcmd_extra < <(options_from_file "$_arg_kcmd_append")
	fi

	# construct the final array
	kcmd+=( "${kcmd_extra[@]}" )
}

update_rootfs_boot_kernel()
{
	if [[ ! $kver ]]; then
		fail "Error: kver not set in update_rootfs_boot_kernel"
	fi

	mount_rootfs 1 # EFI system partition
	conffile="$builddir/mnt/loader/entries/run-qemu-kernel-$kver.conf"

	sudo sfdisk -l "${loopdev}" || sudo parted "${loopdev}" print || true

	root_partuuid="$(sudo blkid "${loopdev}p2" -o export | awk -F'=' '/^PARTUUID/{ print $2 }')"
	if [[ ! $root_partuuid ]]; then
		sudo losetup --list
		ls -l /dev/disk/by-loop-ref/ || true
		sudo blkid "${loopdev}p2" -o export || true
		fail "Unable to determine root partition UUID, is the mkosi image 'Bootable'?"
	fi

	# Note there is no initrd when booting this way, root filesystem must be built-in.
	build_kernel_cmdline "PARTUUID=$root_partuuid"
	sudo tee "$conffile" > /dev/null <<- EOF
		title run-qemu-$_distro ($kver)
		version $kver
		linux run-qemu-kernel/$kver/vmlinuz
		options ${kcmd[*]}
	EOF
	sudo mkdir -p "$builddir/mnt/run-qemu-kernel/$kver"
	sudo cp "$builddir/mkosi.extra/boot/vmlinuz-$kver" "$builddir/mnt/run-qemu-kernel/$kver/vmlinuz"

	defconf="$builddir/mnt/loader/loader.conf"
	if [ -f "$defconf" ]; then
		sudo sed -i -e 's/^#.*timeout.*/timeout 4/' "$defconf"
		sudo sed -i -e '/default.*/d' "$defconf"
	else
		echo "timeout 4" | sudo tee "$defconf"
	fi
	echo "default run-qemu-kernel-$kver.conf" | sudo tee -a "$defconf"

	# Fedora
	sudo cp "$ovmf_path"/Shell.efi "$builddir"/mnt/shellx64.efi ||
		# Arch Linux
		sudo cp /usr/share/edk2-shell/x64/Shell_Full.efi "$builddir"/mnt/shellx64.efi ||
		true

	umount_rootfs 1

	mount_rootfs 2 # Linux root partition
	sudo ln -sf "../efi/run-qemu-kernel" "$builddir/mnt/boot/run-qemu-kernel"
	umount_rootfs 2
}

setup_depmod()
{
	prefix="$1"
	depmod_dir="$prefix/etc/depmod.d"
	depmod_conf="$depmod_dir/nfit_test.conf"
	depmod_cxl_conf="$depmod_dir/cxl_test.conf"
	depmod_load_dir="$prefix/etc/modules-load.d"
	depmod_load_cxl_conf="$depmod_load_dir/cxl_test.conf"

	if [[ $_arg_nfit_test == "on" ]]; then
		mkdir -p "$depmod_dir"
		cat <<- EOF > "$depmod_conf"
			override nfit * extra
			override device_dax * extra
			override dax_pmem * extra
			override dax_pmem_core * extra
			override dax_pmem_compat * extra
			override libnvdimm * extra
			override nd_blk * extra
			override nd_btt * extra
			override nd_e820 * extra
			override nd_pmem * extra
		EOF
	else
		rm -f "$depmod_conf"
	fi

	if [[ $_arg_cxl_test == "on" ]]; then
		mkdir -p "$depmod_dir"
		cat <<- EOF > "$depmod_cxl_conf"
			override cxl_acpi * extra
			override cxl_core * extra
			override cxl_pmem * extra
			override cxl_mem * extra
			override cxl_port * extra
		EOF
		mkdir -p "$depmod_load_dir"
		cat <<- EOF > "$depmod_load_cxl_conf"
			cxl_test
		EOF
	else
		rm -f "$depmod_cxl_conf"
		rm -f "$depmod_load_cxl_conf"
	fi
	system_map="$prefix/boot/System.map"
	if [ ! -f "$system_map" ]; then
		system_map="$prefix/boot/System.map-$kver"
	fi
	if [ ! -f "$system_map" ]; then
		echo "not found: $system_map. Try rebuilding with '-r img'"
		return 1
	fi
	: Warning: symlinks created by this depmod do not survive the move
	: to the virtual machine
	sudo depmod -b "$prefix" -F "$system_map" -C "$depmod_dir" "$kver"
}

__update_existing_rootfs()
{
	inst_prefix="$builddir/mnt"
	inst_path="$inst_prefix/boot"
	mod_inst_param="INSTALL_MOD_PATH=$(readlink -f "$inst_prefix")"

	# Install Modules Strip = ims
	local ims=""
	if [[ $_arg_strip_modules == "on" ]]; then
		ims="INSTALL_MOD_STRIP=1"
	fi

	mount_rootfs 2 # Linux root partition
	if [[ $_arg_nfit_test == "on" ]]; then
		test_path="tools/testing/nvdimm"

		make -j"$num_build_cpus" M="$test_path"
		sudo make "$mod_inst_param" M="$test_path" $ims modules_install
	else
		sudo rm -rf "$test_path"/*.ko
	fi
	if [[ $_arg_cxl_test == "on" ]]; then
		test_path="tools/testing/cxl"

		make -j"$num_build_cpus" M="$test_path"
		sudo make "$mod_inst_param" M="$test_path" $ims modules_install
	else
		sudo rm -rf "$test_path"/*.ko
	fi
	sudo make "$mod_inst_param" $ims modules_install
	sudo make INSTALL_HDR_PATH="$inst_prefix/usr" headers_install

	if [[ $_arg_debug == 'on' ]]; then
	    local _trace_sh='-x'
	fi
	sudo -E bash $_trace_sh -e -c "$(declare -f make_install_kernel); kver=$kver make_install_kernel $inst_path"

	if [[ $_arg_cxl_test == "off" ]]; then
		sudo rm -f "$inst_prefix"/usr/lib/modules/"$kver"/extra/cxl_*.ko
	fi

	if [[ $_arg_ndctl_build == "on" ]]; then
		if [ -n "$ndctl" ] && [ -f "$ndctl/meson.build" ]; then
			>&2 printf '\n%s\n\n' \
'WARNING: --ndctl-build ignored when updating existing image! Outdated ndctl in the image. Try adding "-r img"'
		fi
	fi

	selftests_dir=$(readlink -f "$inst_prefix")/$selftests_home
	if [[ $_arg_kern_selftests == "on" ]]; then
		sudo make -j"$num_build_cpus" -C tools/testing/selftests install INSTALL_PATH="$selftests_dir"
	else
		sudo rm -rf "$selftests_dir"
	fi

	sudo -E bash $_trace_sh -c "$(declare -f setup_depmod); _arg_nfit_test=$_arg_nfit_test; _arg_cxl_test=$_arg_cxl_test; kver=$kver; setup_depmod $inst_prefix"
	sudo -E bash -e $_trace_sh -c "$(declare -f setup_autorun); _arg_autorun=$_arg_autorun; setup_autorun $inst_prefix"

	umount_rootfs 2
}

update_existing_rootfs()
{
	if (( _arg_quiet >= 2 )); then
		__update_existing_rootfs > /dev/null
	else
		__update_existing_rootfs
	fi
}

systemd_preset()
{
	state="$1"
	servicename="$2"

	if [ ! -d "mkosi.extra" ]; then
		fail "couldn't find mkosi.extra, are we in an unexpected CWD?"
	fi

	local preset_dir=mkosi.extra/etc/systemd/system-preset/
	mkdir -p "$preset_dir"

	{
		generatedfrom_header "preset_service $servicename"
		cat <<EOFPRESET

# Different distributions tend to have very different presets; override them all
# with a low enough number.
#
# Note changes in *.preset files are ignored until the next 'systemctl preset ...'
# or 'systemctl daemon-reload' command.

$state $servicename

EOFPRESET
	} > "$preset_dir/04-run_qemu-$servicename.preset"
}

setup_network()
{
	mkdir -p mkosi.extra/etc/systemd/network
	cat <<- EOF > mkosi.extra/etc/systemd/network/20-wired.network
		[Match]
		Name=en*

		[Network]
		DHCP=yes
	EOF
}

check_ndctl_dir()
{
	[ -f "$ndctl/meson.build" ] ||
		fail 'ndctl="%s" is not a valid source directory\n' "$ndctl"
}

prepare_ndctl_build()
{
	cp "${script_dir}"/mkosi/extra/root/ndctl/reinstall.sh \
		mkosi.extra/root/ndctl/
	cat <<- 'EOF' > mkosi.postinst
		#!/bin/sh
		# v14: 'systemd-nspawn"; v15: "mkosi"
		printf 'container=%s\n' "$container"
		# .postinst and others moved outside container in mkosi v15, see
		# https://github.com/systemd/mkosi/commit/9b626c647037bc8a
		if [ -n "$container" ]; then
			/root/ndctl/reinstall.sh
		else
			# The magic, short-lived $SCRIPT variable is already deprecated
			# and we don't need it.
			mkosi-chroot /root/ndctl/reinstall.sh
		fi
	EOF
	chmod +x mkosi.postinst
}

setup_gcp_tweaks()
{
	mkdir -p mkosi.extra/etc/ssh/sshd_config.d/
	cat <<- EOF >  mkosi.extra/etc/ssh/sshd_config
		Include /etc/ssh/sshd_config.d/*.conf
		AuthorizedKeysFile	.ssh/authorized_keys
		Subsystem	sftp	/usr/libexec/openssh/sftp-server
		UsePAM no
		PasswordAuthentication no
		PermitEmptyPasswords no
		PermitRootLogin prohibit-password
	EOF
	chmod go-rw mkosi.extra/etc/ssh/sshd_config
}

# "... generated by ... from $1 ..."
generatedfrom_header()
{
	printf '\n### Generated by %s,\n### from %s,\n### on %s\n### for mkosi version %s\n\n' \
	       "$0" "$1" "$(date)" "$( "$mkosi_bin" --version )"
}

# $1 -> stdout
process_mkosi_template()
{
	local src="$1"
	generatedfrom_header "$src"

	sed \
		-e "s:@OS_DISTRIBUTION_DEF@:${distribution_def}:" \
		-e "s:@OS_RELEASE_DEF@:${release_def}:" \
		-e "s:@ESP_SIZE@:${espsize}:" \
		-e "s:@ROOT_SIZE@:${rootfssize}:" \
		-e "s:@ROOT_PASS@:${rootpw}:" \
		-e "s:@ROOT_FS@:${_arg_rootfs}:" \
		"$src"
}

make_rootfs()
{
	pushd "$builddir" > /dev/null || exit 1

	# initialize mkosi configuration
	mkdir -p mkosi.cache
	mkdir -p mkosi.builddir

	# mkosi version 15 broke backwards-compatibility greatly.  Fortunately,
	# the location of configuration files was renamed around the same
	# time. Leverage this to generate different configurations in different
	# directories.
	#
	# Note we must NOT generate both directories at the same time because
	# mkosi v14 reads *BOTH* subdirectories! - while supporting only
	# old-style configuration data. Support for 'mkosi.conf.d/*.conf' was
	# added by mkosi v14 commit 7b9bd98d15c0 but this was not documented in
	# v14. Significantly later, support for 'mkosi.default.d/*' was silently
	# removed by giant mkosi v15 commit e1bbc39754ef "Rework configuration
	# parsing" and the documentation was switched to `mkosi.conf.d/*.conf` in
	# v15.
	local conf_d=mkosi.conf.d
	if test "$mkosi_ver" -lt 15; then
		conf_d=mkosi.default.d
	fi
	rm -rf mkosi.default.d/ mkosi.conf.d/
	mkdir "$conf_d"
	# Better safe than sorry
	rm -f mkosi.conf mkosi.default

	# Various mkosi versions have introduced various, advanced configuration
	# features like: - mkosi.profiles/; - [Match] filters; - [Include]
	# files; per-arch subdirectories;... Resist using them unless you want
	# to spend a lot of time validating a large range of mkosi versions one
	# by one.

	local mkosi_ver_d=mkosi_tmpl_from_v15
	if test "$mkosi_ver" -lt 15; then
		mkosi_ver_d=mkosi_tmpl_upto_v14
	fi

	local tmpl dst_base
	for tmpl in "${script_dir}/${mkosi_ver_d}"/*.tmpl \
		    "${script_dir}"/mkosi_tmpl_portable/*.tmpl \
		    "${script_dir}"/mkosi.${_distro}.default.tmpl; do
		dst_base=$(basename "${tmpl}")
		# Strip all suffixes
		dst_base=${dst_base%.tmpl}
		dst_base=${dst_base%.conf}
		dst_base=${dst_base%.default}
		# Unlike `mkosi.conf.d/*.conf`, `mkosi.default.d/*` files can
		# have any name. This was a classic design mistake (think
		# accidents with *~ and other backup files) but since we're
		# generating these the risk is very low for us.
		local dst="$conf_d/$dst_base".conf
		if test -e "$dst"; then
			fail 'Cannot process %s\n\tbecause %s already exists - name clash?\n' \
				"$tmpl" "$dst"
		fi
		process_mkosi_template "$tmpl" > "$dst"
	done

	# misc rootfs setup
	mkdir -p mkosi.extra/root/.ssh
	local pubk
	for pubk in ~/.ssh/*.pub; do
		if test -e "${pubk%.pub}"; then
			cat "${pubk}"
		fi
	done > mkosi.extra/root/.ssh/authorized_keys
	chmod -R go-rwx mkosi.extra/root

	rootfs_script="${script_dir}/${_distro}_rootfs.sh"
	# shellcheck source=fedora_rootfs.sh
	# shellcheck source=arch_rootfs.sh
	[ -f "$rootfs_script" ] && source "$rootfs_script" mkosi.extra/

	if [ -f ~/.bashrc ]; then
		rsync "${rsync_opts[@]}" ~/.bash* mkosi.extra/root/
	fi
	if [ -f ~/.vimrc ]; then
		rsync "${rsync_opts[@]}" ~/.vim* mkosi.extra/root/
	fi
	mkdir -p mkosi.extra/root/bin
	if [ -d ~/git/extra-scripts ]; then
		rsync "${rsync_opts[@]}" ~/git/extra-scripts/bin/* mkosi.extra/root/bin/
	fi
	if [[ $_arg_ndctl_build == "on" ]]; then
		if [ -n "$ndctl" ]; then
			rsync "${rsync_opts[@]}" "$ndctl/" mkosi.extra/root/ndctl
			prepare_ndctl_build # create mkosi.postinst which compiles
		fi
	fi

	# timedatectl defaults to UTC when /etc/localtime is missing
	local bld_tz; bld_tz=$( timedatectl | awk '/zone:/ { print $3 }' )
	# v15 commit f11325afa02c "Adopt systemd-firstboot"
	if [ "$mkosi_ver" -ge 15 ]; then
		mkosi_opts+=( --timezone "$bld_tz" )
	elif [ -f /etc/localtime ]; then
		mkdir -p mkosi.extra/etc/
		# Note this does not work across distros.
		# There are more alternatives at https://systemd.io/CREDENTIALS/
		cp -P /etc/localtime mkosi.extra/etc/
	else
		>&2 printf '\n \tWARNING: could not set timezone, --autorun will likely be stuck\n\n'
		sleep 3
	fi

	if [[ $_arg_gcp == "on" ]]; then
		setup_gcp_tweaks
	fi

	# enable ssh
	systemd_preset enable sshd.service

	# These are needed for Arch only, but didn't seem to have any adverse effect on Fedora
	systemd_preset enable systemd-networkd.service
	systemd_preset enable systemd-resolved.service
	setup_network

	# this is effectively 'daxctl migrate-device-model'
	mkdir -p mkosi.extra/etc/modprobe.d
	cat <<- EOF > mkosi.extra/etc/modprobe.d/daxctl.conf
		blacklist dax_pmem_compat
		alias nd:t7* dax_pmem
	EOF

	setup_depmod "mkosi.extra"
	setup_autorun "mkosi.extra"

	if [[ $_arg_gcp == "off" ]]; then
		mkosi_opts+=("--autologin")
	fi

	if [[ $_arg_debug == "on" ]]; then
	    # In case of yet another mkosi incompatibility or other issue,
	    # enable this line. WARNING: --debug options have "stability" issues
	    # too! Check the man page of your specific mkosi version
	    : # mkosi_opts+=('--debug-workspace' '--debug-shell' '--debug')
	fi

	mkosi_opts+=("build")
	if (( _arg_quiet < 3 )); then
		echo "in directory: $(pwd)"
		echo "running: sudo -E $mkosi_bin ${mkosi_opts[*]}"
	fi
	if (( _arg_quiet >= 1 )); then
		sudo -E "$mkosi_bin" "${mkosi_opts[@]}" > /dev/null
	else
		sudo -E "$mkosi_bin" "${mkosi_opts[@]}"
	fi
	sudo chmod go+rw "$_arg_rootfs"
	popd > /dev/null || exit 1
}

qemu_setup_hmat()
{
	hmat_lb_lat="hierarchy=memory,data-type=access-latency,latency"
	hmat_lb_bw="hierarchy=memory,data-type=access-bandwidth,bandwidth"

	# main loop for all the initiators.
	for (( i = 0; i < num_nodes; i++ )); do
		# cpu + mem nodes (--nodes)
		for (( j = 0; j < num_nodes; j++ )); do
			if [[ $i == "$j" ]]; then
				lat=$local_mem_lat
				bw=$local_mem_bw
			else
				lat=$cross_mem_lat
				bw=$cross_mem_bw
			fi
			qcmd+=("-numa" "hmat-lb,initiator=$i,target=$j,$hmat_lb_lat=${lat}")
			qcmd+=("-numa" "hmat-lb,initiator=$i,target=$j,$hmat_lb_bw=${bw}M")
		done

		# mem-only nodes (--mems)
		for (( j = 0; j < num_mems; j++ )); do
			mem_node="$((num_nodes + j))"
			this_initiator="$((j % num_nodes))"

			if [[ $this_initiator == "$i" ]]; then
				lat=$far_mem_lat
				bw=$far_mem_bw
			else
				lat=$cross_mem_lat
				bw=$cross_mem_bw
			fi
			qcmd+=("-numa" "hmat-lb,initiator=$i,target=$mem_node,$hmat_lb_lat=${lat}")
			qcmd+=("-numa" "hmat-lb,initiator=$i,target=$mem_node,$hmat_lb_bw=${bw}M")
		done

		# pmem nodes (--pmems)
		for (( j = 0; j < num_pmems; j++ )); do
			pmem_node="$((num_nodes + num_mems + j))"
			this_initiator="$((j % num_nodes))"

			if [[ $this_initiator == "$i" ]]; then
				lat=$far_pmem_lat
				bw=$far_pmem_bw
			else
				lat=$cross_pmem_lat
				bw=$cross_pmem_bw
			fi
			qcmd+=("-numa" "hmat-lb,initiator=$i,target=$pmem_node,$hmat_lb_lat=${lat}")
			qcmd+=("-numa" "hmat-lb,initiator=$i,target=$pmem_node,$hmat_lb_bw=${bw}M")
		done

		# some canned hmat cache info
		cache_vars="size=10K,level=1,associativity=direct,policy=write-back,line=64"
		qcmd+=("-numa" "hmat-cache,node-id=$i,$cache_vars")
	done

}

qemu_setup_node_distances()
{
	total_nodes=$((num_nodes + num_mems + num_pmems))

	# main loop for all the nodes (cpu, mem-only, and pmem).
	for (( i = 0; i < total_nodes; i++ )); do
		# cpu + mem nodes (--nodes)
		for (( j = 0; j < num_nodes; j++ )); do
			(( j < i )) && continue
			if [[ $i == "$j" ]]; then
				dist=$local_mem_dist
			else
				dist=$cross_mem_dist
			fi
			qcmd+=("-numa" "dist,src=$i,dst=$j,val=$dist")
		done

		# mem-only nodes (--mems)
		for (( j = 0; j < num_mems; j++ )); do
			mem_node="$((num_nodes + j))"
			this_initiator="$((j % num_nodes))"

			(( mem_node < i )) && continue
			if [[ $this_initiator == "$i" ]]; then
				dist=$far_mem_dist
			else
				dist=$cross_mem_dist
			fi
			if [[ $i == "$mem_node" ]]; then
				dist=$local_mem_dist
			fi
			qcmd+=("-numa" "dist,src=$i,dst=$mem_node,val=$dist")
		done

		# pmem nodes (--pmems)
		for (( j = 0; j < num_pmems; j++ )); do
			pmem_node="$((num_nodes + num_mems + j))"
			this_initiator="$((j % num_nodes))"

			(( pmem_node < i )) && continue
			if [[ $this_initiator == "$i" ]]; then
				dist=$far_pmem_dist
			else
				dist=$cross_pmem_dist
			fi
			if [[ $i == "$pmem_node" ]]; then
				dist=$local_mem_dist
			fi
			qcmd+=("-numa" "dist,src=$i,dst=$pmem_node,val=$dist")
		done
	done
}

options_from_file()
{
	local file="$1"

	test -f "$file" || return
	# unmatch lines starting with a '#' for comments
	# unmatch blank lines
	# lstrip and rstrip any whitespace
	awk '!/^#|^$/{ gsub(/^[ \t]+|[ \t]+$/, ""); print }' "$file"
}

get_ovmf_binaries()
{
	if [[ $_arg_legacy_bios == "on" ]]; then
		return 0
	fi

	if [[ $_arg_forget_disks == "on" ]]; then
		rm -f OVMF_*.fd
	fi
	if [[ ! $ovmf_path ]]; then
		echo "Unable to determine OVMF path for $_distro"
		exit 1
	fi
	if ! [ -e "OVMF_CODE.fd" ] && ! [ -e "OVMF_VARS.fd" ]; then
		if [ ! -f "$ovmf_path/OVMF_CODE.fd" ]; then
			echo "OVMF binaries not found, please install '[edk2-]ovmf' or similar, 'edk2-shell', ..."
			exit 1
		fi
		cp "$ovmf_path/OVMF_CODE.fd" .
		cp "$ovmf_path/OVMF_VARS.fd" .
	fi
}

setup_nvme()
{
	local num="$1"
	local extra_args
	[[ $# -gt 1 ]] && extra_args=",$2"

	for (( i = 0; i < num; i++ )); do
		nvme_img="nvme-$i"
		if [[ $_arg_forget_disks == "on" ]] || [[ ! -f $nvme_img ]]; then
			$qemu_img create -f raw "$nvme_img" "$nvme_size" > /dev/null
		fi
		qcmd+=("-device" "nvme,drive=nvme$i,serial=deadbeaf$i${extra_args}")
		qcmd+=("-drive" "file=$nvme_img,if=none,id=nvme$i")
	done
}

setup_cxl()
{
	# Create objects for devices.
	qcmd+=("-object" "memory-backend-file,id=cxl-mem0,share=on,mem-path=cxltest0.raw,size=$cxl_t3_size")
	qcmd+=("-object" "memory-backend-file,id=cxl-mem1,share=on,mem-path=cxltest1.raw,size=$cxl_t3_size")
	qcmd+=("-object" "memory-backend-file,id=cxl-mem2,share=on,mem-path=cxltest2.raw,size=$cxl_t3_size")
	qcmd+=("-object" "memory-backend-file,id=cxl-mem3,share=on,mem-path=cxltest3.raw,size=$cxl_t3_size")

	# Each device needs its own LSA
	qcmd+=("-object" "memory-backend-file,id=cxl-lsa0,share=on,mem-path=lsa0.raw,size=$cxl_label_size")
	qcmd+=("-object" "memory-backend-file,id=cxl-lsa1,share=on,mem-path=lsa1.raw,size=$cxl_label_size")
	qcmd+=("-object" "memory-backend-file,id=cxl-lsa2,share=on,mem-path=lsa2.raw,size=$cxl_label_size")
	qcmd+=("-object" "memory-backend-file,id=cxl-lsa3,share=on,mem-path=lsa3.raw,size=$cxl_label_size")

	# Create the "host bridges"
	qcmd+=("-device" "pxb-cxl,id=cxl.0,bus=pcie.0,bus_nr=53")
	qcmd+=("-device" "pxb-cxl,id=cxl.1,bus=pcie.0,bus_nr=191")

	# Create the root ports
	qcmd+=("-device" "cxl-rp,id=hb0rp0,bus=cxl.0,chassis=0,slot=0,port=0")
	qcmd+=("-device" "cxl-rp,id=hb0rp1,bus=cxl.0,chassis=0,slot=1,port=1")
	qcmd+=("-device" "cxl-rp,id=hb1rp0,bus=cxl.1,chassis=0,slot=2,port=0")
	qcmd+=("-device" "cxl-rp,id=hb1rp1,bus=cxl.1,chassis=0,slot=3,port=1")

	# switch under hb0rp0
	qcmd+=("-device" "cxl-upstream,port=4,bus=hb0rp0,id=cxl-up0,multifunction=on,addr=0.0,sn=12345678")
	qcmd+=("-device" "cxl-switch-mailbox-cci,bus=hb0rp0,addr=0.1,target=cxl-up0")

	# switch under hb1rp0
	qcmd+=("-device" "cxl-upstream,port=4,bus=hb1rp0,id=cxl-up1,multifunction=on,addr=0.0,sn=12341234")
	qcmd+=("-device" "cxl-switch-mailbox-cci,bus=hb1rp0,addr=0.1,target=cxl-up1")

	# 4 downstream ports under switch upstream port cxl-up0
	qcmd+=("-device" "cxl-downstream,port=0,bus=cxl-up0,id=swport0,chassis=0,slot=4")
	qcmd+=("-device" "cxl-downstream,port=1,bus=cxl-up0,id=swport1,chassis=0,slot=5")
	qcmd+=("-device" "cxl-downstream,port=2,bus=cxl-up0,id=swport2,chassis=0,slot=6")
	qcmd+=("-device" "cxl-downstream,port=3,bus=cxl-up0,id=swport3,chassis=0,slot=7")

	# 4 downstream ports under switch upstream port cxl-up1
	qcmd+=("-device" "cxl-downstream,port=0,bus=cxl-up1,id=swport4,chassis=0,slot=8")
	qcmd+=("-device" "cxl-downstream,port=1,bus=cxl-up1,id=swport5,chassis=0,slot=9")
	qcmd+=("-device" "cxl-downstream,port=2,bus=cxl-up1,id=swport6,chassis=0,slot=10")
	qcmd+=("-device" "cxl-downstream,port=3,bus=cxl-up1,id=swport7,chassis=0,slot=11")

	# Create pmem and volatile devices
	for (( i = 0; i < 4; i++ )); do
		bus_str="bus=swport$((i*2))"
		lsa_str="lsa=cxl-lsa$i"
		if (( i < num_cxl_pmems )); then
			mem_str="persistent-memdev=cxl-mem$i"
			id_str="id=cxl-pmem$i"
		else
			mem_str="volatile-memdev=cxl-mem$i"
			id_str="id=cxl-vmem$i"
		fi
		qcmd+=("-device" "cxl-type3,$bus_str,$mem_str,$id_str,$lsa_str")
	done

	# Finally, the CFMWS entries
	declare -a cfmws_params
	while read -r param; do cfmws_params+=("$param"); done <<- EOF
		cxl-fmw.0.targets.0=cxl.0,
		cxl-fmw.0.size=4G,
		cxl-fmw.0.interleave-granularity=8k,

		cxl-fmw.1.targets.0=cxl.0,
		cxl-fmw.1.targets.1=cxl.1,
		cxl-fmw.1.size=4G,
		cxl-fmw.1.interleave-granularity=8k
	EOF
	qcmd+=("-M" "$(printf %s "${cfmws_params[@]}")")
}

prepare_qcmd()
{
	# this step may expect files to be present at the toplevel, so run
	# it before dropping into the builddir
	build_kernel_cmdline "/dev/sda2"

	pushd "$builddir" > /dev/null || exit 1

	if [[ ! $kver ]] && [[ $_arg_kver ]]; then
		kver="$_arg_kver"
	fi

	if [ -n "$kver" ] && [ -e "mkosi.extra/boot/vmlinuz-$kver" ]; then
		vmlinuz="mkosi.extra/boot/vmlinuz-$kver"
	else
		vmlinuz="$(find . -name "vmlinuz*" | grep -vE ".*\.old$" | tail -1)"
	fi

	# if a kver was specified, try to use the same initrd
	if [ -n "$kver" ] && [ -e "mkosi.extra/boot/initramfs-$kver.img" ]; then
		initrd="mkosi.extra/boot/initramfs-$kver.img"
	fi

	# if initrd still hasn't been determined, attempt to use a previous one
	if [ -z "$initrd" -a -d mkosi.extra/boot ]; then
		initrd=$(find "mkosi.extra/boot" -name "initramfs*" -print | head -1)
	fi

	# a 'node' implies a 'mem' attached to it
	qemu_mem="$((_arg_mem_size * (num_mems + num_nodes)))"

	if [ "$num_pmems" -gt 0 ]; then
		pmem_append="maxmem=$((qemu_mem + pmem_final_size * num_pmems))M"
	else
		# qemu doesn't like maxmem = initial mem, so arbitrarily add 4GiB for now
		pmem_append="maxmem=$((qemu_mem + 4096))M"
	fi

	# cpu topology: num_nodes sockets, 2 cores per socket, 2 threads per core
	# so smp = num_nodes (sockets) * cores * threads
	cores=2
	threads=2
	sockets=$num_nodes
	smp=$((sockets * cores * threads))

	if [[ $_arg_gdb_qemu == "on" ]]; then
		qcmd=("$gdb" "${gdb_extra[@]}" "--args")
	fi
	qcmd+=("$qemu")

	# setup machine_args
	machine_args=("q35" "accel=$accel")
	if [[ "$num_pmems" -gt 0 ]]; then
		machine_args+=("nvdimm=on")
	fi
	if [[ $_arg_hmat == "on" ]]; then
		machine_args+=("hmat=on")
	fi
	if [[ $_arg_cxl == "on" ]]; then
		machine_args+=("cxl=on")
	fi
	qcmd+=("-machine" "$(IFS=,; echo "${machine_args[*]}")")
	qcmd+=("-m" "${qemu_mem}M,slots=$((num_pmems + num_mems)),$pmem_append")
	qcmd+=("-smp" "${smp},sockets=${num_nodes},cores=${cores},threads=${threads}")
	qcmd+=("-display" "none" "$dispmode")
	if [[ $_arg_log ]]; then
		qcmd+=("-serial" "file:$_arg_log")
	fi
	if [[ $_arg_legacy_bios == "off" ]] ; then
		get_ovmf_binaries
		qcmd+=("-drive" "if=pflash,format=raw,unit=0,file=OVMF_CODE.fd,readonly=on")
		qcmd+=("-drive" "if=pflash,format=raw,unit=1,file=OVMF_VARS.fd")
		qcmd+=("-debugcon" "file:uefi_debug.log" "-global" "isa-debugcon.iobase=0x402")
	fi
	qcmd+=("-drive" "file=$_arg_rootfs,format=raw,media=disk")
	if [ $_arg_direct_kernel = "on" -a -n "$vmlinuz" -a -n "$initrd" ]; then
		qcmd+=("-kernel" "$vmlinuz" "-initrd" "$initrd")
		qcmd+=("-append" "${kcmd[*]}")
	fi

	hostport="$((10022 + _arg_instance))"
	if [ "$hostport" -gt 65535 ]; then
		fail "run_qemu: instance ID too high, port overflows 65535"
	fi
	mac_lower=$(printf "%06x" "$((_arg_instance + 0x123456))")
	guestmac=("52" "54" "00")
	[[ $mac_lower =~ (..)(..)(..) ]] && guestmac+=("${BASH_REMATCH[@]:1}")
	mac_addr=$(IFS=:; echo "${guestmac[*]}")

	qcmd+=("-device" "e1000,netdev=net0,mac=$mac_addr")
	qcmd+=("-netdev" "user,id=net0,hostfwd=tcp::$hostport-:22")
	# Use host CPU capability
	qcmd+=("-cpu" "host")

	if [[ $_arg_cxl == "on" ]]; then
		setup_cxl
	fi

	if [[ $_arg_qmp == "on" ]]; then
		qcmd+=("-qmp" "unix:$qmp_sock,server,nowait")
	fi

	if [ "$num_nvmes" -gt 0 ]; then
		setup_nvme "$num_nvmes"
	fi

	if [[ $_arg_rw == "off" ]]; then
		qcmd+=("-snapshot")
	fi

	if [ "$_arg_gdb" == "on" ]; then
		qcmd+=("-gdb" "tcp::10000" "-S")
	fi

	# cpu + mem nodes (i.e. the --nodes option)
	for (( i = 0; i < num_nodes; i++ )); do
		[[ $_arg_hmat == "on" ]] && hmat_append="initiator=$i"
		qcmd+=("-object" "memory-backend-ram,id=mem${i},size=${_arg_mem_size}M")
		qcmd+=("-numa" "node,nodeid=${i},memdev=mem${i},$hmat_append")
		qcmd+=("-numa" "cpu,node-id=${i},socket-id=${i}")
	done

	# memory only nodes (i.e. the --mems option)
	for (( i = 0; i < num_mems; i++ )); do
		mem_node="$((num_nodes + i))"

		[[ $_arg_hmat == "on" ]] && hmat_append="initiator=$((i % num_nodes))"
		qcmd+=("-object" "memory-backend-ram,id=mem${mem_node},size=${_arg_mem_size}M")
		qcmd+=("-numa" "node,nodeid=$mem_node,memdev=mem${mem_node},$hmat_append")
	done

	# pmem nodes (i.e. the --pmems option)
	for (( i = 0; i < num_pmems; i++ )); do
		pmem_node="$((num_nodes + num_mems + i))"
		pmem_obj="memory-backend-file,id=nvmem${i},share=on,mem-path=nvdimm-${i}"
		pmem_dev="nvdimm,memdev=nvmem${i},id=nv${i},label-size=${pmem_label_size}M"

		pmem_img="nvdimm-$i"
		if [[ $_arg_forget_disks == "on" ]] || [[ ! -f $pmem_img ]]; then
			$qemu_img create -f raw "$pmem_img" "${pmem_final_size}M" > /dev/null
		fi
		[[ $_arg_hmat == "on" ]] && hmat_append="initiator=$((i % num_nodes))"
		qcmd+=("-numa" "node,nodeid=$pmem_node,$hmat_append")
		qcmd+=("-object" "$pmem_obj,size=${pmem_size}M,align=1G")
		qcmd+=("-device" "$pmem_dev,node=$pmem_node")
	done

	qemu_setup_node_distances
	if [[ $_arg_hmat == "on" ]]; then
		qemu_setup_hmat
	fi

	if [[ $_arg_cmdline == "on" ]]; then
		set +x
		for elem in "${qcmd[@]}"; do
			if [[ $elem == -* ]]; then
				echo "\\"
			fi
			printf "%s " "$elem"
		done
		echo
		exit 0
	fi
	popd > /dev/null || exit 1
}

start_qemu()
{
	pushd "$builddir" > /dev/null || exit 1

	if [[ $_arg_log ]]; then
		if (( _arg_quiet < 3 )); then
			printf "starting qemu. console output is logged to %s\n" "$_arg_log"
		fi
	fi
	if [[ $_arg_timeout == "0" ]]; then
		"${qcmd[@]}"
	else
		printf "guest will be terminated after %d minute(s)\n" "$_arg_timeout"
		"${qcmd[@]}" & sleep 5
		timeout_sec="$(((_arg_timeout * 60) - 5))"
		while ((timeout_sec > 0)); do
			if ! guest_alive; then
				break
			fi
			sleep 5
			timeout_sec="$((timeout_sec - 5))"
		done
		kill_guest
	fi
	popd > /dev/null || exit 1
}

post_script()
{
	post_cmd=("$_arg_post_script")
	if [[ $_arg_log ]]; then
		post_cmd+=("$_arg_log")
	fi
	"${post_cmd[@]}"
}

main()
{
	mkdir -p "$builddir"
	process_options_logic

	case "$_arg_rebuild" in
		kmod)
			build_kernel
			if [ -s "$builddir/$_arg_rootfs" ]; then
				update_existing_rootfs
			else
				make_rootfs
			fi
			update_rootfs_boot_kernel
			;;
		wipe|clean)
			test -d "$builddir" && sudo rm -rf "${builddir:?}"/*
			;&  # fall through
		imgcache)
			rm -f "${builddir}/${_arg_rootfs}"*
			;&  # fall through
		img)
			build_kernel
			make_rootfs
			update_rootfs_boot_kernel
			;;
		kern*)
			echo "--rebuild=kernel has been deprecated, please use --rebuild=kmod (default)"
			exit 1
			;;
		no*)
			;;
		*)
			printf "Invalid option for --rebuild\n"
			exit 1
			;;
	esac

	if [[ $_arg_run == "on" ]]; then
		prepare_qcmd
		start_qemu
	fi
	if [[ $_arg_post_script ]]; then
		# This is the last thing that runs so that the script's exit
		# status comes from this function. If something needs to be
		# added after this in the future, make sure to save the return
		# value from this.
		post_script
	fi
}

main
