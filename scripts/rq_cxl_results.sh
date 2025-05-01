#!/bin/bash
# SPDX-License-Identifier: CC0-1.0
# Copyright (C) 2021 Intel Corporation. All rights reserved.

# TODO: convert this to a proper Expect script.

logfile="$1"

# lines we expect to find in the serial log
# if any of these are not found, this is an error
find_lines_re=( 
	"auto-running .*rq_cxl_tests.sh"
	"[0-9]+/[0-9]+ ndctl:.*OK.*"
	"Ok:[ \t]+[0-9]+"
	"Fail:[ \t]+0"
	"Skipped:[ \t]+0"
	"Timeout:[ \t]+0"
	"Done .*rq_cxl_tests.sh"
)

# lines that we should know about, but are not necessarily an error
# so long as all the other error/no-error conditions are met
# e.g 'Call trace' or so
warn_lines_re=( 
	".*-+\[ cut here \]-+"
	".*-+\[ end trace [0-9a-f]+ \]-+"
	"Call Trace:"
	"WARNING:"
	"kernel BUG"
)

raw_command_re=(
	".*raw command path used"
)

# lines that indicate a fatal error if present
error_lines_re=( 
	"make:.*[Makefile:.*check] Error"
	"ninja: build stopped: subcommand failed"
	"[0-9]+/[0-9]+ ndctl:.*FAIL.*"
	'Fail:[[:blank:]]+[^0[:blank:]]'
	'Unexpected Pass:[[:blank:]]+[^0[:blank:]]'
	'Skipped:[[:blank:]]+[^0[:blank:]]'
	'Timeout:[[:blank:]]+[^0[:blank:]]'
)

warn_count=0

# Try to find and show the most useful lines.
# Max 200 lines in case something goes horribly wrong.
grep_summary()
{
	local re e_regs=()
	for re in "${find_lines_re[@]}" "${error_lines_re[@]}" "${warn_lines_re[@]}"; do
		e_regs+=('-e' "$re")
	done
	grep -n -E "${e_regs[@]}" "$logfile" | head -n 200
}

exit_success()
{
	# bold green
	tput bold; tput setaf 2
	cat <<- EOF
		+-----------------------+
		|  CXL Tests - Success  |
		+-----------------------+
	EOF
	tput sgr0
	exit 0
}

exit_fail()
{

	reason="$1"
	# bold red
	tput bold; tput setaf 1
	cat <<- EOF
		+--------------------+
		|  CXL Tests - FAIL  |
		+--------------------+
		$reason
	EOF
	tput sgr0
	exit 1
}

exit_warn()
{
	# bold yellow
	tput bold; tput setaf 3
	cat <<- EOF
		+-------------------------------+
		|      CXL Tests - Success      |
		|  **with warnings - see log**  |
		+-------------------------------+
		warn_count: $warn_count
	EOF
	tput sgr0
	exit 125
}


# main

# if any of the expected find_lines is not found, it is an automatic failure
for re in "${find_lines_re[@]}"; do
	if grep -qE "$re" "$logfile"; then
		continue
	fi

	grep_summary
	exit_fail "failed to find line: $re"
done

# if any of the error_lines is found, it is an automatic failure
for re in "${error_lines_re[@]}"; do
	if grep -qE "$re" "$logfile"; then
		grep_summary
		exit_fail "found error line: $re"
	fi
done

# if any warn_lines are found, keep a count
for re in "${warn_lines_re[@]}"; do
	if grep -qE "$re" "$logfile"; then
		warn_count=$((warn_count + 1))
	fi
done

# using raw commands produces a taint warning, which adds 4 warn count
# if this was found, adjust the warn count so this isn't flagged
for re in "${raw_command_re[@]}"; do
	if grep -qE "$re" "$logfile"; then
		warn_count=$((warn_count - 4))
	fi
done

if (( warn_count > 0 )); then
	grep_summary
	exit_warn
fi

exit_success
