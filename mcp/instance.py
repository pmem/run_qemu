"""Instance state management for run_qemu VMs.

Tracks VM instances via files in /tmp:
  /tmp/rq_<instance>.pid      — run_qemu.sh process PID
  /tmp/rq_<instance>.log      — console log (via --log)
  /tmp/run_qemu_qmp_<instance> — QMP socket (via --qmp)

SSH port = 10022 + instance number.

State detection:
  - PID alive + SSH unreachable = starting (building or booting)
  - PID alive + SSH reachable = ready
  - PID dead = exited
  No --status-file needed — the MCP infers state from PID + SSH probe.
"""

import asyncio
import json
import os
import signal
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional


class VMState(str, Enum):
    STARTING = "starting"  # build or boot in progress
    READY = "ready"        # SSH reachable
    EXITED = "exited"      # process terminated
    UNKNOWN = "unknown"    # no instance found


@dataclass
class InstanceInfo:
    instance: int
    ssh_port: int
    pid: Optional[int]
    state: VMState
    log_file: str
    qmp_sock: str
    exit_code: Optional[int] = None

    def to_dict(self) -> dict:
        return {
            "instance": self.instance,
            "ssh_port": self.ssh_port,
            "pid": self.pid,
            "state": self.state.value,
            "log_file": self.log_file,
            "qmp_sock": self.qmp_sock,
            "exit_code": self.exit_code,
        }


def ssh_port(instance: int) -> int:
    return 10022 + instance


def pid_file(instance: int) -> Path:
    return Path(f"/tmp/rq_{instance}.pid")


def log_file(instance: int) -> Path:
    return Path(f"/tmp/rq_{instance}.log")


def build_log_file(instance: int) -> Path:
    return Path(f"/tmp/rq_{instance}.build.log")


def qmp_sock(instance: int) -> str:
    return f"/tmp/run_qemu_qmp_{instance}"


def _read_pid(instance: int) -> Optional[int]:
    pf = pid_file(instance)
    if not pf.exists():
        return None
    try:
        return int(pf.read_text().strip())
    except (ValueError, OSError):
        return None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


async def probe_ssh(instance: int, timeout: int = 3) -> bool:
    """Check if the VM is reachable via SSH."""
    port = ssh_port(instance)
    try:
        proc = await asyncio.create_subprocess_exec(
            "ssh",
            "-o", "ConnectTimeout=2",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR",
            "-p", str(port),
            "root@localhost",
            "true",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=timeout)
        return proc.returncode == 0
    except (asyncio.TimeoutError, OSError):
        return False


async def get_instance_info(instance: int) -> InstanceInfo:
    """Get comprehensive state for a VM instance."""
    pid = _read_pid(instance)
    exit_code = None

    if pid and _pid_alive(pid):
        if await probe_ssh(instance):
            state = VMState.READY
        else:
            state = VMState.STARTING
    elif pid and not _pid_alive(pid):
        state = VMState.EXITED
        # Try to read exit code from the state file we maintain
        sf = pid_file(instance).with_suffix(".exit")
        if sf.exists():
            try:
                exit_code = int(sf.read_text().strip())
            except (ValueError, OSError):
                pass
    else:
        state = VMState.UNKNOWN

    return InstanceInfo(
        instance=instance,
        ssh_port=ssh_port(instance),
        pid=pid,
        state=state,
        log_file=str(log_file(instance)),
        qmp_sock=qmp_sock(instance),
        exit_code=exit_code,
    )


async def list_instances() -> list[InstanceInfo]:
    """Find all instances that have PID files."""
    instances = []
    for path in Path("/tmp").glob("rq_*.pid"):
        try:
            inst_num = int(path.stem.split("_")[1])
            info = await get_instance_info(inst_num)
            instances.append(info)
        except (ValueError, IndexError):
            continue

    return sorted(instances, key=lambda i: i.instance)


def cleanup_instance_files(instance: int) -> None:
    """Remove state files for an instance."""
    for path in [pid_file(instance), pid_file(instance).with_suffix(".exit")]:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


async def kill_vm(instance: int) -> str:
    """Kill a VM instance. Tries QMP quit → SSH poweroff → SIGTERM → SIGKILL."""
    pid = _read_pid(instance)
    if not pid:
        return "No PID found for instance"

    if not _pid_alive(pid):
        cleanup_instance_files(instance)
        return "VM already exited"

    # Try QMP quit first (graceful)
    sock = qmp_sock(instance)
    if os.path.exists(sock):
        try:
            proc = await asyncio.create_subprocess_exec(
                "bash", "-c",
                f'echo \'{{"execute": "quit"}}\' | socat - UNIX-CONNECT:{sock}',
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=5)
            await asyncio.sleep(2)
            if not _pid_alive(pid):
                cleanup_instance_files(instance)
                return "VM stopped via QMP"
        except (asyncio.TimeoutError, OSError):
            pass

    # Try SSH poweroff
    port = ssh_port(instance)
    try:
        proc = await asyncio.create_subprocess_exec(
            "ssh",
            "-o", "ConnectTimeout=2",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-p", str(port),
            "root@localhost",
            "poweroff",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=5)
        await asyncio.sleep(3)
        if not _pid_alive(pid):
            cleanup_instance_files(instance)
            return "VM stopped via SSH poweroff"
    except (asyncio.TimeoutError, OSError):
        pass

    # SIGTERM the process group (kills wrapper + QEMU child)
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        await asyncio.sleep(2)
        if not _pid_alive(pid):
            cleanup_instance_files(instance)
            return "VM stopped via SIGTERM (process group)"
    except (OSError, ProcessLookupError):
        pass

    # SIGKILL the process group as last resort
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
        cleanup_instance_files(instance)
        return "VM killed via SIGKILL (process group)"
    except (OSError, ProcessLookupError):
        # Fall back to killing just the PID
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        cleanup_instance_files(instance)
        return "VM process not found (already exited?)"
