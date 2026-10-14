#!/usr/bin/env python3
"""Read-only Android boot image v0 audit for Pixus hiPower (MT6580).

Usage:
  python3 pixus_boot_audit.py ~/pixus-boot-work/pixus-mainline-no-atag-mem.img

The program reads local files only and never invokes adb/fastboot.
"""
import argparse
import gzip
import hashlib
from pathlib import Path
import struct
import sys

BOOT_FMT = '<8s10I16s512s32s'
BOOT_FIELDS = (
    'magic', 'kernel_size', 'kernel_addr', 'ramdisk_size', 'ramdisk_addr',
    'second_size', 'second_addr', 'tags_addr', 'page_size', 'dt_size',
    'unused', 'name', 'cmdline', 'id',
)
ZIMAGE_MAGIC = 0x016F2818
FDT_MAGIC = 0xD00DFEED
RAMOOPS_START, RAMOOPS_END = 0x83F10000, 0x83FF0000
RAMCON_START, RAMCON_END = 0x83F00000, 0x83F10000
MINIDUMP_START, MINIDUMP_END = 0x83FF0000, 0x84000000


def sha(data):
    return hashlib.sha256(data).hexdigest()


def align(n, page):
    return (n + page - 1) // page * page


def check_match(label, actual, path):
    if not path.is_file():
        print(f'  {label}: нет файла для сравнения ({path.name})')
        return
    ref = path.read_bytes()
    eq = actual == ref
    print(f'  {label}: {"MATCH" if eq else "MISMATCH"} ({path})')
    if not eq:
        print(f'    образ: {sha(actual)[:16]}..., текущий файл: {sha(ref)[:16]}...')


def parse_cpio(blob):
    out = {}
    pos = 0
    for _ in range(100000):
        if blob[pos:pos+6] not in (b'070701', b'070702'):
            return out, f'Остановка на смещении {pos}, заголовок {blob[pos:pos+8]!r}'
        if pos + 110 > len(blob):
            return out, 'Обрезанный заголовок cpio'
        try:
            vals = [int(blob[pos+6+j*8:pos+14+j*8], 16) for j in range(13)]
        except ValueError:
            return out, 'Некорректные числа в заголовке cpio'
        mode, size, namesize = vals[1], vals[6], vals[11]
        if not (0 < namesize < 4096):
            return out, f'Некорректная длина имени: {namesize}'
        name_start = pos + 110
        name = blob[name_start:name_start+namesize].rstrip(b'\x00').decode('utf-8', 'replace')
        content_start = align(name_start+namesize, 4)
        content_end = content_start+size
        if content_end > len(blob):
            return out, f'Файл {name}: за пределами архива'
        if name == 'TRAILER!!!':
            return out, 'TRAILER!!! найден'
        out[name.removeprefix('./').removeprefix('/')] = (mode, blob[content_start:content_end])
        pos = align(content_end, 4)
    return out, 'Слишком много записей'


