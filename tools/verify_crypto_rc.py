#!/usr/bin/env python3
"""verify_crypto_rc.py - cek wiring init.rc kripto recovery sebelum build.

Yang diperiksa:

1. Setiap `start <nama>` / `stop <nama>` harus menunjuk service yang benar-benar
   dideklarasikan (di rc utama, rc yang di-import, atau /system/etc/init/*.rc).
   Ini menangkap bug kelas "start vendor.gatekeeper-1-0 padahal service-nya
   bernama gatekeeper-1-0" - gatekeeper tidak pernah jalan, dan hasilnya
   "Failed to decrypt user 0" walau keymaster sehat.
2. Binary tiap service harus ada di ramdisk.
3. Fragmen A17 harus sudah ada di rc (penanda "A17 crypto overlay").
4. File rc tidak boleh CRLF dan tidak boleh pakai tab (init gagal parse).

Pemakaian:
    python3 tools/verify_crypto_rc.py --rc device/xiaomi/tanzanite/recovery/root/init.recovery.mt6789.rc \
                                     --root device/xiaomi/tanzanite/recovery/root
"""

import argparse
import glob
import os
import sys

MARKER = "A17 crypto overlay"

# Service milik init sendiri / rc lain di luar tree perangkat.
BUILTIN = {
    "servicemanager", "hwservicemanager", "vndservicemanager", "adbd", "logd",
    "ueventd", "vold", "netd", "apexd", "keystore2", "tombstoned",
    "debuggerd", "debuggerd64", "healthd", "bootanim", "surfaceflinger",
    "zygote", "installd", "sdcard", "mtp", "statsd", "traced",
    "traced_probes", "console", "vendor.apexd", "vendor.keymaster-4.1",
}


# Service HAL yang rc-nya baru ada SETELAH build (disalin dari AOSP ke
# /system/etc/init di ramdisk), jadi tidak terlihat saat memeriksa device tree.
# Catatan: gatekeeper sengaja TIDAK masuk sini - nama service-nya dideklarasikan
# sendiri di rc tree, dan salah nama di situ justru bug yang mau ditangkap.
HAL_OK_PREFIX = ("boot-hal", "health-hal", "keymaster", "keymint",
                 "vendor.apexd", "vendor.keymaster")


def hal_service(name):
    return name.startswith(HAL_OK_PREFIX) or "-hal-" in name


def looks_like_ramdisk(root):
    """True kalau root sudah berupa ramdisk hasil build, bukan device tree."""
    if not root or not os.path.isdir(root):
        return False
    return (os.path.exists(os.path.join(root, "init"))
            or os.path.isdir(os.path.join(root, "twres")))


def read_rc(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    return raw, raw.decode("utf-8", "replace")


def parse(text):
    """Kembalikan (services, triggers) dari isi rc."""
    services = {}     # nama -> path
    starts = []       # (nama, baris)
    for no, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split()
        if parts[0] == "service" and len(parts) >= 3:
            services[parts[1]] = parts[2]
        elif parts[0] in ("start", "stop") and len(parts) >= 2:
            starts.append((parts[1], no))
    return services, starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rc", required=True, help="init.recovery.<hw>.rc hasil patch")
    ap.add_argument("--root", default="", help="root ramdisk recovery (untuk cek binary)")
    args = ap.parse_args()

    problems = []
    raw, text = read_rc(args.rc)

    if b"\r\n" in raw:
        problems.append("%s: ada CRLF - init gagal parse (lihat .gitattributes)" % args.rc)
    if "\t" in text:
        problems.append("%s: ada karakter TAB - init butuh spasi" % args.rc)
    if MARKER not in text:
        problems.append("%s: fragmen '%s' tidak ada - patch A17 belum jalan"
                        % (args.rc, MARKER))

    services, starts = parse(text)

    # service dari rc lain yang ikut dibaca init
    extra = []
    base = os.path.dirname(os.path.abspath(args.rc))
    for pat in ("init*.rc",):
        extra += glob.glob(os.path.join(base, pat))
    if args.root:
        extra += glob.glob(os.path.join(args.root, "system/etc/init/*.rc"))
        extra += glob.glob(os.path.join(args.root, "system/etc/init/hw/*.rc"))
    for p in extra:
        if os.path.abspath(p) == os.path.abspath(args.rc):
            continue
        _, t = read_rc(p)
        sv, _ = parse(t)
        for k, v in sv.items():
            services.setdefault(k, v)

    # 1. start/stop harus ada targetnya
    ramdisk = looks_like_ramdisk(args.root)
    for name, no in starts:
        if name in services or name in BUILTIN:
            continue
        # Di device tree, rc HAL AOSP (system/etc/init/*.rc) belum ada.
        if not ramdisk and hal_service(name):
            continue
        problems.append("%s:%d: start/stop '%s' - service itu tidak dideklarasikan"
                        % (args.rc, no, name))

    # 2. binary service harus ada - hanya bisa diperiksa di ramdisk hasil build,
    #    karena /system/bin/sh dll disalin build, bukan bagian device tree.
    skip_bin = {"charger"}  # symlink di root ramdisk, bukan bagian patch ini
    if ramdisk:
        for name, path in sorted(services.items()):
            if not path.startswith("/") or name in skip_bin:
                continue
            cand = os.path.join(args.root, path.lstrip("/"))
            if os.path.exists(cand) or os.path.exists(cand + ".symlink"):
                continue
            problems.append("service %s: binary %s tidak ada di ramdisk"
                            % (name, path))

    # 3. cek khusus: gatekeeper harus dipakai dengan nama yang benar
    gk = [n for n in services if n.endswith("gatekeeper-1-0")]
    if gk:
        started = {n for n, _ in starts}
        if not (set(gk) & started):
            problems.append("gatekeeper (%s) tidak pernah di-start - "
                            "'Failed to decrypt user 0' kalau /data pakai PIN"
                            % ", ".join(sorted(gk)))

    if problems:
        print("VERIFIKASI GAGAL:")
        for p in problems:
            print("  - %s" % p)
        return 1

    print("VERIFIKASI OK: %d service, %d start/stop, fragmen A17 ada (%s)"
          % (len(services), len(starts),
             "ramdisk, cek ketat" if ramdisk else "device tree, cek binary dilewati"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
