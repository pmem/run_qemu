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

try_cmd()
{
	cmd=( "$@" )
	if [ "${#cmd[@]}" -lt 1 ]; then
		bug "no cmd passed to try_cmd"
	fi

	cmd_name="${cmd[0]}"
	attempt "${cmd[*]}"

	if ! cxl "${cmd[@]}"; then
		fail "cxl-$cmd_name"
	else
		pass "cxl-$cmd_name"
	fi
}

test_write_labels()
{
	label_in="label_in"
	label_out="label_out"
	label_size="4088"

	dd if=/dev/urandom of="$label_in" bs=1 count="$label_size"
	try_cmd "write-labels" "-i" "$label_in" "mem0"
	try_cmd "read-labels" -o "$label_out" "mem0"
	if ! diff "$label_in" "$label_out"; then
		fail "cxl write/read labels test"
	else
		pass "cxl write/read labels test"
	fi
}

tests_start
try_cmd "list"
verify_device_presence
try_cmd "read-labels" "mem0"
test_write_labels
tests_end
