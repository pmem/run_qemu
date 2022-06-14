#!/bin/bash -Ee
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

# default config
: "${builddir:=./qbuild}"
rootpw="root"
rootfssize="10G"
nvme_size="1G"
pmem_size="16384"  #in MiB
pmem_label_size=2  #in MiB
pmem_final_size="$((pmem_size + pmem_label_size))"
: "${qemu:=qemu-system-x86_64}"
: "${gdb:=gdb}"
: "${distro:=fedora}"
: "${rev:=35}"
: "${ndctl:=$(readlink -f ~/git/ndctl)}"
mkosi_bin="mkosi"
mkosi_opts=("-i" "-f")

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
cxl_label_size="1K"

num_build_cpus="$(($(getconf _NPROCESSORS_ONLN) + 1))"
rsync_opts=("--delete" "--exclude=.git/" "-L" "-r")

qemu_dir=$(dirname "$(dirname "$qemu")")
if [[ $qemu_dir != . ]]; then
	qemu_img="$qemu_dir/qemu-img"
	if [ ! -f "$qemu_img" ]; then
		qemu_img="$qemu_dir/build/qemu-img"
	fi
	qmp="$qemu_dir/scripts/qmp/qmp-shell"
else
	qemu_img="qemu-img"
	qmp="qmp"
fi

fail()
{
	printf "%s\n" "$*"
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

cxl_test_script="$script_dir/scripts/rq_cxl_tests.sh"
cxl_results_script="$script_dir/scripts/rq_cxl_results.sh"
nfit_test_script="$script_dir/scripts/rq_nfit_tests.sh"
nfit_results_script="$script_dir/scripts/rq_nfit_results.sh"

pushd "$_arg_working_dir" > /dev/null || fail "couldn't cd to $_arg_working_dir"

kill_guest()
{
	# sometimes this can be inadvertently re-entrant
	sleep 1

	if [ -x "$qmp" ] && [ -e "$qmp_sock" ]; then
		"$qmp" "$qmp_sock" <<< "quit" > /dev/null
		if (( _arg_quiet < 3 )); then
			echo "run_qemu: Killed guest via QMP"
		fi
	fi
}

guest_alive()
{
	if [ -e "$qmp_sock" ]; then
		return 0
	fi
	return 1
}

loop_teardown()
{
	loopdev="$(losetup --list | grep "$_arg_rootfs" | awk '{ print $1 }')"
	if [ -b "$loopdev" ]; then
		sudo umount "${loopdev}p1" || true
		sudo umount "${loopdev}p2" || true
		sudo losetup -d "$loopdev"
	fi
}

cleanup()
{
	kill_guest
	loop_teardown
	set +x
}

trap cleanup EXIT

set_topo_presets()
{
	case "$1" in
	1S|tiny)
		num_nodes=1
		num_mems=0
		num_pmems=1
		;;
	2S0|small0)
		num_nodes=2
		num_mems=0
		num_pmems=2
		;;
	2S|small)
		num_nodes=2
		num_mems=2
		num_pmems=2
		;;
	2S4|med*)
		num_nodes=2
		num_mems=4
		num_pmems=4
		;;
	4S|large)
		num_nodes=4
		num_mems=4
		num_pmems=4
		;;
	8S|huge)
		num_nodes=8
		num_mems=8
		num_pmems=8
		;;
	16S|insane)
		num_nodes=16
		num_mems=0
		num_pmems=16
		;;
	16Sb|broken)
		num_nodes=16
		num_mems=0
		num_pmems=32
		;;
	*)
		printf "error: invalid preset: %s\n" "$1"
		exit 1
		;;
	esac
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
	if [[ $_arg_nfit_test_run == "on" ]]; then
		_arg_nfit_test="on"
		set_topo_presets "med"
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
	if [[ $_arg_cxl_test == "on" ]]; then
		_arg_cxl="on"
		_arg_cxl_debug="on"
	fi
	if [[ $_arg_cxl_debug == "on" ]]; then
		_arg_cxl="on"
	fi
	if [[ $_arg_cxl_legacy == "on" ]] || [[ $_arg_cxl == "on" ]]; then
		_arg_git_qemu="on"
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

	num_nvmes="$_arg_nvmes"
	num_nodes="$_arg_nodes"
	num_mems="$_arg_mems"
	num_pmems="$_arg_pmems"
	set_topo_presets "$_arg_preset"

	if [[ $_arg_nfit_test == "on" ]]; then
		if (( _arg_quiet < 3 )); then
			printf "setting preset to 'med' for nfit_test\n"
		fi
		set_topo_presets "med"
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
			fail "--timeout requires 'qmp'. $qmp not found"
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
}

