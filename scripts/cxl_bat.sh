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

	for (( i = 0; i < 50; i++ )); do
		randsize="$(get_rand_range 1 4088)"
		#randsize="$(get_rand_range 1 1024)"
		attempt "label size: $randsize"
		dd if=/dev/urandom of="$label_in" bs=1 count="$randsize" > /dev/null 2>&1
		do_cmd_silent "write-labels" "-i" "$label_in" "-s" "$randsize" "mem0"
		do_cmd_silent "read-labels" -o "$label_out" "-s" "$randsize" "mem0"
		if ! diff "$label_in" "$label_out"; then
			fail "cxl write/read labels size: $randsize"
		else
			pass "cxl write/read labels size: $randsize"
		fi
		rm "$label_in" "$label_out"
	done
	pass "cxl write/read labels test"
}

tests_start
try_cmd "list"
verify_device_presence
try_cmd "read-labels" "mem0" "-o" "/dev/null"
test_write_labels
tests_end