def compare_overlap(a_start, a_end, b_start, b_end):
    return max(a_start, b_start) < min(a_end, b_end)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path, help='проверяемый boot.img (только чтение)')
    parser.add_argument('--root', type=Path, help='корень pixus-boot-work; по умолчанию каталог образа')
    args = parser.parse_args()
    path = args.image.expanduser().resolve()
    root = (args.root or path.parent).expanduser().resolve()
    try:
        data = path.read_bytes()
    except OSError as e:
        sys.exit(f'Не удалось прочитать: {e}')
    print(f'Образ: {path}\nРазмер: {len(data):,} байт\nSHA256: {sha(data)}')
    if len(data) < struct.calcsize(BOOT_FMT):
        sys.exit('ОШИБКА: файл слишком короткий для Android boot header')
    h = dict(zip(BOOT_FIELDS, struct.unpack_from(BOOT_FMT, data)))
    if h['magic'] != b'ANDROID!':
        sys.exit(f'ОШИБКА: нет ANDROID! magic: {h["magic"]!r}')
    page = h['page_size']
    if page < 512 or page > 65536 or (page & (page-1)):
        sys.exit(f'ОШИБКА: неверный page_size: {page}')
    # Includes Android boot image legacy extra_cmdline field (1024 bytes).
    cmdline = (h['cmdline'] + data[608:1632]).split(b'\x00', 1)[0].decode('utf-8', 'replace')
    print('\n=== Android boot header ===')
    for key in ('kernel_addr', 'ramdisk_addr', 'second_addr', 'tags_addr'):
        print(f'  {key:15s}: 0x{h[key]:08X}')
    for key in ('kernel_size', 'ramdisk_size', 'second_size', 'dt_size', 'page_size'):
        print(f'  {key:15s}: {h[key]:,}')
    print('  name:', h['name'].split(b'\0')[0].decode('utf-8', 'replace'))
    print('  cmdline:', cmdline)
    if h['unused']:
        print('  ПРЕДУПРЕЖДЕНИЕ: reserved/unused != 0; возможно, заголовок иной версии')
    if page != 2048:
        print('  ПРЕДУПРЕЖДЕНИЕ: у штатного Pixus page_size=2048')
    for key, expect in (('kernel_addr', 0x80008000), ('ramdisk_addr', 0x84000000), ('tags_addr', 0x8E000000)):
        if h[key] != expect:
            print(f'  ПРЕДУПРЕЖДЕНИЕ: {key} отличается от stock ({expect:#010x})')
    if 'rdinit=/init' not in cmdline:
        print('  ПРЕДУПРЕЖДЕНИЕ: rdinit=/init не найден в boot cmdline')
    kern_off = page
    ram_off = kern_off + align(h['kernel_size'], page)
    second_off = ram_off + align(h['ramdisk_size'], page)
    dt_off = second_off + align(h['second_size'], page)
    areas = [('kernel', kern_off, h['kernel_size']), ('ramdisk', ram_off, h['ramdisk_size']),
             ('second', second_off, h['second_size']), ('dt', dt_off, h['dt_size'])]
    print('\n=== Секции в файле ===')
    for label, start, size in areas:
        print(f'  {label:7s}: file offset 0x{start:X}..0x{start+size:X} ({size:,} bytes)')
        if start+size > len(data):
            sys.exit(f'ОШИБКА: секция {label} выходит за конец файла!')
    kernel = data[kern_off:kern_off+h['kernel_size']]
    ramdisk = data[ram_off:ram_off+h['ramdisk_size']]
    print('\n=== ARM zImage и appended DTB ===')
    if len(kernel) < 0x30:
        sys.exit('ОШИБКА: kernel payload слишком короткий')
    magic, zstart, zend = struct.unpack_from('<III', kernel, 0x24)
    print(f'  zImage magic: 0x{magic:08X} ({"OK" if magic == ZIMAGE_MAGIC else "INVALID"})')
    print(f'  zImage start/end в заголовке: 0x{zstart:X} / 0x{zend:X}')
    if magic != ZIMAGE_MAGIC:
        print('  ОШИБКА: kernel payload не начинается с ожидаемого ARM zImage')
    if not (0 < zend <= len(kernel)):
        print('  ОШИБКА: zImage end выходит за kernel payload')
        zbytes, dtb_bytes = kernel, b''
    else:
        zbytes, dtb_bytes = kernel[:zend], kernel[zend:]
        print(f'  Размер zImage: {len(zbytes):,}; остаток после него: {len(dtb_bytes):,}')
        if len(dtb_bytes) >= 8:
            fdt_magic, fdt_size = struct.unpack_from('>II', dtb_bytes)
            print(f'  DTB magic: 0x{fdt_magic:08X} ({"OK" if fdt_magic == FDT_MAGIC else "INVALID"})')
            print(f'  DTB declared totalsize: {fdt_size:,} байт')
            if fdt_magic == FDT_MAGIC and fdt_size <= len(dtb_bytes):
                print('  Appended DTB: корректные границы')
            else:
                print('  ОШИБКА: нет корректного appended DTB по ARM zImage end')
        else:
            print('  ОШИБКА: appended DTB отсутствует/обрезан')
    print('\n=== Initramfs ===')
    print('  gzip magic:', 'OK' if ramdisk.startswith(b'\x1f\x8b') else 'НЕ gzip')
    try:
        uncompressed = gzip.decompress(ramdisk)
        print(f'  gzip распаковывается: OK, {len(uncompressed):,} bytes')
        files, status = parse_cpio(uncompressed)
        print(f'  cpio: {status}; файлов: {len(files)}')
        for name in ('init', 'bin/busybox', 'bin/sh', 'sbin/init'):
            if name in files:
                mode, content = files[name]
                typ = ('symlink' if mode & 0o170000 == 0o120000 else
                       'regular' if mode & 0o170000 == 0o100000 else 'other')
                print(f'  /{name}: {typ}, mode {mode:o}, length {len(content)}')
                if name == 'init':
                    print('    начало:', repr(content[:120]))
                    if not mode & 0o111:
                        print('    ОШИБКА: /init без execute-бита')
            elif name == 'init':
                print('  ОШИБКА: /init не найден в cpio')
        if uncompressed[:6] not in (b'070701', b'070702'):
            print('  ПРЕДУПРЕЖДЕНИЕ: cpio не начинается с newc заголовка')
    except (OSError, EOFError, ValueError) as e:
        print(f'  ОШИБКА при распаковке gzip: {e}')
    print('\n=== Сравнение с актуальными файлами сборки ===')
    check_match('kernel payload = pixus-zImage-dtb', kernel, root/'pixus-zImage-dtb')
    check_match('zImage внутри boot = текущий zImage', zbytes,
                root/'build-7.2/arch/arm/boot/zImage')
    check_match('appended DTB = текущий DTB', dtb_bytes,
                root/'build-7.2/arch/arm/boot/dts/mediatek/mt6580-pixus-hipower.dtb')
    check_match('ramdisk = текущий initramfs', ramdisk,
                root/'initramfs-work/pixus-initramfs.cpio.gz')
    print('\n=== Быстрая проверка диапазонов физической RAM ===')
    for label, lo, size in (('загруженный zImage', h['kernel_addr'], len(zbytes)),
                            ('загруженный ramdisk', h['ramdisk_addr'], len(ramdisk))):
        hi = lo+size
        print(f'  {label}: 0x{lo:08X}..0x{hi:08X}')
        for rlabel, rs, re in (('ram_console', RAMCON_START, RAMCON_END),
                               ('ramoops', RAMOOPS_START, RAMOOPS_END),
                               ('minidump', MINIDUMP_START, MINIDUMP_END)):
            if compare_overlap(lo, hi, rs, re):
                print(f'  ОШИБКА: пересечение с {rlabel}')
    image = root/'build-7.2/arch/arm/boot/Image'
    if image.is_file():
        imsize = image.stat().st_size
        # Only an estimate: .bss, decompressor scratch, LK fixups not accounted for.
        lo = (h['kernel_addr'] & 0xF8000000) + 0x8000
        hi = lo + imsize
        print(f'  распакованный Image (ОЦЕНКА): 0x{lo:08X}..0x{hi:08X}')
        for rlabel, rs, re in (('ram_console', RAMCON_START, RAMCON_END),
                               ('ramoops', RAMOOPS_START, RAMOOPS_END),
                               ('minidump', MINIDUMP_START, MINIDUMP_END)):
            if compare_overlap(lo, hi, rs, re):
                print(f'  ВНИМАНИЕ: Image пересекает {rlabel}')
    print('\nПроверка завершена. Никакие данные планшета или файла boot.img не изменялись.')


if __name__ == '__main__':
    main()
