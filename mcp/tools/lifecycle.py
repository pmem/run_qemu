"""VM lifecycle tools: vm_start, vm_stop, vm_list."""

import asyncio
import os
import shlex
from pathlib import Path

from server import mcp
from instance import (
    build_log_file,
    cleanup_instance_files,
    get_instance_info,
    kill_vm,
    list_instances,
    log_file,
    pid_file,
    qmp_sock,
    ssh_port,
)


def _find_run_qemu() -> str:
    """Locate run_qemu.sh relative to the MCP server."""
    # MCP lives in run_qemu/mcp/tools/, so run_qemu.sh is two levels up
    mcp_dir = Path(__file__).resolve().parent.parent.parent
    script = mcp_dir / "run_qemu.sh"
    if script.exists():
        return str(script)
    # Fallback: check PATH
    import shutil
    found = shutil.which("run_qemu.sh")
    if found:
        return found
    raise FileNotFoundError(
        f"run_qemu.sh not found. Expected at {script} or in PATH."
    )


@mcp.tool()
async def vm_start(
    linux_dir: str = ".",
    rebuild: str = "kmod",
    preset: str = "small",
    cxl: bool = False,
    cxl_test: bool = False,
    nfit_test: bool = False,
    defconfig: bool = True,
    instance: int = 0,
    timeout_minutes: int = 0,
    extra_args: str = "",
) -> str:
    """Build a kernel and launch a QEMU VM in the background.

    Returns immediately with instance info. Use vm_status to poll for
    readiness (starting → ready).

    Args:
        linux_dir: Path to the Linux kernel tree. Default: current directory.
        rebuild: Rebuild mode — kmod (default, rebuild kernel + modules),
            img (full rootfs rebuild), wipe (clean everything), none (just boot).
        preset: NUMA topology preset — tiny/small/med/large/huge.
        cxl: Enable CXL topology.
        cxl_test: Set up CXL unit test environment (includes cxl_test kernel module).
        nfit_test: Set up NFIT unit test environment (includes libnvdimm test modules).
        defconfig: Run 'make olddefconfig' before building (default: true).
        instance: Instance number (0-based). Determines SSH port (10022+N)
            and allows running multiple VMs simultaneously.
        timeout_minutes: Auto-kill timeout in minutes. 0 = no timeout.
        extra_args: Additional run_qemu.sh arguments passed verbatim
            (e.g., "--cxl-debug --hmat --kcmd-append myfile.txt").
    """
    run_qemu = _find_run_qemu()
    linux_dir = os.path.expanduser(linux_dir)
    linux_dir = os.path.abspath(linux_dir)

    if not os.path.isdir(linux_dir):
        return f"Error: {linux_dir} is not a directory"

    valid_rebuilds = ("kmod", "img", "wipe", "none")
    if rebuild not in valid_rebuilds:
        return f"Error: rebuild must be one of {valid_rebuilds}"

    # Build the command
    lf = str(log_file(instance))
    cmd_parts = [
        run_qemu,
        f"--rebuild={rebuild}",
        f"--preset={preset}",
        f"--instance={instance}",
        f"--log={lf}",
        "--qmp",
    ]

    if cxl:
        cmd_parts.append("--cxl")

    if cxl_test:
        cmd_parts.append("--cxl-test")

    if nfit_test:
        cmd_parts.append("--nfit-test")

    if defconfig:
        cmd_parts.append("--defconfig")

    if timeout_minutes > 0:
        cmd_parts.append(f"--timeout={timeout_minutes}")

    if extra_args.strip():
        cmd_parts.extend(shlex.split(extra_args))

    cmd_parts.append(linux_dir)

    # Launch as async subprocess in its own process group so we can
    # kill the entire tree (wrapper + QEMU) via killpg.
    bf = str(build_log_file(instance))
    proc = await asyncio.create_subprocess_exec(
        *cmd_parts,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=linux_dir,
        start_new_session=True,
    )

    # Write PID file so vm_status/vm_stop can find it
    pid_file(instance).write_text(str(proc.pid))

    # Background task: stream stdout to build log, record exit code
    asyncio.create_task(_monitor_exit(proc, instance, bf))

    port = ssh_port(instance)
    return (
        f"VM instance {instance} started (PID {proc.pid})\n"
        f"  SSH port: {port}\n"
        f"  Console log: {lf}\n"
        f"  Build log: {bf}\n"
        f"  QMP: {qmp_sock(instance)}\n"
        f"  Rebuild: {rebuild}, Preset: {preset}, CXL: {cxl}\n"
        f"\nPoll vm_status(instance={instance}) to check progress."
    )


async def _monitor_exit(
    proc: asyncio.subprocess.Process, instance: int, build_log: str
) -> None:
    """Background task: stream stdout to build log, record exit code."""
    try:
        with open(build_log, "w", buffering=1) as f:  # line-buffered text mode
            assert proc.stdout is not None
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                f.write(line.decode(errors="replace"))
    except OSError:
        pass

    await proc.wait()
    exit_file = pid_file(instance).with_suffix(".exit")
    try:
        exit_file.write_text(str(proc.returncode))
    except OSError:
        pass


@mcp.tool()
async def vm_stop(instance: int = 0) -> str:
    """Gracefully stop a running VM instance.

    Tries QMP quit (graceful) → SSH poweroff → SIGTERM → SIGKILL.
    Cleans up PID files.

    Args:
        instance: Instance number to stop (default: 0).
    """
    info = await get_instance_info(instance)
    if info.state in ("unknown", "exited"):
        cleanup_instance_files(instance)
        return f"Instance {instance} is not running (state: {info.state.value})"

    result = await kill_vm(instance)
    return f"Instance {instance}: {result}"


@mcp.tool()
async def vm_list() -> str:
    """List all known run_qemu VM instances with their state and SSH ports."""
    instances = await list_instances()

    if not instances:
        return "No VM instances found."

    lines = ["Instance  State     SSH Port  PID"]
    lines.append("-" * 42)
    for info in instances:
        pid_str = str(info.pid) if info.pid else "-"
        lines.append(
            f"  {info.instance:<8} {info.state.value:<9} {info.ssh_port:<9} {pid_str}"
        )

    return "\n".join(lines)
