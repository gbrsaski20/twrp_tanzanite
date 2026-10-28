"""Compare battery/gauge related strings between two decompressed kernels.

vendor_boot carries NO kernel on this device, so any difference in how the
battery is reported has to come from boot.img's kernel. This dumps the
interesting strings from each kernel so they can be diffed.

usage: kerncmp.py <boot.img> [<boot.img> ...]
"""
import sys, os, re, hashlib
sys.path.insert(0, os.path.dirname(__file__))
from bootimg_info import parse_boot, decompress

KEYS = re.compile(
    rb"(gauge|fgauge|fuel|ocv|zcv|coulomb|rtc_ui_soc|ui_soc|info_con0|"
    rb"power_supply|battery|charger|Kernel mode|SW FG|hwocv|uisoc|"
    rb"capacity|mt6358|bms)", re.I)

cache = {}


def kernel_strings(path):
    if path in cache:
        return cache[path]
    info = parse_boot(path)
    kind, raw = decompress(info["kernel"])
    # printable ascii runs of length >= 6
    out = set()
    for m in re.finditer(rb"[\x20-\x7e]{6,200}", raw):
        s = m.group()
        if KEYS.search(s):
            out.add(s.decode("latin1"))
    cache[path] = (info, kind, len(raw), out, hashlib.md5(raw).hexdigest())
    return cache[path]


data = {}
for p in sys.argv[1:]:
    info, kind, n, strs, md5 = kernel_strings(p)
    print("=" * 78)
    print(os.path.basename(p))
    print("  kernel md5 :", md5)
    print("  decomp     :", kind, n, "bytes")
    print("  battery-ish strings:", len(strs))
    data[p] = strs

if len(data) == 2:
    a, b = list(data.values())
    pa, pb = list(data.keys())
    only_a = sorted(a - b)
    only_b = sorted(b - a)
    print("\n" + "=" * 78)
    print("ONLY IN", os.path.basename(pa), "(%d)" % len(only_a))
    for s in only_a:
        print("  -", s)
    print("\nONLY IN", os.path.basename(pb), "(%d)" % len(only_b))
    for s in only_b:
        print("  +", s)
