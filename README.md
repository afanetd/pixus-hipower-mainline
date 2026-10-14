# Pixus hiPower — Mainline Linux Bring-up

Experimental mainline Linux bring-up for the Pixus hiPower tablet,
based on the MediaTek MT6580/MT8321 platform.

## Current status

Linux 7.2 boots successfully using `fastboot boot` and reaches
a BusyBox-based initramfs userspace.

### Confirmed working

- ARMv7 kernel boot on CPU0
- Device Tree and initramfs loading
- BusyBox `/init`
- MediaTek GPT timer and timer interrupts
- pstore/ramoops debugging
- MediaTek watchdog driver and kernel watchdog pings

### Work in progress

- USB gadget / MUSB controller
- UART console
- ARM architected timer
- SMP (secondary CPU cores)
- MMC/eMMC
- Display and other peripherals

## Development

The project uses experimental RAM-only boot images.
The stock Android installation is retained for hardware research
and diagnostic log collection.

This is an early bring-up project, not a complete Linux port.
