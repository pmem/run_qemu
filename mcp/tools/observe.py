"""VM observation tools: vm_status, vm_log, vm_build_log."""

import re
from pathlib import Path
from typing import Optional

from server import mcp
from instance import get_instance_info, log_file, build_log_file, VMState


@mcp.tool()
async def vm_status(instance: int = 0) -> str:
    """Check the current state of a VM instance.

    Returns one of:
      - starting: kernel build, rootfs creation, or QEMU boot in progress
      - ready: VM is up and SSH-accessible
      - exited: VM has terminated (includes exit code)
      - unknown: no instance found

    Args:
        instance: VM instance number (default: 0).
    """
    info = await get_instance_info(instance)

    lines = [f"Instance {instance}: {info.state.value}"]
    lines.append(f"  SSH port: {info.ssh_port}")

    if info.pid:
        lines.append(f"  PID: {info.pid}")
    if info.state == VMState.EXITED and info.exit_code is not None:
        lines.append(f"  Exit code: {info.exit_code}")
    if info.state == VMState.READY:
        lines.append(f"  SSH: ssh -p {info.ssh_port} root@localhost")

    lines.append(f"  Log: {info.log_file}")

    return "\n".join(lines)


@mcp.tool()
async def vm_log(
    instance: int = 0,
    tail_lines: int = 50,
    grep_pattern: Optional[str] = None,
) -> str:
    """Read the VM's console log file.

    Args:
        instance: VM instance number (default: 0).
        tail_lines: Number of lines from the end to return (default: 50).
        grep_pattern: If set, filter lines matching this pattern (case-insensitive).
    """
    lf = log_file(instance)
    if not lf.exists():
        return f"No log file found for instance {instance} (expected: {lf})"

    try:
        content = lf.read_text(errors="replace")
    except OSError as e:
        return f"Error reading log: {e}"

    lines = content.splitlines()

    if grep_pattern:
        try:
            pattern = re.compile(grep_pattern, re.IGNORECASE)
            lines = [line for line in lines if pattern.search(line)]
        except re.error as e:
            return f"Invalid grep pattern: {e}"

    if tail_lines and tail_lines < len(lines):
        lines = lines[-tail_lines:]

    if not lines:
        if grep_pattern:
            return f"No lines matching '{grep_pattern}' in log for instance {instance}"
        return f"Log file is empty for instance {instance}"

    return "\n".join(lines)


@mcp.tool()
async def vm_build_log(
    instance: int = 0,
    tail_lines: int = 80,
    grep_pattern: Optional[str] = None,
) -> str:
    """Read the build/startup log (kernel compile, mkosi, run_qemu.sh output).

    This is separate from the console log (vm_log). The build log captures
    everything run_qemu.sh prints to stdout/stderr: kernel build progress,
    mkosi rootfs creation, and any errors before QEMU starts.

    Args:
        instance: VM instance number (default: 0).
        tail_lines: Number of lines from the end to return (default: 80).
        grep_pattern: If set, filter lines matching this pattern (case-insensitive).
    """
    bf = build_log_file(instance)
    if not bf.exists():
        return f"No build log found for instance {instance} (expected: {bf})"

    try:
        content = bf.read_text(errors="replace")
    except OSError as e:
        return f"Error reading build log: {e}"

    lines = content.splitlines()

    if grep_pattern:
        try:
            pattern = re.compile(grep_pattern, re.IGNORECASE)
            lines = [line for line in lines if pattern.search(line)]
        except re.error as e:
            return f"Invalid grep pattern: {e}"

    if tail_lines and tail_lines < len(lines):
        lines = lines[-tail_lines:]

    if not lines:
        if grep_pattern:
            return f"No lines matching '{grep_pattern}' in build log for instance {instance}"
        return f"Build log is empty for instance {instance}"

    return "\n".join(lines)
