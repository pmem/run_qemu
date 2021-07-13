#!/bin/bash -e

fail()
{
	printf "[FAIL] %s failed\n" "$*" > /dev/kmsg
	exit 1
}

pass()
{
	printf "[PASS] %s passed\n" "$*" > /dev/kmsg
}

attempt()
{
	printf "[ATTEMPT] %s\n" "$*" > /dev/kmsg
}

bug()
{
	printf "[BUG] %s\n" "$*" > /dev/kmsg
	exit 2
}

tests_start()
{
	printf "[START] Starting CXL BAT tests\n" > /dev/kmsg
}

tests_end()
{
	printf "[END] All CXL BAT tests completed successfully\n" > /dev/kmsg
	exit 0
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

tests_start
try_cmd "list"
try_cmd "read-labels" "mem0"
tests_end
