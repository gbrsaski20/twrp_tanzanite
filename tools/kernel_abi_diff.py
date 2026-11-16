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

# Tingkatan berdasarkan bukti di perangkat (tanzanite, A17):
#   fatal   : hampir pasti mengubah layout struct / CRC simbol
#   suspect : sering memutus modul, tapi tidak selalu -> harus dites
#   info    : terbukti / secara teori tidak mengubah CRC
FATAL_KEYS = ("MODVERSIONS", "RANDSTRUCT", "STACKPROTECTOR_PER_TASK",
              "MODULE_SIG_FORCE")
SUSPECT_KEYS = ("SUSFS", "KSU_SAMSUNG", "LTO_CLANG_FULL", "LTO_CLANG_THIN",
                "CFI_FORCE_SKIP_CHECK", "CLANG_VERSION", "GCC_VERSION")


def classify(key):
    k = key.replace("CONFIG_", "")
    if k in FATAL_KEYS:
        return "fatal"
    if any(x in k for x in SUSPECT_KEYS):
        return "suspect"
    # CONFIG_KSU saja (tanpa SUSFS/Samsung) terbukti aman: SuiKernel
    # KernelSU-Next 5.10.270 bisa boot ke OFox dengan modul stok.
    return "info"


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

    # Fitur yang sering diklaim di changelog: cek langsung di binary-nya.
    def feats(k):
        return "KSU:%s SUSFS:%s" % ("ya" if b"KernelSU" in k or b"kernelsu" in k else "tidak",
                                    "ya" if k.count(b"susfs") > 3 else "tidak")
    print("A fitur: %s" % feats(ka))
    print("B fitur: %s" % feats(kb))

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

    fatal = [k for k, _, _ in rows if classify(k) == "fatal"]
    suspect = [k for k, _, _ in rows if classify(k) == "suspect"]
    info = [k for k, _, _ in rows if classify(k) == "info"]

    if fatal:
        print("ABI: TIDAK KMI-compliant. %d opsi yang mengubah layout/CRC:" % len(fatal))
        for k in fatal:
            print("  - %s" % k)
        print("\nKesimpulan: modul vendor (lib/modules di vendor_boot) akan DITOLAK.")
        print("Minta pembuat kernel menyamakan opsi itu dengan kernel stok, atau")
        print("minta folder lib/modules hasil build-nya.")
    elif suspect:
        print("ABI: perlu dites. Tidak ada opsi layout yang beda, tapi ada:")
        for k in suspect:
            print("  - %s" % k)
        print("\nSUSFS/LTO full/CFI skip adalah tersangka utama kalau modul ditolak")
        print("(KSU saja terbukti aman: SuiKernel KernelSU-Next boot di tanzanite).")
        print("Kalau recovery mati: ambil /tmp/pstore.log (service pstore-dump).")
    else:
        print("ABI: aman. Tidak ada opsi yang mengubah CRC/layout, jadi modul")
        print("stok tetap diterima walau versi kernel berbeda.")

    if info:
        print("Beda yang aman (string/path/daftar ekspor/KSU saja): %s"
              % ", ".join(info))
    return 0


if __name__ == "__main__":
    sys.exit(main())
