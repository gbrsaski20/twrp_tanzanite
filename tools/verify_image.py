import sys, os, hashlib
sys.path.insert(0, os.path.dirname(__file__))
from vbimg2 import (parse_image, lz4_legacy_decompress, cpio_parse)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# usage: verify_image.py <stock.img> <patched.img> [battfixd.sh]
#
# Prints a structural diff: the header should differ only in the vendor ramdisk
# size field, frag0 should be byte-identical, and exactly one cpio entry should
# have changed (system/bin/battfixd.sh).
if len(sys.argv) < 3:
    sys.exit("usage: verify_image.py <stock.img> <patched.img> [battfixd.sh]")

SRC = sys.argv[1]
DST = sys.argv[2]
NEW = (sys.argv[3] if len(sys.argv) > 3
       else os.path.join(REPO, "battfix", "battfixd.sh"))


def sha(b):
    return hashlib.sha256(b).hexdigest()[:16]


a = parse_image(SRC)
b = parse_image(DST)

print("size      :", os.path.getsize(SRC), "->", os.path.getsize(DST))
print("header eq :", a["header"] == b["header"] or "differs (expected: sizes changed)")
print("dtb eq    :", a["dtb"] == b["dtb"], sha(a["dtb"]), sha(b["dtb"]))
print("frag0 eq  :", a["frags"][0]["data"] == b["frags"][0]["data"])
print("frags     :", [(f["name"], f["type"], f["size"]) for f in b["frags"]])

cpio_a = cpio_parse(lz4_legacy_decompress(a["frags"][1]["data"]))
cpio_b = cpio_parse(lz4_legacy_decompress(b["frags"][1]["data"]))
print("entries   :", len(cpio_a), "->", len(cpio_b))

names_a = [e["name"] for e in cpio_a]
names_b = [e["name"] for e in cpio_b]
print("same names:", names_a == names_b)

new_content = open(NEW, "rb").read()
diffs = 0
for ea, eb in zip(cpio_a, cpio_b):
    if ea["body"] != eb["body"]:
        diffs += 1
        print("  changed :", ea["name"], len(ea["body"]), "->", len(eb["body"]))

target = [e for e in cpio_b if e["name"] == "system/bin/battfixd.sh"]
if target:
    ok = target[0]["body"] == new_content
    print("battfixd  :", "matches new file" if ok else "MISMATCH", len(target[0]["body"]))
    print("mode      :", oct(target[0]["vals"][1]))

print("total diffs:", diffs)
