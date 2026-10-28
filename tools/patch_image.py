import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vbimg2 import (parse_image, build_image, lz4_legacy_decompress,
                    lz4_legacy_compress, cpio_parse, cpio_build)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Minimal swap: replaces battfixd.sh and rebuilds, without pruning modules.
# patch_fast.py does the same plus the module pruning; use that for real builds.
#
# usage: patch_image.py <stock vendor_boot.img> <out.img> [battfixd.sh]
if len(sys.argv) < 3:
    sys.exit("usage: patch_image.py <stock vendor_boot.img> <out.img> [battfixd.sh]")

SRC = sys.argv[1]
DST = sys.argv[2]
NEW_BATTFIXD = (sys.argv[3] if len(sys.argv) > 3
                else os.path.join(REPO, "battfix", "battfixd.sh"))

TARGET = "system/bin/battfixd.sh"

info = parse_image(SRC)
print("image       :", SRC)
print("fragments   :", [(f["index"] if "index" in f else i, f["name"], f["size"])
                        for i, f in enumerate(info["frags"])])

# find the recovery fragment
idx = None
for i, f in enumerate(info["frags"]):
    if f["name"] == "recovery":
        idx = i
        break
if idx is None:
    idx = max(range(len(info["frags"])), key=lambda i: info["frags"][i]["size"])
print("patching    : fragment", idx, info["frags"][idx]["name"], info["frags"][idx]["size"])

raw = info["frags"][idx]["data"]
print("magic       :", raw[:4].hex())
cpio = lz4_legacy_decompress(raw)
print("cpio size   :", len(cpio))

entries = cpio_parse(cpio)
print("cpio entries:", len(entries))

new_body = open(NEW_BATTFIXD, "rb").read()
hit = 0
for e in entries:
    if e["name"] == TARGET:
        print("replace     :", e["name"], len(e["body"]), "->", len(new_body))
        e["body"] = new_body
        e["vals"][1] = e["vals"][1] | 0o111  # keep executable
        hit += 1
if not hit:
    raise SystemExit("target not found in ramdisk: " + TARGET)

new_cpio = cpio_build(entries)
print("new cpio    :", len(new_cpio))
new_raw = lz4_legacy_compress(new_cpio)
print("recompressed:", len(new_raw), "(was", len(raw), ")")

info["frags"][idx]["data"] = new_raw
written = build_image(info, info["frags"], DST)
print("written     :", DST, written, "bytes")
print("original    :", os.path.getsize(SRC), "bytes")

# pad to the original size so the file matches the partition exactly
orig = os.path.getsize(SRC)
if written < orig:
    with open(DST, "ab") as f:
        f.write(b"\0" * (orig - written))
    print("padded      :", os.path.getsize(DST), "bytes")
elif written > orig:
    print("WARNING: image is larger than the partition:", written, ">", orig)
