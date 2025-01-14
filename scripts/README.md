Logs and autorun
----------------

Some of these scripts are installed in the image and `run_qemu.sh` can
configure systemd to autorun them at boot time.

By default, systemctl logs the stdout and stderr (including plain set
-x) of what it starts at the journalctl -p priority level 6
(info). These are NOT in the "kernel" logging facility hence not on QEMU
serial console and not visible outside the VM. You must ssh to see these
logs.

On the other hand, commands inside these scripts frequently report
status by printing to `/dev/kmsg` which is in the "kernel" facility and
does exit the VM through QEMU's serial port.

https://www.kernel.org/doc/Documentation/ABI/testing/dev-kmsg

When the printed line has no <PREFIX>, "echo foo > /dev/kmsg" is logged
at the "default kernel priority".  On Fedora, this is priority level 4
(warn).
