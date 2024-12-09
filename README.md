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

You can also git clone https://github.com/systemd/mkosi, symlink to
`mkosi.git/bin/mkosi` and run mkosi directly from source. This works out of the box
with git tags v15 and above. `mkosi/README.md` offers other installation methods.

## mkosi v15+ (Fedora 39+)

Fedora 39 updated mkosi to v15 or higher which contained a lot of breaking changes,
and indeed broke various expectations with run_qemu's usage of it. Basic
run_qemu.sh features are now functional with both mkosi v14- and mkosi v15+ but
please report any bug.

Fedora 39 and 40 have packaged mkosi 14 separately and in parallel to the latest mkosi.
If you want to keep using mkosi v14 on Fedora 39 or 40:

```
# dnf remove --noautoremove mkosi
# dnf install mkosi14
```

Fedora 41 has stopped packaging mkosi14.

See longer mkosi section below.

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
     copying `.ssh/*.pub` keys for easy access, and your `~/.bashrc`
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
 - The root password for the guest VM is `root` by default but note many Linux
   distributions restrict remote root access in various ways. The serial console
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

## DAX Usage

- --dax-debug: Add any and all flags for extra debug of dax modules (kernel)

### Kernel config
- Make sure to Turn on CXL related options in the kernel's .config:
```
$ grep -i cxl .config
CONFIG_CXL_BUS=y
CONFIG_CXL_PCI=m
CONFIG_CXL_MEM_RAW_COMMANDS=y
CONFIG_CXL_ACPI=m
CONFIG_CXL_PMEM=m
CONFIG_CXL_MEM=m
CONFIG_CXL_PORT=y
CONFIG_CXL_SUSPEND=y
```

The following is a way to check basic sanity within the QEMU guest:
```shell
lspci  | grep '3[45]:00'
34:00.0 PCI bridge: Intel Corporation Device 7075
35:00.0 Memory controller [0502]: Intel Corporation Device 0d93 (rev 01)

readlink -f /sys/bus/cxl/devices/mem0
/sys/devices/pci0000:34/0000:34:00.0/0000:35:00.0/mem0
```

# mkosi

mkosi version 15 made a lot of backwards incompatible changes. Fortunately,
the location of configuration files changed at the same time. So `run_qemu.sh`
creates different configuration folder depending on which mkosi version is
detected: `qbuild/mkosi.default.d/*.conf` for version 14 and before, resp.
`qbuild/mkosi.conf.d/*.conf` for version 15 and above.

While no such major break of backwards compatibility has happened after v15
(yet?), features are being added regularly. Various Linux distributions come
with various mkosi versions. So try to keep mkosi configuration(s) as simple as
possible to avoid accidentally breaking someone else using a different mkosi
version. Rely on default values as much as possible.

Fortunately, most mkosi versions are thoroughly documented and you can
easily check the documentation of any version without installing anything.
For versions 14 and before, use this syntax:
  https://github.com/systemd/mkosi/blob/v14/man/mkosi.1
For versions 15 and above go to:
  https://github.com/systemd/mkosi/blob/v15/mkosi/resources/mkosi.md
