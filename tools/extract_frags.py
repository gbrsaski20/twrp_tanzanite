import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from vbimg import parse

# usage: extract_frags.py <vendor_boot.img>   -> writes work/fragN_<name>.bin
if len(sys.argv) < 2:
    sys.exit("usage: extract_frags.py <vendor_boot.img>")

IMG = sys.argv[1]
info, d = parse(IMG)
base = info["vendor_ramdisk_offset"]
os.makedirs("work", exist_ok=True)
for fr in info["fragments"]:
    s = base + fr["offset"]
    e = s + fr["size"]
    name = fr["name"] or "platform"
    out = "work/frag%d_%s.bin" % (fr["index"], name)
    with open(out, "wb") as f:
        f.write(d[s:e])
    head = d[s:s+8]
    print(out, fr["size"], head.hex())
