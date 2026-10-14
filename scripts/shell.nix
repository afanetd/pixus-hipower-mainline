# Pixus hiPower / MediaTek MT6580 - Linux 7.2 bring-up environment
# Place this file at ~/pixus-boot-work/shell.nix, then run:
#   cd ~/pixus-boot-work && nix-shell
#
# This environment builds files on the PC only. No flashing is automated.

{ pkgs ? import <nixpkgs> {} }:

let
  llvm = pkgs.llvmPackages_21;
  clang = llvm.clang-unwrapped;
  opensslLib = pkgs.openssl.out;
in
pkgs.mkShell {
  name = "pixus-hipower-mainline";

  packages = with pkgs; [
    # Linux kernel build prerequisites
    gnumake
    bc
    bison
    flex
    pkg-config
    perl
    python3
    nano
    dtc
    cpio
    gzip
    openssl
    elfutils
    ncurses
    zlib

    # Everyday inspection and Android boot tools
    git
    file
    android-tools  # adb, fastboot, mkbootimg

    # Cross-compile ARMv7 with the LLVM 21 tools
    llvm.clang-unwrapped
    llvm.llvm
    llvm.lld
  ];

  shellHook = ''
    export PIXUS_ROOT="$HOME/pixus-boot-work"
    export KBUILD_OUTPUT="$PIXUS_ROOT/build-7.2"
    export ARCH=arm
    export LLVM=1
    export CLANG_DIR="${clang}"
    export CC="$CLANG_DIR/bin/clang"
    export HOSTCC=cc
    export HOSTCXX=c++

    # Bypass Nix's x86_64 compiler wrapper for ARM kernel code.
    # Ensure Kbuild's LLVM=1 also finds unwrapped clang, lld and llvm-* tools.
    export PATH="${clang}/bin:${llvm.llvm}/bin:${llvm.lld}/bin:$PATH"

    # NixOS runtime lookup for the host-built certs/extract-cert tool.
    export LD_LIBRARY_PATH="${opensslLib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # Build helpers are host-only. The existing pixus-bootloader explicitly invokes adb.
    pixus-make() {
      command make -C "$PIXUS_ROOT/linux-mainline" \
        O="$KBUILD_OUTPUT" \
        ARCH=arm LLVM=1 \
        CC="$CLANG_DIR/bin/clang" \
        HOSTCC=cc HOSTCXX=c++ \
        "$@"
    }

    pixus-dtb() {
      pixus-make mediatek/mt6580-pixus-hipower.dtb
    }

    pixus-editor() {
        code "$@"
    }

    pixus-edit-dtb() {
      pixus-editor "$PIXUS_ROOT/linux-mainline/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dts"
    }


    pixus-bootloader() {
      adb reboot bootloader
    }

    pixus-zimage() {
      pixus-make -j4 zImage
    }

    pixus-menuconfig() {
      pixus-make menuconfig
    }

    pixus-append-dtb() {
      local zimage="$KBUILD_OUTPUT/arch/arm/boot/zImage"
      local dtb="$KBUILD_OUTPUT/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dtb"
      if [ ! -s "$zimage" ] || [ ! -s "$dtb" ]; then
        echo "Missing zImage or Pixus DTB; run pixus-zimage and pixus-dtb first." >&2
        return 1
      fi
      cat "$zimage" "$dtb" > "$PIXUS_ROOT/pixus-zImage-dtb"
      ls -lh "$PIXUS_ROOT/pixus-zImage-dtb"
    }

    # Locate the *source directory* of the initramfs. Never edit the .cpio.gz archive directly.
    # Override automatic discovery with: export PIXUS_INIT_ROOT=/path/to/rootfs
    pixus-init-root() {
      local root file found=""
      if [ -n "$PIXUS_INIT_ROOT" ]; then
        if [ -f "$PIXUS_INIT_ROOT/init" ] && [ -e "$PIXUS_INIT_ROOT/bin/busybox" ]; then
          printf '%s\n' "$PIXUS_INIT_ROOT"
          return 0
        fi
        echo "Invalid PIXUS_INIT_ROOT: missing init or bin/busybox" >&2
        return 1
      fi
      while IFS= read -r -d "" file; do
        root="$(dirname "$file")"
        if [ -e "$root/bin/busybox" ]; then
          if [ -n "$found" ]; then
            echo "Multiple initramfs source trees found; set PIXUS_INIT_ROOT explicitly." >&2
            return 1
          fi
          found="$root"
        fi
      done < <(find "$PIXUS_ROOT/initramfs-work" -type f -name init -print0)
      if [ -z "$found" ]; then
        echo "Initramfs source tree not found under initramfs-work/." >&2
        echo "Set PIXUS_INIT_ROOT to the directory containing init and bin/busybox." >&2
        return 1
      fi
      printf '%s\n' "$found"
    }

    # Snapshot the source /init, board DTS, and current compressed initramfs.
    pixus-init-save() {
      local root snap id dts archive
      root="$(pixus-init-root)" || return 1
      id="$(date +%Y%m%d-%H%M%S-%N)"
      snap="$PIXUS_ROOT/backups/init/$id"
      dts="$PIXUS_ROOT/linux-mainline/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dts"
      archive="$PIXUS_ROOT/initramfs-work/pixus-initramfs.cpio.gz"
      mkdir -p "$snap" || return 1
      cp -a "$root/init" "$snap/init" || return 1
      cp -a "$dts" "$snap/board.dts" || return 1
      if [ -s "$archive" ]; then
        cp -a "$archive" "$snap/pixus-initramfs.cpio.gz" || return 1
      fi
      echo "Saved snapshot: $id"
    }

    pixus-init-snapshots() {
      local dir="$PIXUS_ROOT/backups/init"
      if [ -d "$dir" ]; then
        find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
      else
        echo "No snapshots yet."
      fi
    }

    # Restore exact snapshot; never touch tablet partitions.
    pixus-init-restore() {
      local root id snap dts archive
      id="$1"
      if [[ ! "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{9}$ ]]; then
        echo "Usage: pixus-init-restore <ID from pixus-init-snapshots>" >&2
        return 1
      fi
      root="$(pixus-init-root)" || return 1
      snap="$PIXUS_ROOT/backups/init/$id"
      dts="$PIXUS_ROOT/linux-mainline/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dts"
      archive="$PIXUS_ROOT/initramfs-work/pixus-initramfs.cpio.gz"
      if [ ! -f "$snap/init" ] || [ ! -f "$snap/board.dts" ]; then
        echo "Snapshot not found or incomplete: $snap" >&2
        return 1
      fi
      cp -a "$snap/init" "$root/init" || return 1
      cp -a "$snap/board.dts" "$dts" || return 1
      if [ -f "$snap/pixus-initramfs.cpio.gz" ]; then
        cp -a "$snap/pixus-initramfs.cpio.gz" "$archive" || return 1
      fi
      echo "Restored /init, board DTS and available archive from $id."
      echo "Run pixus-init-image to create a boot image from this snapshot."
    }

    # Save before opening the editor. A build is never started by the editor.
    pixus-init() {
      local root
      root="$(pixus-init-root)" || return 1
      pixus-init-save || return 1
      pixus-editor "$root/init"
    }

    # Generate initramfs and update *only* linux,initrd-end in the board DTS.
    pixus-init-pack() {
      local root archive dts tmp
      root="$(pixus-init-root)" || return 1
      archive="$PIXUS_ROOT/initramfs-work/pixus-initramfs.cpio.gz"
      dts="$PIXUS_ROOT/linux-mainline/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dts"
      if [ ! -x "$root/init" ] || [ ! -e "$root/bin/busybox" ]; then
        echo "Expected executable /init and bin/busybox in $root" >&2
        return 1
      fi
      if [ ! -c "$root/dev/console" ]; then
        echo "Expected dev/console character device in $root (do not build a broken archive)." >&2
        return 1
      fi
      tmp="$(mktemp "$archive.tmp.XXXXXXXX")" || return 1
      (
        set -o pipefail
        cd "$root" || exit 1
        find . -mindepth 1 -print0 | \
          cpio --null -o -H newc --owner=0:0 2>/dev/null | \
          gzip -n -9
      ) > "$tmp" || { rm -f "$tmp"; return 1; }
      gzip -t "$tmp" || { rm -f "$tmp"; return 1; }

      # Guard against silently editing the wrong DTS or stale ramdisk-start.
      python3 - "$dts" "$tmp" <<'PY_INNER'
import re
import sys
from pathlib import Path

dts = Path(sys.argv[1])
archive = Path(sys.argv[2])
text = dts.read_text()
number = r'(0x[0-9a-fA-F]+|[0-9]+)'
starts = list(re.finditer(r'\blinux,initrd-start\s*=\s*<\s*' + number + r'\s*>\s*;', text))
ends = list(re.finditer(r'(\blinux,initrd-end\s*=\s*<\s*)' + number + r'(\s*>\s*;)', text))
if len(starts) != 1 or len(ends) != 1:
    sys.exit('ERROR: expected one linux,initrd-start and one linux,initrd-end in board DTS')
start = int(starts[0].group(1), 0)
if start != 0x84000000:
    sys.exit(f'ERROR: unexpected initrd-start: {start:#x}; verify boot header first')
size = archive.stat().st_size
if not 0 < size <= 16 * 1024 * 1024:
    sys.exit(f'ERROR: unexpected ramdisk size {size}; verify memory layout')
end = start + size
m = ends[0]
updated = text[:m.start()] + m.group(1) + f'0x{end:08x}' + m.group(3) + text[m.end():]
if updated != text:
    dts.write_text(updated)
print(f'Initramfs: {size} bytes; DT chosen initrd range: {start:#010x}..{end:#010x}')
PY_INNER
      if [ "$?" -ne 0 ]; then
        rm -f "$tmp"
        return 1
      fi
      mv -f "$tmp" "$archive" || return 1
      echo "Packed: $archive"
    }

    # Recompile the DTB and package an Android boot v0 image; HOST-ONLY.
    pixus-init-image() {
      local image tmp kernel archive dtb start_hex end_hex actual_size
      image="$1"
      if [ -z "$image" ]; then image="$PIXUS_ROOT/pixus-mainline-dev.img"; fi
      kernel="$PIXUS_ROOT/pixus-zImage-dtb"
      archive="$PIXUS_ROOT/initramfs-work/pixus-initramfs.cpio.gz"
      [ -s "$archive" ] || { echo "Missing $archive" >&2; return 1; }
      pixus-dtb || return 1
      dtb="$KBUILD_OUTPUT/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dtb"
      start_hex="$(fdtget -t x "$dtb" /chosen linux,initrd-start)" || return 1
      end_hex="$(fdtget -t x "$dtb" /chosen linux,initrd-end)" || return 1
      actual_size="$(stat -c%s "$archive")" || return 1
      if [ "$start_hex" != "84000000" ] || \
         [ "$((16#$end_hex - 16#$start_hex))" -ne "$actual_size" ]; then
        echo "DTB initrd address range does not match ramdisk size; run pixus-init-pack." >&2
        return 1
      fi
      pixus-append-dtb || return 1
      tmp="$(mktemp "$image.tmp.XXXXXXXX")" || return 1
      mkbootimg \
        --kernel "$kernel" \
        --ramdisk "$archive" \
        --header_version 0 \
        --base 0x80000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x04000000 \
        --tags_offset 0x0e000000 \
        --pagesize 2048 \
        --cmdline 'bootopt=64S3,32S1,32S1 rdinit=/init loglevel=8 ignore_loglevel panic=15' \
        --output "$tmp" || { rm -f "$tmp"; return 1; }
      if [ -f "$PIXUS_ROOT/pixus_boot_audit.py" ]; then
        python3 "$PIXUS_ROOT/pixus_boot_audit.py" "$tmp" || { rm -f "$tmp"; return 1; }
      else
        echo "Warning: pixus_boot_audit.py not found, image not fully audited." >&2
      fi
      mv -f "$tmp" "$image" || return 1
      echo "READY: $image"
      echo "No device command was executed. Inspect the image before manual RAM boot."
    }

    # Single-command build: modified /init -> archive -> DTS/DTB -> boot image.
    pixus-init-build() {
      pixus-init-pack || return 1
      pixus-init-image "$@"
    }

    # Extra-short interactive shortcuts.
    pi()  { pixus-init "$@"; }
    pib() { pixus-init-build "$@"; }
    pis() { pixus-init-snapshots; }
    pir() { pixus-init-restore "$@"; }

    pixus-root() { cd "$PIXUS_ROOT"; }
    pixus-src()  { cd "$PIXUS_ROOT/linux-mainline"; }
    pixus-build() { cd "$KBUILD_OUTPUT"; }

    pixus-info() {
      printf 'Pixus project : %s\n' "$PIXUS_ROOT"
      printf 'Linux sources : %s\n' "$PIXUS_ROOT/linux-mainline"
      printf 'Build output  : %s\n' "$KBUILD_OUTPUT"
      printf 'Architecture  : %s\n' "$ARCH"
      printf 'Clang         : %s\n' "$CC"
      "$CC" --version | head -n 1
      printf '\nCommands: pixus-dtb, pixus-zimage, pixus-menuconfig, pixus-append-dtb\n'
      printf '           pixus-make <target>, pixus-root, pixus-src, pixus-build, pixus-edit-dtb\n'
      printf '           pixus-init (edit + snapshot), pixus-init-build [image.img] (full build)\n'
      printf '           pixus-init-pack, pixus-init-image [image.img], pixus-init-root\n'
      printf '           pixus-init-save, pixus-init-snapshots, pixus-init-restore ID\n'
      printf '           Shortcuts: pi (edit), pib (build), pis (list), pir ID (restore)\n'
    }

    echo 'Pixus hiPower build shell ready. Run pixus-info for paths and commands.'
  '';
}