install_build_initrd()
{
	inst_prefix="$builddir/mkosi.extra"
	inst_path="$builddir/mkosi.extra/boot"

	make INSTALL_MOD_PATH="$inst_prefix" modules_install
	make INSTALL_HDR_PATH="$inst_prefix/usr" headers_install
	make INSTALL_PATH="$inst_path" INSTALL_MOD_PATH="$inst_prefix" INSTALL_HDR_PATH="$inst_prefix/usr" install

	# Much of the script relies on a kernel named vmlinuz-$kver. This is
	# distro specific as the default from Linux is simply "vmlinuz". Adjust
	# that here.
	[ ! -f "$inst_path/vmlinuz-$kver" ] && cp "$inst_path/vmlinuz" "$inst_path/vmlinuz-$kver"

	dracut --force --verbose \
		--no-hostonly \
		--show-modules \
		--kver="$kver" \
		--filesystems="xfs ext4" \
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

	mkdir -p "$inst_path"

	if [[ $_arg_defconfig == "on" ]]; then
		make olddefconfig
		make prepare
	fi
	kver=$(make kernelrelease)
	test -n "$kver"
	make -j"$num_build_cpus"
	if [[ $_arg_nfit_test == "on" ]]; then
		test_path="tools/testing/nvdimm"

		make -j"$num_build_cpus" M="$test_path"
		make INSTALL_MOD_PATH="$inst_prefix" M="$test_path" modules_install
	fi
	if [[ $_arg_cxl_test == "on" ]]; then
		test_path="tools/testing/cxl"

		make -j"$num_build_cpus" M="$test_path"
		make INSTALL_MOD_PATH="$inst_prefix" M="$test_path" modules_install
	fi
	if (( _arg_quiet >= 1 )); then
		install_build_initrd > /dev/null 2>&1
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
	local systemd_linkdir="$systemd_dir/rq-custom.target.wants"

	if [[ ! $_arg_autorun ]]; then
		autorun_file="$prefix/$systemd_unit"
		rm -f "${autorun_file:?}"
		return
	fi

	mkdir -p "$prefix/$bin_dir"
	mkdir -p "$prefix/$systemd_dir"
	mkdir -p "$prefix/$systemd_linkdir"
	cp -L "$_arg_autorun" "$prefix/$bin_dir"
	chmod +x "$prefix/$bin_dir/${_arg_autorun##*/}"
	cat <<- EOF > "$prefix/$systemd_dir/rq-custom.target"
		[Unit]
		Description=run_qemu Custom Target
		Requires=multi-user.target
		After=multi-user.target
		AllowIsolate=yes
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
		WantedBy=rq-custom.target
	EOF
	ln -sfr "$prefix/$systemd_unit" "$prefix/$systemd_linkdir/${systemd_unit##*/}"
	ln -sfr "$prefix/$systemd_dir/rq-custom.target" "$prefix/$systemd_dir/default.target"
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
	loopdev="$(losetup --list | grep "$_arg_rootfs" | awk '{ print $1 }')"
	looppart="${loopdev}p${partnum}"
	test -b "$loopdev"
	sleep 1
	sudo mount "$looppart" "$mp"
	popd > /dev/null || exit 1 # back to kernel tree
}

# umount_rootfs <partnum>
umount_rootfs()
{
	partnum="$1"
	mp="mnt"

	loopdev="$(losetup --list | grep "$_arg_rootfs" | awk '{ print $1 }')"
	looppart="${loopdev}p${partnum}"
	test -b "$loopdev"
	sync
	sleep 5
	sudo umount "$looppart"
	sudo rm -rf "$mp"
	sudo losetup -d "$loopdev"
}

