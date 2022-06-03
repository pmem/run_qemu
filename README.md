# Requirements
 - mkosi
   - e.g. `dnf install mkosi`
 - `qemu-system-x86_64`
 - rsync
 - dracut
 - enabled virtualization (KVM)
 - nopasswd sudo preferred, or run as root, or enter passwords into the prompt
 several times
 - `argbash` to generate the argument parser lib (using `parser_generator.m4`)

# Installation
 - symlink the `run_qemu.sh` script into somewhere in your `PATH`
   - e.g. `ln -s ~/git/run_qemu/run_qemu.sh ~/bin/run_qemu.sh`
 - **Note:** Supporting files in this repo are required to be in the same
   location as the script, after any symlink resolution. Copying just the
   script itself will not work.
 - **Bash Completion**
   - Copy or symlink the `run_qemu` file into the default bash completions dir
   - The completions directory can be found using:
       `pkg-config --variable=completionsdir bash-completion`


# Usage Notes
 - Run this from the top level of a Linux kernel tree
   - e.g. `run_qemu.sh --cxl --git-qemu`
 - The script can/will:
   - Build the kernel with whatever .config is present
     (It is up to the user to manage the .config)
   - Create a rootfs image with the chosen distro using `mkosi`
   - Perform some basic setup on the rootfs, including installing the kernel,
     utilities (such as `ndctl`), and other convenience operations such as
     copying your `~/.ssh/id_rsa.pub` for easy ssh access, and your `~/.bashrc`
     etc.
   - Boot qemu with the newly compiled kernel provided on the qemu command line,
     and using the rootfs image above
   - Various options influence the qemu command line generated - there are
     options to select NUMA config, NVDIMMs, NVME devices, CXL devices etc.
 - More detailed CLI help is available with `run_qemu.sh --help`
 - Once qemu starts, in nographic mode, the Linux console 'takes over' the
   terminal. To interact with it, the following are useful:
   - `Ctrl-a c` : switch between the qemu monitor prompt `(qemu)` and console
   - `Ctrl-a x` : kill qemu and exit
 - `mkosi` creates a package cache in `mkosi.cache/`  If a cache is present,
   it will always use only that, and never go over the network even if newer
   packages are available. To force re-fetching everything, remove this
   directory, or --rebuild=wipe which removes the `builddir` entirely.
 - Which `qemu` to use can be overridden from the environment:
       `qemu=/path/to/qemu/build/qemu-system-x86_64 ./run_qemu.sh [options]`
 - List of variables that have overrides via `env`:
     - `qemu`
     - `gdb`
     - `distro`
     - `rev`
     - `builddir`
     - `ndctl`
 - To use the 'hostfwd' network, put this in your `.ssh/config`:

       Host rq
       Hostname localhost
       User root
       Port 10022
       StrictHostKeyChecking no
       UserKnownHostsFile /dev/null

    And then `ssh rq`. You may need to open port 10022 on any local firewalls.
 - The root password for the guest VM is `root`. The serial console
   automatically logs in, and a password isn't required.

## CXL Usage

The script enables generating a sane QEMU commandline for instantiating a basic CXL topology. Since QEMU support for CXL isn't yet upstream, `--git-qemu` is additionally required. The CXL related options are:
- `--cxl`: Enables a simple CXL topology with:
  - single host bridge
    - 512M window size at 0x4c00000000
    - Bus #52
  - single root port
  - single Type 3 device
    - Persistent 256M
  - simple label storage area
- --cxl-debug: Add any and all flags for extra debug (kernel and QEMU)
- --cxl-hb: Turn q35 into a CXL capable Host bridge. Don't use this option unless you're working on support for this.
- --cxl-test-run: Attempt to do a sanity test of the kernel and QEMU configuration.

### Kernel config
- Make sure to Turn on CXL related options in the kernel's .config:
```
$ grep -i cxl .config
CONFIG_CXL_BUS=m
CONFIG_CXL_MEM=m
CONFIG_CXL_MEM_RAW_COMMANDS=y
CONFIG_CXL_ACPI=m
```

The following is a way to check basic sanity within the QEMU guest:
```shell
lspci  | grep '3[45]:00'
34:00.0 PCI bridge: Intel Corporation Device 7075
35:00.0 Memory controller [0502]: Intel Corporation Device 0d93 (rev 01)

readlink -f /sys/bus/cxl/devices/mem0
/sys/devices/pci0000:34/0000:34:00.0/0000:35:00.0/mem0
```
