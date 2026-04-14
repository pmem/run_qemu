---
name: run-qemu
description: Use this skill for building Linux kernels and booting QEMU VMs with custom topologies (CXL, NUMA, NVDIMMs). Covers building, launching, testing inside VMs, and managing VM lifecycle via MCP tools or CLI.
---

# run_qemu

## Overview

`run_qemu` builds a Linux kernel from a source tree, creates a Fedora rootfs using mkosi, installs the kernel into it, and boots QEMU with a generated command line. It supports complex NUMA/CXL/NVDIMM topologies and provides SSH access to the guest.

**Run from the root of a Linux kernel tree.** The `run_qemu.sh` script should be in the user's PATH.

**Prerequisites:** mkosi, qemu-system-x86_64, rsync, dracut, KVM-enabled host, nopasswd sudo preferred.

## MCP Tools (Primary Agent Interface)

When the `run-qemu` MCP server is available, use these tools for all VM operations. They provide structured, async-safe interaction with run_qemu.

### Typical Agent Workflow

```
1. vm_start(linux_dir=".", rebuild="kmod", preset="small", cxl=true)
   → Returns immediately. VM is building in background.

2. vm_status(instance=0)
   → Poll every 30-60s until state is "ready".
   States: starting → ready (or exited on failure)

3. vm_run(instance=0, command="uname -r")
   → Execute commands inside the VM via SSH.

4. vm_dmesg(instance=0, grep="cxl")
   → Check kernel log for specific messages.

5. vm_log(instance=0, tail_lines=100)
   → Read console log for boot messages or errors.

6. vm_stop(instance=0)
   → Graceful shutdown when done.
```

### Tool Reference

#### `vm_start` — Build kernel and launch VM

Builds the kernel, creates/updates the rootfs, and launches QEMU in the background. Returns immediately with instance info. Runs `make olddefconfig` by default to avoid interactive config prompts.

**Typed parameters (common options):**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `linux_dir` | str | `.` | Path to the Linux kernel tree |
| `rebuild` | str | `kmod` | `kmod` (rebuild kernel+modules), `img` (full rootfs), `wipe` (clean slate), `none` (just boot) |
| `preset` | str | `small` | NUMA topology: `tiny`, `small`, `med`, `large`, `huge` |
| `cxl` | bool | false | Enable CXL topology |
| `cxl_test` | bool | false | CXL unit test environment (includes cxl_test kernel module) |
| `nfit_test` | bool | false | NFIT unit test environment (includes libnvdimm test modules). Overrides preset to `med`. |
| `defconfig` | bool | true | Run `make olddefconfig` before building |
| `instance` | int | 0 | Instance number — determines SSH port (10022+N) |
| `timeout_minutes` | int | 0 | Auto-kill timeout in minutes (0=disabled) |

**`extra_args`** (str): Any additional run_qemu.sh options not covered above, passed verbatim. Examples:
- `"--cxl-debug"` — enable CXL dyndbg
- `"--hmat"` — enable HMAT table
- `"--kcmd-append myfile.txt"` — append kernel command line from file
- `"--no-kvm"` — disable KVM (for environments without hardware virtualization)

#### `vm_status` — Check VM state

Returns the current state: `starting`, `ready`, `exited`, or `unknown`. When `ready`, the SSH connection string is included.

#### `vm_run` — Execute command in VM

Runs a shell command via SSH. Returns stdout, stderr, and exit code. The VM must be in `ready` state.

#### `vm_dmesg` — Read kernel log

Reads `dmesg` from the VM. Supports filtering by level (`err`, `warn`) and grep pattern.

#### `vm_log` — Read console log

Reads the QEMU console log file. Supports tail (last N lines) and grep filtering.

#### `vm_stop` — Stop VM

Gracefully shuts down the VM. Tries QMP quit → SSH poweroff → SIGTERM → SIGKILL.

#### `vm_list` — List running VMs

Shows all running run_qemu instances with their state and SSH ports.

### Common MCP Workflows

#### CXL Topology Testing

```
vm_start(cxl=true, preset="small", extra_args="--cxl-debug")
# Poll vm_status until ready...
vm_run(command="lspci | grep '3[45]:00'")
vm_run(command="readlink -f /sys/bus/cxl/devices/mem0")
vm_dmesg(grep="cxl")
```