update_rootfs_boot_kernel()
{
	if [[ ! $kver ]]; then
		fail "Error: kver not set in update_rootfs_boot_kernel"
	fi

	mount_rootfs 1 # EFI system partition
	conffile="$builddir/mnt/loader/entries/run-qemu-kernel-$kver.conf"
	root_partuuid="$(sudo blkid "${loopdev}p2" -o export | awk -F'=' '/^PARTUUID/{ print $2 }')"
	if [[ ! $root_partuuid ]]; then
		fail "Unable to determine root partition UUID"
	fi

	# TODO: consolidate this with build_kernel_cmdline()
	kopts=( 
		"root=PARTUUID=$root_partuuid"
		"selinux=0"
		"audit=0"
		"rw"
		"console=ttyS0"
		"ignore_loglevel"
		"cxl_acpi.dyndbg=+fplm"
		"cxl_pci.dyndbg=+fplm"
		"cxl_core.dyndbg=+fplm"
		"cxl_mem.dyndbg=+fplm"
		"cxl_port.dyndbg=+fplm"
		"cxl_region.dyndbg=+fplm"
	)
	sudo tee "$conffile" > /dev/null <<- EOF
		title run-qemu-$distro ($kver)
		version $kver
		source /efi/EFI/Linux/linux-$kver.efi
		linux EFI/Linux/linux-$kver.efi
		options ${kopts[*]}
	EOF
	sudo mkdir -p "$builddir/mnt/run-qemu-kernel/$kver"
	sudo cp "$builddir/mkosi.extra/boot/vmlinuz-$kver" "$builddir/mnt/EFI/Linux/linux-$kver.efi"

	defconf="$builddir/mnt/loader/loader.conf"
	sudo sed -i -e 's/default.*/default run-qemu-kernel-*/' "$defconf"
	sudo sed -i -e 's/^#.*timeout.*/timeout 4/' "$defconf"
	umount_rootfs 1

	mount_rootfs 2 # Linux root partition
	sudo ln -sf "$builddir/mnt/efi/run-qemu-kernel" "$builddir/mnt/boot/run-qemu-kernel"
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
	depmod -b "$prefix" -F "$system_map" -C "$depmod_dir" "$kver"
}

