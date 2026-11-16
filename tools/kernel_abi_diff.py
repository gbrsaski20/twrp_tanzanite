#!/usr/bin/env python3
"""kernel_abi_diff.py - apakah kernel ini masih "KMI-compliant"?

Modul vendor (lib/modules di vendor_boot) di-build terhadap KMI kernel stok.
Kernel GKI tetap bisa menolak modul itu kalau build-nya mengubah ABI: LTO
thin->full, CFI diakali, beda versi clang (genksyms), atau daftar simbol
ekspor (TRIM_UNUSED_KSYMS / whitelist) berbeda. Alat ini membandingkan config
yang tertanam di dua kernel (IKCONFIG) dan menyorot opsi yang menentukan.

Pemakaian:
    python3 tools/kernel_abi_diff.py --a boot_stok.img --b kernel.zip
    python3 tools/kernel_abi_diff.py --a boot_a.img --b boot_b.img
"""

import argparse
import gzip
import os
import re
import struct
import sys
import zipfile

ABI_KEYS = (
    "MODVERSIONS", "TRIM_UNUSED_KSYMS", "UNUSED_KSYMS_WHITELIST",
    "CFI", "LTO", "RANDSTRUCT", "MODULE_SIG", "MODULE_FORCE",
    "STACKPROTECTOR", "INIT_ON_ALLOC", "INIT_ON_FREE", "SHADOW_CALL",
    "RETPOLINE", "MODULE_UNLOAD", "CLANG_VERSION", "GCC_VERSION",
    "LOCALVERSION", "KSU",
)

# Beda di opsi ini mengubah layout struct / hash tipe -> CRC modul berubah.
FATAL = ("MODVERSIONS", "STACKPROTECTOR_PER_TASK", "RANDSTRUCT",
         "MODULE_SIG_FORCE", "KSU")

# Bisa ikut memutus modul, tapi tidak selalu: perlu dibuktikan dari dmesg.
WARN = ("LTO_CLANG_FULL", "CFI_FORCE_SKIP_CHECK", "CLANG_VERSION", "GCC_VERSION")

# Beda di opsi ini TIDAK mengubah CRC: string versi, path whitelist, dan
# TRIM_UNUSED_KSYMS (hanya memangkas simbol yang tidak dipakai siapa pun,
# CRC simbol yang tersisa tetap sama).
INFO = ("LOCALVERSION", "UNUSED_KSYMS_WHITELIST", "TRIM_UNUSED_KSYMS",
        "INIT_ON_ALLOC", "MODULE_UNLOAD")

PAT = re.compile(r"CONFIG_(%s)[A-Z0-9_]*\b.*" % "|".join(ABI_KEYS))


def load_kernel(path):
    """Kembalikan byte kernel (Image) dari boot.img atau zip AnyKernel3."""
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.startswith("Image") or name == "kernel":
                    return gzip.decompress(z.read(name)) if name.endswith(".gz") \
                        else z.read(name)
        raise SystemExit("tidak ada Image/kernel di zip %s" % path)
    d = open(path, "rb").read()
    if d[:8] != b"ANDROID!":
        return d  # sudah Image mentah
    ksize, = struct.unpack_from("<I", d, 8)
    k = d[4096:4096 + ksize]
    if k[:2] == b"\x1f\x8b":
        k = gzip.decompress(k)
    return k


def embedded_config(kimg):
    i = kimg.find(b"IKCFG_ST")
    if i < 0:
        raise SystemExit("kernel tidak membawa config (CONFIG_IKCONFIG tidak aktif)")
    j = kimg.find(b"IKCFG_ED", i)
    blob = kimg[i + 8:j]
    s = blob.find(b"\x1f\x8b\x08")
    return gzip.decompress(blob[s:]).decode("utf-8", "replace")


def banner(kimg):
    m = re.search(rb"Linux version ([0-9][^\x00\n]{0,120})", kimg)
    return m.group(1).decode("utf-8", "replace") if m else "?"


def pick(config):
    out = {}
    for line in config.splitlines():
        line = line.strip()
        if not PAT.match(line):
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
        elif line.endswith(" is not set"):
            out[line[2:].split(" is not set")[0]] = "n"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="kernel stok (boot.img / Image / zip)")
    ap.add_argument("--b", required=True, help="kernel pembanding")
    args = ap.parse_args()

    ka, kb = load_kernel(args.a), load_kernel(args.b)
    print("A: %s" % banner(ka))
    print("B: %s" % banner(kb))

    A, B = pick(embedded_config(ka)), pick(embedded_config(kb))
    rows = [(k, A.get(k, "-"), B.get(k, "-")) for k in sorted(set(A) | set(B))
            if A.get(k, "-") != B.get(k, "-")]

    print("\n%-42s %-22s %s" % ("OPSI", "A (stok)", "B"))
    for k, a, b in rows:
        print("%-42s %-22s %s" % (k, a[:22], b[:40]))

    print()
    if not rows:
        print("ABI: tidak ada opsi ABI yang beda -> modul stok seharusnya diterima.")
        return 0

    fatal = [k for k, _, _ in rows if any(x in k for x in FATAL)]
    warn = [k for k, _, _ in rows if k not in fatal and any(x in k for x in WARN)]
    info = [k for k, _, _ in rows if k not in fatal and k not in warn
            and any(x in k for x in INFO)]
    other = [k for k, _, _ in rows if k not in fatal and k not in warn and k not in info]

    if fatal:
        print("ABI: TIDAK KMI-compliant. %d opsi yang mengubah CRC/layout:" % len(fatal))
        for k in fatal:
            print("  - %s" % k)
        print("\nKesimpulan: modul vendor (lib/modules di vendor_boot) akan DITOLAK")
        print("kernel ini. Minta pembuat kernel menyamakan opsi di atas dengan kernel")
        print("stok, atau minta folder lib/modules hasil build-nya.")
    elif warn:
        print("ABI: belum pasti. Tidak ada opsi layout yang beda, tapi ada:")
        for k in warn:
            print("  - %s" % k)
        print("\nCoba flash; kalau recovery mati, ambil /tmp/pstore.log (pstore-dump)")
        print("untuk melihat simbol mana yang ditolak.")
    else:
        print("ABI: aman. Tidak ada opsi yang mengubah CRC/layout, jadi modul")
        print("stok tetap diterima walau versi kernel berbeda.")

    if info:
        print("Beda yang aman (string/path/daftar ekspor): %s" % ", ".join(info))
    if other:
        print("Beda lain (tidak menyangkut modul): %s" % ", ".join(other[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
