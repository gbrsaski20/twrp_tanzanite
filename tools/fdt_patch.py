"""In-place patcher for the MTK fuel-gauge node inside a vendor_boot DTB.

WHY
   The gauge's idea of "100%" is not a measurement, it is a configuration.
   mt6358_battery.ko reads these properties from device tree:

     g_FG_PSEUDO100              the real SOC at which the UI is allowed to say
                                 100 %. Anything below 100 is a deliberate
                                 over-report, used to hide battery aging.
     g_FG_PSEUDO100_100_300_cycle   same, applied between 100-300 cycles
     g_FG_PSEUDO100_300_800_cycle   same, applied between 300-800 cycles
     g_FG_PSEUDO100_ov_800_cycle    same, applied above 800 cycles
     g_FG_charge_PSEUDO100       same, while charging
     KEEP_100_PERCENT            1 = once the UI reaches 100 % it stays there
                                 until the voltage sags, i.e. a latch

   This device is at 1377 charge cycles (dmesg: "cycle count = 1377"), so it
   uses the _ov_800_cycle row, where the thresholds are 90-93. The UI therefore
   says 100 % on a battery that is really at ~91 %, and KEEP_100_PERCENT then
   holds it there. That is the "it says 100 % and never comes down" symptom.

   All these values are plain big-endian u32 arrays of identical length, so they
   can be rewritten in place without rebuilding the FDT.

usage
   python fdt_patch.py <vendor_boot.img> <out.img> [--pseudo100 100] [--keep100 0]
"""
import sys, os, struct
sys.path.insert(0, os.path.dirname(__file__))
from vbimg2 import parse_image, build_image

FDT_MAGIC = 0xD00DFEED
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9

TABLES = [
    "g_FG_PSEUDO100",
    "g_FG_PSEUDO100_100_300_cycle",
    "g_FG_PSEUDO100_300_800_cycle",
    "g_FG_PSEUDO100_ov_800_cycle",
    "g_FG_charge_PSEUDO100",
]


def walk(dtb, base):
    """Yield (path, prop_name, value_offset, value_len) with absolute offsets."""
    magic, totalsize, off_struct, off_strings = struct.unpack_from(">IIII", dtb, base)
    if magic != FDT_MAGIC:
        raise SystemExit("bad FDT magic at %d" % base)
    p = base + off_struct
    strings = base + off_strings
    path = []
    while True:
        tok = struct.unpack_from(">I", dtb, p)[0]
        p += 4
        if tok == BEGIN_NODE:
            end = dtb.index(b"\0", p)
            name = dtb[p:end].decode("utf-8", "replace")
            p = (end + 1 + 3) & ~3
            path.append(name)
        elif tok == END_NODE:
            if path:
                path.pop()
        elif tok == PROP:
            ln, nameoff = struct.unpack_from(">II", dtb, p)
            p += 8
            vstart = p
            p = (p + ln + 3) & ~3
            end = dtb.index(b"\0", strings + nameoff)
            nm = dtb[strings + nameoff:end].decode("utf-8", "replace")
            yield "/".join(x for x in path if x), nm, vstart, ln
        elif tok == NOP:
            continue
        elif tok == END:
            return
        else:
            raise SystemExit("bad FDT token 0x%x" % tok)


def patch_gauge(dtb, node_sub="mtk_gauge", pseudo100=100, keep100=0):
    """Rewrite the gauge tables in place. Returns list of human-readable changes."""
    blob = dtb.find(struct.pack(">I", FDT_MAGIC))
    if blob < 0:
        raise SystemExit("no FDT blob found in dtb section")
    changes = []
    for path, nm, off, ln in list(walk(dtb, blob)):
        if node_sub.lower() not in path.lower():
            continue
        if nm in TABLES:
            if ln % 4:
                changes.append("SKIP %s (len %d not u32 aligned)" % (nm, ln))
                continue
            n = ln // 4
            new = struct.pack(">%dI" % n, *([pseudo100] * n))
            # `off` is already absolute inside `dtb` because walk() starts from
            # base + off_struct, so do NOT add the blob offset again.
            old = bytes(dtb[off:off + ln])
            dtb[off:off + ln] = new
            oldvals = list(struct.unpack(">%dI" % n, old))
            changes.append("%-30s %s -> %s" % (nm, oldvals[:4], [pseudo100] * min(4, n)))
        elif nm == "KEEP_100_PERCENT" and ln == 4:
            old = struct.unpack_from(">I", dtb, off)[0]
            struct.pack_into(">I", dtb, off, keep100)
            changes.append("%-30s %d -> %d" % (nm, old, keep100))
    return changes


def main():
    src, dst = sys.argv[1], sys.argv[2]
    pseudo100 = 100
    keep100 = 0
    for i, a in enumerate(sys.argv):
        if a == "--pseudo100":
            pseudo100 = int(sys.argv[i + 1])
        if a == "--keep100":
            keep100 = int(sys.argv[i + 1])

    info = parse_image(src)
    dtb = bytearray(info["dtb"])
    changes = patch_gauge(dtb, "mtk_gauge", pseudo100, keep100)
    if not changes:
        raise SystemExit("nothing patched - mtk_gauge node or its tables not found")

    print("patched gauge node in", os.path.basename(src))
    for c in changes:
        print("  ", c)

    info["dtb"] = bytes(dtb)
    written = build_image(info, info["frags"], dst)
    orig = os.path.getsize(src)
    if written < orig:
        with open(dst, "ab") as f:
            f.write(b"\0" * (orig - written))
        written = os.path.getsize(dst)
    print("written:", dst, written)


if __name__ == "__main__":
    main()
