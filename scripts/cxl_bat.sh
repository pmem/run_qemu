#!/bin/bash -e

fail()
{
	printf "[FAIL] %s\n" "$*" | tee /dev/kmsg
	exit 1
}

pass()
{
	printf "[PASS] %s\n" "$*" | tee /dev/kmsg
}

attempt()
{
	printf "[ATTEMPT] %s\n" "$*" | tee /dev/kmsg
}

bug()
{
	printf "[BUG] %s\n" "$*" | tee /dev/kmsg
	exit 2
}

tests_start()
{
	printf "[START] Starting CXL BAT tests\n" | tee /dev/kmsg
}

tests_end()
{
	printf "[END] All CXL BAT tests completed successfully\n" | tee /dev/kmsg
	exit 0
}

get_rand_range()
{
	start=$1
	end=$2
	size="$((end - start + 1))"

	echo "$((($RANDOM % (size + 1)) + start))"
}

initial_setup()
{
	# cxl_test produces memdevs we're not interested in BAT'ing
	modprobe -r cxl_test
}

verify_device_presence()
{
	attempt "device presence"

	devname="$(cxl list | jq -r '.[0].memdev')" 
	if [[ $devname ]]; then
		pass "cxl $devname found"
	else
		fail "no cxl memdev found"
	fi
}

do_cmd_silent()
{
	cmd=( "$@" )
	if [ "${#cmd[@]}" -lt 1 ]; then
		bug "$0: no cmd passed"
	fi

	cxl "${cmd[@]}"
}

try_cmd()
{
	cmd=( "$@" )

	cmd_name="${cmd[0]}"
	attempt "${cmd[*]}"

	if ! do_cmd_silent "${cmd[@]}"; then
		fail "cxl-$cmd_name"
	else
		pass "cxl-$cmd_name"
	fi
}

test_write_labels()
{
	label_in="label_in"
	label_out="label_out"

	while read -r memdev; do
		payload_size="$(cat "/sys/bus/cxl/devices/$memdev/payload_max")"
		label_size="$(cat "/sys/bus/cxl/devices/$memdev/label_storage_size")"
		max_size="$((payload_size < label_size ? payload_size : label_size))"
		for (( i = 0; i < 10; i++ )); do
			randsize="$(get_rand_range 1 $max_size)"
			attempt "label size: $randsize"
			rm "$label_in" "$label_out"
			dd if=/dev/urandom of="$label_in" bs=1 count="$randsize" > /dev/null 2>&1
			do_cmd_silent "write-labels" "-i" "$label_in" "-s" "$randsize" "$memdev"
			do_cmd_silent "read-labels" -o "$label_out" "-s" "$randsize" "$memdev"
			if ! diff "$label_in" "$label_out"; then
				fail "cxl write/read labels size: $randsize"
			else
				pass "cxl write/read labels size: $randsize"
			fi
		done
	done < <(cxl list | jq -r '.[].memdev')
	pass "cxl write/read labels test"
}

test_acpidev_presence()
{
	dev=$1
	count=0
	attempt "Check presence of ACPI $1 device"

	for dev in /sys/bus/cxl/devices/$1*; do
		if [ ! -e "$dev" ]; then
			continue
		fi
		echo "found ${dev##*/}"
		count="$((count + 1))"
	done
	if ((count == 0)); then
		fail "ACPI $1 device not found"
	else
		pass "ACPI $1 device(s) found"
		echo "found $count $1"
	fi
}

test_hb_chbs_warning()
{
	attempt "Check that each Host Bridge has a CHBS"
	if [[ $(dmesg | grep -c "No CHBS found for Host Bridge") -gt 0 ]]; then
		fail "One or more Host Bridges is missing a CHBS"
	else
		pass "Each Host Bridge has a CHBS"
	fi
}

tests_start
initial_setup
test_acpidev_presence "root"
test_acpidev_presence "decoder"
test_acpidev_presence "port"
try_cmd "list"
verify_device_presence
try_cmd "read-labels" "mem0" "-o" "/dev/null"
test_write_labels
test_hb_chbs_warning
tests_end
