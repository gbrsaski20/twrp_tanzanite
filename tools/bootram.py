"""Unpack the RAMDISK of a plain Android boot image (ANDROID! magic).

boot.img ramdisks on MTK carry the generic first-stage init plus the offline
charger UI (system/bin/charger, res/images/charger/*.png). They are almost
always gzip'd cpio, unlike the LZ4-legacy frames used inside vendor_boot.

usage: bootram.py <boot.img> <outdir>
"""
import sys, os, gzip, bz2, lzma
sys.path.insert(0, os.path.dirname(__file__))
from bootimg_info import parse_boot
from vbimg2 import cpio_parse, lz4_legacy_decompress

IMG = sys.argv[1]
OUT = sys.argv[2]

info = parse_boot(IMG)
d = open(IMG, "rb").read()

# header v3/v4: header occupies one page, kernel follows immediately, then the
# ramdisk starts on the NEXT PAGE BOUNDARY (the kernel blob is zero padded).
off = 4096 + info["kernel_size"]
off = (off + 4095) // 4096 * 4096
ram = d[off: off + info["ramdisk_size"]]

print("ramdisk blob: %d bytes @ %d  magic=%s" % (len(ram), off, ram[:4].hex()))
if ram[:2] == b"\x1f\x8b":
    data = gzip.decompress(ram)
elif ram[:3] == b"BZh":
    data = bz2.decompress(ram)
elif ram[:6] == b"\xfd7zXZ\x00":
    data = lzma.decompress(ram)
elif ram[:4] == b"\x02\x21\x4c\x18":
    data = lz4_legacy_decompress(ram)
elif ram[:6] in (b"070701", b"070702"):
    data = ram
else:
    raise SystemExit("unknown ramdisk container: %r" % ram[:8])

ents = cpio_parse(data)
print("cpio entries:", len(ents))

base = os.path.join(OUT, "root")
os.makedirs(base, exist_ok=True)
n = 0
for e in ents:
    nm = e["name"]
    if nm in (".", "..", "TRAILER!!!"):
        continue
    p = os.path.join(base, nm.lstrip("/"))
    if e["vals"][1] & 0o170000 == 0o040000:
        os.makedirs(p, exist_ok=True)
    elif e["vals"][1] & 0o170000 == 0o120000:
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p + ".symlink", "w").write(e["body"].decode("latin1"))
        except OSError:
            pass
    else:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        try:
            open(p, "wb").write(e["body"])
            n += 1
        except OSError as ex:
            print("  skip", nm, ex)
print("files written:", n, "->", base)