__update_existing_rootfs()
{
	inst_prefix="$builddir/mnt"

	mount_rootfs 2 # Linux root partition
	if [[ $_arg_nfit_test == "on" ]]; then
		test_path="tools/testing/nvdimm"

		make -j"$num_build_cpus" M="$test_path"
		sudo make INSTALL_MOD_PATH="$inst_prefix" M="$test_path" modules_install
	fi
	if [[ $_arg_cxl_test == "on" ]]; then
		test_path="tools/testing/cxl"

		make -j"$num_build_cpus" M="$test_path"
		sudo make INSTALL_MOD_PATH="$inst_prefix" M="$test_path" modules_install
	fi
	sudo make INSTALL_MOD_PATH="$inst_prefix" modules_install
	sudo make INSTALL_HDR_PATH="$inst_prefix/usr" headers_install
	sudo make INSTALL_PATH="$inst_prefix" INSTALL_MOD_PATH="$inst_prefix" INSTALL_HDR_PATH="$inst_prefix/usr" install

	ndctl_dst="$inst_prefix/root/ndctl"
	if [ -d "$ndctl" ] && [ -d "$ndctl_dst" ]; then
		rsync "${rsync_opts[@]}" "$ndctl/" "$ndctl_dst"
	fi

	sudo -E bash -c "$(declare -f setup_depmod); _arg_nfit_test=$_arg_nfit_test; _arg_cxl_test=$_arg_cxl_test; kver=$kver; setup_depmod $inst_prefix"
	sudo -E bash -c "$(declare -f setup_autorun); _arg_autorun=$_arg_autorun; setup_autorun $inst_prefix"
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

enable_systemd_service()
{
	servicename="$1"

	if [ ! -d "mkosi.extra" ]; then
		fail "couldn't find mkosi.extra, are we in an unexpected CWD?"
	fi

	mkdir -p mkosi.extra/etc/systemd/system/multi-user.target.wants

	ln -sf "/usr/lib/systemd/system/${servicename}.service" \
		"mkosi.extra/etc/systemd/system/multi-user.target.wants/${servicename}.service"
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

prepare_ndctl_build()
{
	cat <<- EOF > mkosi.postinst
		#!/bin/bash -ex

		if [[ ! -d /root/ndctl ]]; then
			exit 0
		fi
		pushd /root/ndctl
		rm -rf build
		meson setup build
		meson configure -Dtest=enabled -Ddestructive=enabled build
		meson compile -C build
		meson install -C build
	EOF
	chmod +x mkosi.postinst
}

make_rootfs()
{
	pushd "$builddir" > /dev/null || exit 1

	# initialize mkosi configuration
	mkdir -p mkosi.cache
	mkdir -p mkosi.builddir
	sed -e "s:@OS_DISTRO@:${distro}:" \
		-e "s:@OS_RELEASE@:${rev}:" \
		-e "s:@ROOT_SIZE@:${rootfssize}:" \
		-e "s:@ROOT_FS@:${_arg_rootfs}:" \
		-e "s:@ROOT_PASS@:${rootpw}:" \
		"${script_dir}"/mkosi.${distro}.default.tmpl > mkosi.default

	# misc rootfs setup
	mkdir -p mkosi.extra/root/.ssh
	cp -L ~/.ssh/id_rsa.pub mkosi.extra/root/.ssh/authorized_keys
	chmod -R go-rwx mkosi.extra/root

	rootfs_script="${script_dir}/${distro}_rootfs.sh"
	# shellcheck source=fedora_rootfs.sh
	# shellcheck source=arch_rootfs.sh
	[ -f "$rootfs_script" ] && source "$rootfs_script" mkosi.extra/

	cp -Lr ~/.bash* mkosi.extra/root/
	if [ -f ~/.vimrc ]; then
		rsync "${rsync_opts[@]}" ~/.vimrc mkosi.extra/root/
	fi
	mkdir -p mkosi.extra/root/bin
	if [ -d ~/git/extra-scripts ]; then
		rsync "${rsync_opts[@]}" ~/git/extra-scripts/bin/* mkosi.extra/root/bin/
	fi
	if [ -d "$ndctl" ]; then
		rsync "${rsync_opts[@]}" "$ndctl/" mkosi.extra/root/ndctl
	fi
	if [ -f /etc/localtime ]; then
		mkdir -p mkosi.extra/etc/
		cp -P /etc/localtime mkosi.extra/etc/
	fi

	# enable ssh
	enable_systemd_service sshd

	# These are needed for Arch only, but didn't seem to have any adverse effect on Fedora
	enable_systemd_service systemd-networkd
	enable_systemd_service systemd-resolved
	setup_network

	# this is effectively 'daxctl migrate-device-model'
	mkdir -p mkosi.extra/etc/modprobe.d
	cat <<- EOF > mkosi.extra/etc/modprobe.d/daxctl.conf
		blacklist dax_pmem_compat
		alias nd:t7* dax_pmem
	EOF

	setup_depmod "mkosi.extra"
	setup_autorun "mkosi.extra"

	prepare_ndctl_build
	mkosi_ver="$("$mkosi_bin" --version | awk '/mkosi/{ print $2 }')"
	if (( mkosi_ver >= 9 )); then
		mkosi_opts+=("--autologin")
	fi
	mkosi_opts+=("build")
	if (( _arg_quiet < 3 )); then
		echo "running: $mkosi_bin ${mkosi_opts[*]}"
	fi
	if (( _arg_quiet >= 1 )); then
		sudo -E "$mkosi_bin" "${mkosi_opts[@]}" > /dev/null 2>&1
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

build_kernel_cmdline()
{
	# standard options
	kcmd=( 
		"selinux=0"
		"audit=0"
		"console=tty0"
		"console=ttyS0"
		"root=/dev/sda2"
		"ignore_loglevel"
		"rw"
	)
	if [[ $_arg_cxl_debug == "on" ]]; then
		kcmd+=( 
			"cxl_acpi.dyndbg=+fplm"
			"cxl_pci.dyndbg=+fplm"
			"cxl_core.dyndbg=+fplm"
			"cxl_mem.dyndbg=+fplm"
			"cxl_port.dyndbg=+fplm"
			"cxl_region.dyndbg=+fplm"
			"cxl_test.dyndbg=+fplm"
			"cxl_mock.dyndbg=+fplm"
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
			"nfit_test_iomap.dyndbg=+fplm"
		)
	fi
	if [[ $_arg_nfit_test == "on" ]]; then
		kcmd+=( 
			"memmap=3G!6G,1G!9G"
			"efi_fake_mem=2G@10G:0x40000"
		)
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

get_ovmf_binaries()
{
	if [[ $_arg_legacy_bios == "on" ]]; then
		return 0
	fi

	if [[ $_arg_forget_disks == "on" ]]; then
		rm -f OVMF_*.fd
	fi
	if ! [ -e "OVMF_CODE.fd" ] && ! [ -e "OVMF_VARS.fd" ]; then
		wget -O edk2-ovmf.tar.zst https://www.archlinux.org/packages/extra/any/edk2-ovmf/download/
	else
		# Binaries are already there.
		return 0
	fi

	tar -I zstd --strip-components=4 -xf edk2-ovmf.tar.zst usr/share/edk2-ovmf/x64/OVMF_CODE.fd usr/share/edk2-ovmf/x64/OVMF_VARS.fd
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

prepare_qcmd()
{
	# this step may expect files to be present at the toplevel, so run
	# it before dropping into the builddir
	build_kernel_cmdline

	pushd "$builddir" > /dev/null || exit 1

	get_ovmf_binaries

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
	if [ -z "$initrd" ]; then
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
	machine_args=("q35" "accel=kvm")
	if [[ "$num_pmems" -gt 0 ]]; then
		machine_args+=("nvdimm=on")
	fi
	if [[ $_arg_hmat == "on" ]]; then
		machine_args+=("hmat=on")
	fi
	if [[ $_arg_cxl == "on" ]]; then
		# New QEMU always wants the CXL machine
		machine_args+=("cxl=on")
	fi
	qcmd+=("-machine" "$(IFS=,; echo "${machine_args[*]}")")
	qcmd+=("-m" "${qemu_mem}M,slots=$((num_pmems + num_mems)),$pmem_append")
	qcmd+=("-smp" "${smp},sockets=${num_nodes},cores=${cores},threads=${threads}")
	qcmd+=("-enable-kvm" "-display" "none" "$dispmode")
	if [[ $_arg_log ]]; then
		qcmd+=("-serial" "file:$_arg_log")
	fi
	if [[ $_arg_legacy_bios == "off" ]] ; then
		qcmd+=("-drive" "if=pflash,format=raw,unit=0,file=OVMF_CODE.fd,readonly=on")
		qcmd+=("-drive" "if=pflash,format=raw,unit=1,file=OVMF_VARS.fd")
		qcmd+=("-debugcon" "file:uefi_debug.log" "-global" "isa-debugcon.iobase=0x402")
	fi
	qcmd+=("-drive" "file=$_arg_rootfs,format=raw,media=disk")
	if [[ $_arg_direct_kernel == "on" ]]; then
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

	if [[ $_arg_cxl_legacy == "on" ]]; then
		# Create a single host bridge with a single root port, and a
		# Type3 device (of 256M PMEM). The host bridge will be 52:0.0
		# for no particular reason.
		#
		# The memory window is declared first and used throughout CXL
		# component creation. The PA of the window is 0x4c0000000, for
		# no particular reason.
		qcmd+=("-object" "memory-backend-file,id=cxl-mem1,share=on,mem-path=cxl-window1,size=$cxl_backend_size")
		qcmd+=("-object" "memory-backend-file,id=cxl-label1,share=on,mem-path=cxl-label1,size=$cxl_label_size")
		qcmd+=("-object" "memory-backend-file,id=cxl-label2,share=on,mem-path=cxl-label2,size=$cxl_label_size")

		pxb_cxl_subcmd="pxb-cxl"
		pxb_cxl_subcmd+=",id=cxl.0,bus=pcie.0,bus_nr=52,uid=0"
		pxb_cxl_subcmd+=",len-window-base=1,window-base[0]=$cxl_addr"
		pxb_cxl_subcmd+=",memdev[0]=cxl-mem1"
		qcmd+=("-device" "$pxb_cxl_subcmd")

		qcmd+=("-device" "cxl-rp,id=rp0,bus=cxl.0,addr=0.0,chassis=0,slot=0,port=0")
		qcmd+=("-device" "cxl-rp,id=rp1,bus=cxl.0,addr=1.0,chassis=0,slot=1,port=1")
		qcmd+=("-device" "cxl-type3,bus=rp0,memdev=cxl-mem1,id=cxl-pmem0,size=$cxl_t3_size,lsa=cxl-label1")
		qcmd+=("-device" "cxl-type3,bus=rp1,memdev=cxl-mem1,id=cxl-pmem1,size=$cxl_t3_size,lsa=cxl-label2")
	elif [[ $_arg_cxl == "on" ]]; then
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

		# Create the devices
		qcmd+=("-device" "cxl-type3,bus=hb0rp0,memdev=cxl-mem0,id=cxl-dev0,lsa=cxl-lsa0")
		qcmd+=("-device" "cxl-type3,bus=hb0rp1,memdev=cxl-mem1,id=cxl-dev1,lsa=cxl-lsa1")
		qcmd+=("-device" "cxl-type3,bus=hb1rp0,memdev=cxl-mem2,id=cxl-dev2,lsa=cxl-lsa2")
		qcmd+=("-device" "cxl-type3,bus=hb1rp1,memdev=cxl-mem3,id=cxl-dev3,lsa=cxl-lsa3")

		# Finally, the CFMWS entries
		qcmd+=("-cxl-fixed-memory-window" "targets.0=cxl.0,size=4G,interleave-granularity=8k")
		qcmd+=("-cxl-fixed-memory-window" "targets.0=cxl.0,targets.1=cxl.1,size=4G,interleave-granularity=8k")
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
				echo
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
			test -d "$builddir" && sudo rm -rf $builddir/*
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

	prepare_qcmd
	if [[ $_arg_run == "on" ]]; then
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
