#!/usr/bin/env python3
"""kernel_info.py - bandingkan kernel di boot.img dengan modul di vendor_boot.

Modul vendor (lib/modules di vendor_boot) hanya bisa dipakai kernel yang
"cocok": vermagic sama dan versi simbol (CONFIG_MODVERSIONS) cocok. Kalau
tidak cocok, recovery berhenti sebelum UI tampil (layar hitam / balik ke
fastboot) walaupun ramdisk-nya benar.

Pemakaian:
    python3 tools/kernel_info.py --boot boot.img
    python3 tools/kernel_info.py --modules /path/lib/modules
    python3 tools/kernel_info.py --vendor-boot vendor_boot.img
    python3 tools/kernel_info.py --boot boot.img --vendor-boot vendor_boot.img
"""

import argparse
import gzip
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vbimg2  # noqa: E402


def kernel_banner(boot):
    d = open(boot, "rb").read()
    if d[:8] != b"ANDROID!":
        raise SystemExit("bukan boot.img Android: %s" % boot)
    ksize, = struct.unpack_from("<I", d, 8)
    k = d[4096:4096 + ksize]
    if k[:2] == b"\x1f\x8b":
        k = gzip.decompress(k)
    elif k[:4] == b"\x02\x21\x4c\x18":
        import lz4.block
        k = lz4.block.decompress(k, uncompressed_size=96 * 1024 * 1024)
    m = re.search(rb"Linux version ([0-9][^\x00\n]{0,140})", k)
    if not m:
        raise SystemExit("banner 'Linux version' tidak ketemu di %s" % boot)
    return m.group(1).decode("utf-8", "replace")


def vermagic_of(body):
    i = body.find(b"vermagic=")
    if i < 0:
        return None
    return body[i + 9:body.find(b"\0", i)].decode("utf-8", "replace")


def scan_dir(path):
    out = {}
    for root, _, files in os.walk(path):
        for fn in files:
            if fn.endswith(".ko"):
                vm = vermagic_of(open(os.path.join(root, fn), "rb").read())
                if vm:
                    out[vm] = out.get(vm, 0) + 1
    return out


def scan_vendor_boot(img):
    info = vbimg2.parse_image(img)
    out = {}
    for f in info["frags"]:
        data = f["data"]
        if data[:4] == b"\x02\x21\x4c\x18":
            data = vbimg2.lz4_legacy_decompress(data)
        for e in vbimg2.cpio_parse(data):
            if e["name"].startswith("lib/modules/") and e["name"].endswith(".ko"):
                vm = vermagic_of(e["body"])
                if vm:
                    out[vm] = out.get(vm, 0) + 1
    return out


def show(title, table):
    print("%s:" % title)
    if not table:
        print("  (tidak ada modul)")
        return
    for vm, n in sorted(table.items(), key=lambda kv: -kv[1]):
        print("  %-72s %3d modul" % (vm, n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot")
    ap.add_argument("--modules")
    ap.add_argument("--vendor-boot")
    args = ap.parse_args()
    if not (args.boot or args.modules or args.vendor_boot):
        ap.error("pilih minimal satu: --boot / --modules / --vendor-boot")

    if args.boot:
        print("kernel     : %s" % kernel_banner(args.boot))
    if args.modules:
        show("modul di %s" % args.modules, scan_dir(args.modules))
    if args.vendor_boot:
        show("modul di %s" % args.vendor_boot, scan_vendor_boot(args.vendor_boot))

    print()
    print("cocok kalau angka versi kernel == awalan vermagic modul, dan build")
    print("kernel-nya dari source/config yang sama (kalau beda build, simbol")
    print("CONFIG_MODVERSIONS bisa berbeda walau angkanya sama).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