The default CXL topology creates:
- 1 CXL host bridge (bus #52, window at 0x4c00000000)
- 1 root port
- 1 Type 3 device (256M persistent)

#### CXL Unit Testing (cxl_test)

Uses the kernel's `cxl_test` module to mock a CXL hierarchy without real hardware:

```
vm_start(cxl_test=true, extra_args="--cxl-debug")
# cxl_test implies cxl, and includes extra CXL mock modules
vm_run(command="modprobe cxl_test")
vm_dmesg(grep="cxl_test")
```

#### NFIT Unit Testing (nfit_test)

Tests libnvdimm with mock NFIT/NVDIMM devices. Forces preset to `med`:

```
vm_start(nfit_test=true)
# Includes libnvdimm 'extra' modules and memmap reserved memory
vm_run(command="modprobe nfit_test")
vm_dmesg(grep="nfit")
```

#### Multiple VMs

```
vm_start(instance=0, preset="small")        # SSH port 10022
vm_start(instance=1, preset="med", cxl=true) # SSH port 10023
vm_run(instance=0, command="uname -r")
vm_run(instance=1, command="lspci | grep CXL")
```

## Core Concepts

### Build Directory

run_qemu creates a `builddir` (default: `../builddir-<branch>`) containing:
- The rootfs image (`root.img`)
- mkosi cache (`mkosi.cache/`)
- Built kernel artifacts

### Rebuild Modes

| Mode | What it does | When to use |
|------|-------------|-------------|
| `kmod` | Rebuild kernel + update rootfs modules | **Default**. Iterative kernel development |
| `img` | Rebuild entire rootfs image from scratch | When rootfs is broken or after major config changes |
| `wipe` | Delete everything (including package cache) and rebuild | When switching distro versions or corrupted cache |
| `none` | Don't rebuild anything, just boot | Quick re-test of existing build |

### Topology Presets

| Preset | Nodes | Mem-only | PMEMs | EFI-mems | Legacy-PMEMs |
|--------|-------|----------|-------|----------|-------------|
| tiny   | 1 | 0 | 1 | 0 | 0 |
| small  | 2 | 0 | 2 | 0 | 0 |
| med    | 2 | 4 | 4 | 1 | 2 |
| large  | 4 | 4 | 4 | 2 | 2 |
| huge   | 8 | 8 | 8 | 2 | 2 |

### Kernel .config Management

run_qemu does **not** manage .config — it's the user's responsibility. The MCP's `vm_start` runs `make olddefconfig` by default to avoid interactive prompts. Common patterns:
```bash
make defconfig
# Or merge CXL configs:
./scripts/kconfig/merge_config.sh .config ../run_qemu/.github/workflows/*.cfg
```

### SSH Access

- SSH port = 10022 + instance number
- Root password: `root` (serial console auto-logs in)
- Recommended `.ssh/config`:
  ```
  Host rq
    Hostname localhost
    User root
    Port 10022
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
  ```
- File sharing: `dpipe /usr/lib/ssh/sftp-server = ssh rq sshfs :$HOME/CXL /root/CXL -o passive`

## Manual CLI Workflows (when MCP not available)

If the MCP tools are not available, drive `run_qemu.sh` directly from a bash shell.

### Interactive Kernel Test
```bash
cd /path/to/linux
run_qemu.sh --defconfig --preset=small
# Drops you into a serial console. Ctrl-a x to exit.
# SSH in from another terminal: ssh -p 10022 root@localhost
```

### CXL Topology Testing
```bash
run_qemu.sh --defconfig --cxl --cxl-debug --preset=small
```

### CXL Unit Testing
```bash
run_qemu.sh --defconfig --cxl-test --cxl-debug
```

### NFIT Unit Testing
```bash
run_qemu.sh --defconfig --nfit-test
# Note: --nfit-test forces preset=med
```

### Automated Test Run
```bash
run_qemu.sh --defconfig --autorun=my_test.sh --timeout=10 --log=/tmp/rq_test.log
# Runs my_test.sh as a systemd service on boot
# Kills VM after 10 minutes
# Console output captured in /tmp/rq_test.log
```

### Iterative Development Cycle
```bash
# First run (creates rootfs):
run_qemu.sh --defconfig --rebuild=img --cxl

# Subsequent runs (kernel-only rebuild, fast):
run_qemu.sh --defconfig --cxl
# (default --rebuild=kmod rebuilds the kernel and updates modules)
```

## Option Reference

### Build & Image
| Option | Description |
|--------|-------------|
| `--rebuild=MODE` | kmod (default), img, wipe, none |
| `--rootfs=FILE` | Non-default rootfs image (default: root.img) |
| `--strip-modules` | Strip kernel modules after install |
| `--defconfig` | Run `make olddefconfig` before build |
| `--mirror=URL` | Use alternate package mirror |
| `--ndctl-build` / `--no-ndctl-build` | Build ndctl in rootfs (default: on) |

### Topology
| Option | Description |
|--------|-------------|
| `--preset=NAME` | tiny, small (default), med, large, huge |
| `--nodes=N` | CPU+memory nodes |
| `--mems=N` | Memory-only nodes |
| `--pmems=N` | Persistent memory DIMMs |
| `--nvmes=N` | NVMe devices |
| `--mem-size=MiB` | Size of each memory device (default: 2048) |

### CXL
| Option | Description |
|--------|-------------|
| `--cxl` | Enable CXL topology |
| `--cxl-debug` | Enable CXL dyndbg |
| `--cxl-pmems=N` | Number of CXL memdevs with pmem (0-4, default: 2) |
| `--cxl-test` | Set up CXL unit test environment (includes cxl_test module) |

### NFIT / NVDIMM
| Option | Description |
|--------|-------------|
| `--nfit-test` | Set up NFIT unit test environment (forces preset=med) |
| `--nfit-debug` | Enable NVDIMM/NFIT dyndbg |
| `--dax-debug` | Enable DAX dyndbg |

### Runtime
| Option | Description |
|--------|-------------|
| `--instance=N` / `-n N` | Instance ID, offsets SSH port (default: 0) |
| `--timeout=MIN` / `-t MIN` | Auto-kill timeout in minutes (0=disabled) |
| `--log=FILE` / `-l FILE` | Console output to file |
| `--autorun=FILE` / `-A FILE` | Run FILE as systemd service on boot |
| `--post-script=FILE` | Run FILE after VM exits |

### Kernel Command Line
| Option | Description |
|--------|-------------|
| `--kcmd-replace=FILE` | Replace kernel cmdline from FILE |
| `--kcmd-append=FILE` | Append to kernel cmdline from FILE |

### Display & Debug
| Option | Description |
|--------|-------------|
| `--gdb` | Wait for GDB connection (port 10000) |
| `--gdb-qemu` | Start QEMU under GDB |
| `--qmp` | Enable QMP control socket |
| `--debug` / `-v` | Enable set -x debugging |
| `--cmdline` | Print QEMU command line without starting |
| `--curses` | Use curses display instead of nographic |

### Other
| Option | Description |
|--------|-------------|
| `--rw` | Persist runtime image changes |
| `--no-kvm` | Disable KVM (slow, for non-KVM hosts) |
| `--legacy-bios` | Don't use OVMF/EDK2 |
| `--direct-kernel` / `--no-direct-kernel` | Supply kernel to QEMU via -kernel (default: on) |
| `--forget-disks` | Force re-creation of disk images |
| `--hmat` | Set up HMAT table in QEMU |
| `--git-qemu` / `-g` | Use QEMU from ~/git/qemu/ |
| `--quiet` / `-q` | Reduce output verbosity |

## Troubleshooting

### Build Failures
- Check that `.config` exists and has the needed options enabled
- Use `--rebuild=wipe` to start fresh if the rootfs is corrupted
- mkosi cache issues: remove `builddir/mkosi.cache/` or use `--rebuild=wipe`

### VM Won't Boot
- Check the log file (`vm_log` or `--log`) for kernel panics
- Try `--no-kvm` if hardware virtualization isn't available
- Verify QEMU is installed: `qemu-system-x86_64 --version`

### SSH Not Connecting
- Verify the correct port: 10022 + instance number
- Check host firewall: port 10022 may be blocked
- Wait for boot to complete — the VM needs time to start sshd
- Check `vm_log` for boot progress

### CXL Devices Not Visible
- Ensure `.config` has CXL options enabled (CONFIG_CXL_BUS=y, CONFIG_CXL_PCI=m, etc.)
- Use `--cxl-debug` for dyndbg output
- Check `vm_dmesg(grep="cxl")` for driver messages

### nfit_test / cxl_test Issues
- These require `--rebuild=img` or higher when switching to/from test mode
- Check that the test modules are built: `vm_run(command="modinfo cxl_test")`
