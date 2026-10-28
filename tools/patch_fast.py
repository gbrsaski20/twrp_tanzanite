import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vbimg2 import (parse_image, build_image, lz4_legacy_decompress,
                    lz4_legacy_compress, cpio_parse, cpio_build)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# usage: patch_fast.py <stock vendor_boot.img> <out.img> [battfixd.sh]
#
# The stock image is whatever OrangeFox/TWRP build produced for this device;
# the output is that image with the new daemon dropped in and the debug
# modules pruned. Nothing else is touched, so the header and the first
# ramdisk fragment stay byte-identical.
if len(sys.argv) < 3:
    sys.exit(__doc__ or
             "usage: patch_fast.py <stock vendor_boot.img> <out.img> [battfixd.sh]")

SRC = sys.argv[1]
DST = sys.argv[2]
NEW_BATTFIXD = (sys.argv[3] if len(sys.argv) > 3
                else os.path.join(REPO, "battfix", "battfixd.sh"))

# Modules that cost boot time but do nothing useful in recovery.
#
# Measured on this device with /proc/bootprof: clk_disable_unused alone is
# 340 ms, and every entry here is also one more insmod in the boot path.
#
# ONLY modules with no dependents among the modules we keep. Checked against
# lib/modules/modules.dep: dropping mmprofile.ko, irq-dbg.ko, mtk-smi-dbg.ko,
# mtk-mmc-dbg.ko, clk-chk-mt6789.ko or clk-dbg-mt6789.ko would break
# mediatek-drm.ko (no display), mtk-mmc.ko (no storage) and others, because
# they are listed as dependencies there. Do not add them back.
DROP = {
    "clk-disable-unused.ko",              # 340 ms, only saves power
    "mtk-pm-domain-disable-unused.ko",    #  21 ms, same family
    "dbgtop-drm.ko",                      # display debug
    "iommu_test.ko",                      # test module
    "mt63xx-debug.ko",                    # pmic debug
    "ufs-mediatek-dbg.ko",                # ufs debug
    "load_track.ko",                      # mtk boot tracking
}

info = parse_image(SRC)
idx = next(i for i, f in enumerate(info["frags"]) if f["name"] == "recovery")
cpio = lz4_legacy_decompress(info["frags"][idx]["data"])
entries = cpio_parse(cpio)
print("entries:", len(entries))

new_battfixd = open(NEW_BATTFIXD, "rb").read()
replaced = []
dropped = []

for e in entries:
    if e["name"] == "system/bin/battfixd.sh":
        e["body"] = new_battfixd
        replaced.append(e["name"])
    elif e["name"] == "lib/modules/modules.load.recovery":
        lines = e["body"].decode("utf-8", "replace").splitlines()
        out = []
        seen = set()
        for ln in lines:
            name = ln.strip()
            if not name:
                continue
            if name in DROP:
                dropped.append(name)
                continue
            if name in seen:            # pd_dbg_info.ko was listed twice
                dropped.append(name + " (duplicate)")
                continue
            seen.add(name)
            out.append(name)
        e["body"] = ("\n".join(out) + "\n").encode()
        print("modules: %d -> %d" % (len(lines), len(out)))

print("replaced:", replaced)
print("dropped :", dropped)

new_cpio = cpio_build(entries)
info["frags"][idx]["data"] = lz4_legacy_compress(new_cpio)
written = build_image(info, info["frags"], DST)
print("written :", DST, written)

orig = os.path.getsize(SRC)
if written < orig:
    with open(DST, "ab") as f:
        f.write(b"\0" * (orig - written))
    print("padded  :", os.path.getsize(DST))
elif written > orig:
    print("WARNING: too big:", written, ">", orig)
