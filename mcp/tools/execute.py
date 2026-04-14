"""VM command execution tools: vm_run, vm_dmesg."""

import asyncio
from typing import Optional

from server import mcp
from instance import get_instance_info, ssh_port, VMState


async def _ssh_command(
    instance: int, command: str, timeout: int = 120
) -> tuple[int, str, str]:
    """Run a command on the VM via SSH. Returns (returncode, stdout, stderr)."""
    port = ssh_port(instance)
    proc = await asyncio.create_subprocess_exec(
        "ssh",
        "-o", "ConnectTimeout=5",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", "LogLevel=ERROR",
        "-p", str(port),
        "root@localhost",
        command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return proc.returncode, stdout.decode(errors="replace"), stderr.decode(errors="replace")
    except asyncio.TimeoutError:
        proc.kill()
        return -1, "", f"Command timed out after {timeout}s"


@mcp.tool()
async def vm_run(
    command: str,
    instance: int = 0,
    timeout: int = 120,
) -> str:
    """Run a shell command inside the VM via SSH.

    The VM must be in 'ready' state (SSH accessible). Returns the
    command's stdout, stderr, and exit code.

    Args:
        command: Shell command to execute on the VM.
        instance: VM instance number (default: 0).
        timeout: Command timeout in seconds (default: 120).
    """
    info = await get_instance_info(instance)
    if info.state != VMState.READY:
        return (
            f"Error: Instance {instance} is not ready (state: {info.state.value}). "
            f"Use vm_status to check when the VM is ready."
        )

    rc, stdout, stderr = await _ssh_command(instance, command, timeout)

    parts = []
    if stdout.strip():
        parts.append(stdout.rstrip())
    if stderr.strip():
        parts.append(f"[stderr]\n{stderr.rstrip()}")
    parts.append(f"[exit code: {rc}]")

    return "\n".join(parts)


@mcp.tool()
async def vm_dmesg(
    instance: int = 0,
    level: Optional[str] = None,
    grep: Optional[str] = None,
    tail_lines: Optional[int] = None,
) -> str:
    """Read kernel log (dmesg) from the VM.

    Args:
        instance: VM instance number (default: 0).
        level: Filter by log level (e.g., "err", "warn", "err,warn").
        grep: Filter output with grep pattern (e.g., "cxl", "error").
        tail_lines: Return only the last N lines.
    """
    info = await get_instance_info(instance)
    if info.state != VMState.READY:
        return (
            f"Error: Instance {instance} is not ready (state: {info.state.value}). "
            f"Use vm_status to check when the VM is ready."
        )

    cmd = "dmesg --color=never"
    if level:
        cmd += f" --level={level}"
    if grep:
        cmd += f" | grep -i -- {_shell_quote(grep)}"
    if tail_lines:
        cmd += f" | tail -n {tail_lines}"

    rc, stdout, stderr = await _ssh_command(instance, cmd)

    if rc != 0 and not stdout.strip():
        return f"dmesg failed (exit {rc}): {stderr.strip()}"

    return stdout.rstrip() if stdout.strip() else "(no matching dmesg output)"


def _shell_quote(s: str) -> str:
    """Quote a string for use in a shell command."""
    import shlex
    return shlex.quote(s)
