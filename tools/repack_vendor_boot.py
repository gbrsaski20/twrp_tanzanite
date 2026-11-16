#!/usr/bin/env python3
"""Repack vendor_boot TWRP tanzanite di atas basis vendor_boot Android 17 (Halcyon).

Yang dilakukan:

1. Fragmen *platform* (first_stage_ramdisk/fstab.mt6789) diganti dengan fstab
   dari vendor_boot A17, supaya flag kripto (/metadata keydirectory, FBE v2,
   inlinecrypt) sama persis dengan yang dipakai ROM.
2. Fragmen *recovery* (rootfs TWRP) dipertahankan, tetapi:
     - lib/modules/* diganti modul dari vendor_boot A17 (vermagic harus sama
       dengan kernel yang dipakai ROM A17),
     - file overlay (a17/root/...) disalin masuk,
     - init.recovery.mt6789.rc dari overlay dipakai kalau ada.
3. DTB dan bootconfig diambil dari basis A17.

Pemakaian:
    python tools/repack_vendor_boot.py \
        --base-a17 vendor_boot_a17.img \
        --twrp     vendor_boot_twrp_tanzanite.img \
        --overlay  a17/root \
        --fstab    a17/fstab.mt6789 \
        --init-append a17/init.append.rc \
        --out      vendor_boot_twrp_tanzanite_a17.img
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vbimg2  # noqa: E402

PART_SIZE = 67108864  # BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE


def decompress_fragment(data):
    if data[:4] == b"\x02\x21\x4c\x18":
        return vbimg2.lz4_legacy_decompress(data)
    return data


def make_entry(name, body, mode=0o100644, uid=0, gid=0, mtime=0):
    vals = [0, mode, uid, gid, 1, mtime, len(body), 0, 0, 0, 0,
            len(name.encode()) + 1, 0]
    return {"name": name, "body": body, "vals": vals}


def index(entries):
    return {e["name"]: e for e in entries}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-a17", required=True, help="vendor_boot A17 (Halcyon)")
    ap.add_argument("--twrp", "--recovery", dest="twrp", required=True,
                    help="image recovery yang sekarang (TWRP atau OrangeFox)")
    ap.add_argument("--overlay", required=True, help="folder overlay (a17/root)")
    ap.add_argument("--fstab", required=True, help="fstab.mt6789 dari A17")
    ap.add_argument("--init-append", default="",
                    help="fragmen init tambahan (a17/init.append.rc)")
    ap.add_argument("--modules-from", default="",
                    help="folder berisi .ko dari kernel lain (kernel custom). "
                         "Menggantikan seluruh lib/modules/*.ko di ramdisk.")
    ap.add_argument("--keep-extra-modules", action="store_true",
                    help="dengan --modules-from: modul lama yang tidak ada di "
                         "folder sumber tetap dipakai (mis. flashlight.ko)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    base = vbimg2.parse_image(args.base_a17)
    twrp = vbimg2.parse_image(args.twrp)

    print("base A17 : frags=%d dtb=%d" % (len(base["frags"]), len(base["dtb"])))
    print("twrp     : frags=%d dtb=%d" % (len(twrp["frags"]), len(twrp["dtb"])))

    # --- fragmen platform + recovery milik TWRP -----------------------------
    plat = rec = None
    for f in twrp["frags"]:
        if f["type"] == 2:
            rec = f
        else:
            plat = f
    if rec is None:
        sys.exit("fragmen recovery (type 2) tidak ditemukan di image TWRP")

    plat_entries = vbimg2.cpio_parse(decompress_fragment(plat["data"]))
    rec_entries = vbimg2.cpio_parse(decompress_fragment(rec["data"]))
    print("platform entries=%d  recovery entries=%d"
          % (len(plat_entries), len(rec_entries)))

    # --- 1. fstab A17 -----------------------------------------------------
    # Fstab first-stage bisa berada di fragmen platform maupun recovery,
    # tergantung tree perangkat. Ganti di mana pun ia ditemukan; kalau tidak
    # ada sama sekali, taruh di fragmen recovery (tempat TWRP membacanya).
    fstab = open(args.fstab, "rb").read()
    candidates = ("first_stage_ramdisk/fstab.mt6789",
                  "first_stage_ramdisk/system/etc/fstab.mt6789")
    hit = []
    for entries in (rec_entries, plat_entries):
        for e in entries:
            if e["name"] in candidates:
                e["body"] = fstab
                hit.append(e["name"])
    if not hit:
        rec_entries.insert(-1, make_entry(candidates[0], fstab, mode=0o100644))
        hit.append(candidates[0] + " (baru)")
    print("fstab A17  : %d byte -> %s" % (len(fstab), ", ".join(hit)))

    # --- 2. modul kernel dari basis A17 ------------------------------------
    a17_entries = vbimg2.cpio_parse(decompress_fragment(base["frags"][0]["data"]))
    a17_mods = [e for e in a17_entries if e["name"].startswith("lib/modules/")]
    if not a17_mods:
        sys.exit("basis A17 tidak memuat lib/modules/* - cek file vendor_boot")

    rec_idx = index(rec_entries)
    replaced = added = 0
    for m in a17_mods:
        if m["name"] in rec_idx:
            rec_idx[m["name"]]["body"] = m["body"]
            replaced += 1
        else:
            rec_entries.insert(-1, m)
            added += 1
    print("modul A17  : %d diganti, %d ditambah" % (replaced, added))

    # --- 2b. ganti seluruh modul dengan milik kernel lain -------------------
    # Modul vendor terikat ke kernel yang jalan (vermagic + versi simbol).
    # Kalau user memakai kernel custom, modul A17 tidak bisa dipakai; kasih
    # folder modul hasil build kernel itu lewat --modules-from.
    if args.modules_from:
        src = os.path.abspath(args.modules_from)
        if not os.path.exists(src):
            sys.exit("--modules-from tidak ada: %s" % src)
        tmpdir = None
        if os.path.isfile(src) and src.lower().endswith(".zip"):
            # zip AnyKernel3 / paket modul: ambil semua .ko di dalamnya
            import tempfile
            import zipfile
            tmpdir = tempfile.mkdtemp(prefix="kmods_")
            n = 0
            with zipfile.ZipFile(src) as z:
                for info in z.infolist():
                    if not info.filename.endswith(".ko"):
                        continue
                    rel = info.filename
                    for pre in ("modules/system/lib/modules/", "system/lib/modules/", "lib/modules/"):
                        if rel.startswith(pre):
                            rel = rel[len(pre):]
                            break
                    out = os.path.join(tmpdir, "lib", "modules", os.path.basename(rel))
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    with open(out, "wb") as w:
                        w.write(z.read(info))
                    n += 1
            if n == 0:
                sys.exit("zip %s tidak berisi .ko - kernel itu tidak menyertakan "
                         "modul, jadi tidak bisa dipakai untuk recovery.\n"
                         "Minta modulnya ke pembuat kernel (folder lib/modules "
                         "hasil build kernel)." % os.path.basename(src))
            print("modul zip  : %d .ko diambil dari %s" % (n, os.path.basename(src)))
            src = tmpdir
        if not os.path.isdir(src):
            sys.exit("--modules-from bukan folder/zip: %s" % src)
        new_mods = []
        for root, _, files in os.walk(src):
            for fn in files:
                if not fn.endswith(".ko"):
                    continue
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, src).replace("\\", "/")
                if not rel.startswith("lib/modules/"):
                    rel = "lib/modules/" + rel
                new_mods.append((rel, open(p, "rb").read()))
        if not new_mods:
            sys.exit("tidak ada .ko di %s" % src)

        drop = [n for n in rec_idx if n.startswith("lib/modules/") and n.endswith(".ko")]
        if args.keep_extra_modules:
            have = {n for n, _ in new_mods}
            drop = [n for n in drop if n in have]
        for n in drop:
            rec_entries = [e for e in rec_entries if e["name"] != n]
        rec_idx = index(rec_entries)
        for name, body in new_mods:
            if name in rec_idx:
                rec_idx[name]["body"] = body
            else:
                rec_entries.insert(-1, make_entry(name, body, mode=0o100644))
        print("modul baru : %d .ko dari %s (%d modul lama dibuang)"
              % (len(new_mods), args.modules_from, len(drop)))
        load = rec_idx.get("lib/modules/modules.load.recovery")
        if load is not None:
            have = {n.rsplit("/", 1)[-1] for n, _ in new_mods}
            need = [l.strip() for l in load["body"].decode().splitlines()
                    if l.strip() and not l.strip().startswith("#")]
            missing = [n for n in need if n not in have]
            if missing:
                print("  PERINGATAN modules.load.recovery menyebut %d modul yang "
                      "tidak ada di set baru, contoh: %s"
                      % (len(missing), ", ".join(missing[:5])))

    # vermagic modul yang akhirnya dipakai (buat dicocokkan dengan `uname -r`)
    vm = {}
    for e in rec_entries:
        if e["name"].startswith("lib/modules/") and e["name"].endswith(".ko"):
            i = e["body"].find(b"vermagic=")
            if i >= 0:
                s = e["body"][i + 9:e["body"].find(b"\0", i)].decode("utf-8", "replace")
                vm[s] = vm.get(s, 0) + 1
    if vm:
        print("vermagic   : %d variasi" % len(vm))
        for s, n in sorted(vm.items(), key=lambda kv: -kv[1])[:4]:
            print("             %-64s %3d modul" % (s, n))
        print("             harus cocok dengan kernel di boot.img (`uname -r`)")

    # modul yang ada di TWRP tapi tidak ada di A17 (mis. mtk-afe-external.ko)
    keep = [n for n in rec_idx if n.startswith("lib/modules/")
            and n not in {m["name"] for m in a17_mods}]
    for n in keep:
        print("  catatan: modul hanya-di-TWRP tetap dipakai: %s" % n)

    # --- 3. overlay -------------------------------------------------------
    rec_idx = index(rec_entries)
    overlay_files = 0
    for root, _, files in os.walk(args.overlay):
        for fn in files:
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, args.overlay).replace("\\", "/")
            body = open(p, "rb").read()
            mode = 0o100755 if (fn.endswith(".sh") or "/bin/" in rel) else 0o100644
            if rel in rec_idx:
                rec_idx[rel]["body"] = body
                rec_idx[rel]["vals"][1] = mode
            else:
                rec_entries.insert(-1, make_entry(rel, body, mode=mode))
            overlay_files += 1
            print("  overlay: %s (%d byte)" % (rel, len(body)))
    print("overlay    : %d file" % overlay_files)

    # --- 3b. fragmen init (append, BUKAN timpa) ---------------------------
    # Kalau image masukan sudah pernah dipatch, blok lama DIGANTI dengan isi
    # a17/init.append.rc yang sekarang. Tanpa ini, merakit ulang di atas image
    # yang sudah dipatch akan memakai fragmen lama (perbaikan tidak pernah
    # masuk ke image).
    rc_name = "init.recovery.mt6789.rc"
    marker = b"# --- A17 crypto overlay (a17/init.append.rc) ---"
    if args.init_append and os.path.exists(args.init_append):
        frag = open(args.init_append, "rb").read()
        e = rec_idx.get(rc_name)
        if e is None:
            print("init rc    : tidak ada di ramdisk, fragmen dilewati")
        else:
            body = e["body"]
            pos = body.find(marker)
            if pos >= 0:
                body = body[:pos].rstrip(b"\n") + b"\n"
                state = "fragmen A17 lama diganti"
            else:
                body = body.rstrip(b"\n") + b"\n"
                state = "fragmen A17 ditambahkan"
            # Nama service di rc tree salah: dideklarasikan `gatekeeper-1-0`
            # tetapi di-start sebagai `vendor.gatekeeper-1-0` (nama gaya AOSP),
            # jadi gatekeeper tidak pernah jalan -> "Failed to decrypt user 0".
            fixes = 0
            for bad, good in ((b"start vendor.gatekeeper-1-0", b"start gatekeeper-1-0"),
                              (b"stop vendor.gatekeeper-1-0", b"stop gatekeeper-1-0")):
                fixes += body.count(bad)
                body = body.replace(bad, good)
            if fixes:
                print("init rc    : %d nama service gatekeeper diperbaiki" % fixes)
            e["body"] = body + b"\n" + marker + b"\n" + frag
            print("init rc    : %s (%d byte)" % (state, len(frag)))

    # --- 4. rakit ulang ---------------------------------------------------
    plat_cpio = vbimg2.cpio_build(plat_entries)
    rec_cpio = vbimg2.cpio_build(rec_entries)

    frags = [
        {"name": "", "type": 1,
         "data": vbimg2.lz4_legacy_compress(plat_cpio, 9)},
        {"name": "recovery", "type": 2,
         "data": vbimg2.lz4_legacy_compress(rec_cpio, 9)},
    ]

    info = dict(twrp)
    info["dtb"] = base["dtb"]
    info["bootconfig"] = base["bootconfig"]

    size = vbimg2.build_image(info, frags, args.out)
    print("\nhasil      : %s" % args.out)
    print("ukuran     : %d byte (%.2f MiB), partisi %d byte"
          % (size, size / 1048576.0, PART_SIZE))
    if size > PART_SIZE:
        sys.exit("GAGAL: image melebihi ukuran partisi vendor_boot")
    print("sisa       : %d byte" % (PART_SIZE - size))

    # --- 5. verifikasi baca ulang ----------------------------------------
    chk = vbimg2.parse_image(args.out)
    ok = True
    for f in chk["frags"]:
        ents = vbimg2.cpio_parse(decompress_fragment(f["data"]))
        names = {e["name"] for e in ents}
        print("verifikasi : frag type=%d entries=%d trailer=%s"
              % (f["type"], len(ents), "TRAILER!!!" in names))
        if "TRAILER!!!" not in names:
            ok = False
    if chk["dtb"] != base["dtb"]:
        print("verifikasi : DTB beda dari basis A17!")
        ok = False
    print("verifikasi : %s" % ("OK" if ok else "GAGAL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
