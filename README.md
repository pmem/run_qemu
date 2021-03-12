# Requirements
 - mkosi
   - e.g. `dnf install mkosi`
 - `qemu-system-x86_64`
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
 - CLI help is available with `run_qemu.sh --help`
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
     - `ndctl`.
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
