"""Minimal FDT parser: dump a node's properties from a vendor_boot DTB.

The MTK fuel gauge is configured entirely through device-tree properties in
`fg_cust_data` (see mt6358_battery.ko: uisoc_update_type, swocv_oldocv_diff_emb,
CAR_TUNE_VALUE, ...). Those live in the DTB inside vendor_boot, so two recoveries
can behave completely differently on battery even with identical kernels and
identical modules.

usage: fdt_dump.py <vendor_boot.img> [node-substring]
"""
import sys, os, struct
sys.path.insert(0, os.path.dirname(__file__))
from vbimg2 import parse_image

MAGIC = 0xD00DFEED


def parse_fdt(b, base=0):
    magic, totalsize, off_struct, off_strings = struct.unpack_from(">IIII", b, base)
    if magic != MAGIC:
        raise SystemExit("bad fdt magic %08x at %d" % (magic, base))
    struct_blk = base + off_struct
    strings_blk = base + off_strings
    nodes = []          # (path, [(name, value_bytes)])
    path = []
    cur = None
    p = struct_blk
    while True:
        tok = struct.unpack_from(">I", b, p)[0]
        p += 4
        if tok == 1:                                    # BEGIN_NODE
            end = b.index(b"\0", p)
            name = b[p:end].decode("utf-8", "replace")
            p = (end + 1 + 3) & ~3
            path.append(name)
            cur = ("/".join(x for x in path if x), [])
            nodes.append(cur)
        elif tok == 2:                                  # END_NODE
            if path:
                path.pop()
            cur = None
        elif tok == 3:                                  # PROP
            ln, nameoff = struct.unpack_from(">II", b, p)
            p += 8
            val = b[p:p + ln]
            p = (p + ln + 3) & ~3
            if cur is not None:
                nm = b[strings_blk + nameoff:b.index(b"\0", strings_blk + nameoff)].decode("utf-8", "replace")
                cur[1].append((nm, val))
        elif tok == 4:                                  # NOP
            continue
        elif tok == 9:                                  # END
            break
        else:
            raise SystemExit("bad fdt token 0x%x at %d" % (tok, p - 4))
    return nodes


def show(val):
    if len(val) == 0:
        return "<empty>"
    if len(val) == 4:
        return "u32 %d (0x%x)" % (struct.unpack(">I", val)[0], struct.unpack(">I", val)[0])
    if len(val) % 4 == 0 and len(val) <= 64:
        return "u32[%d] %s" % (len(val) // 4, list(struct.unpack(">%dI" % (len(val) // 4), val)))
    try:
        s = val.rstrip(b"\0").decode("utf-8")
        if all(32 <= ord(c) < 127 or c in "\t\n" for c in s):
            return '"%s"' % s
    except Exception:
        pass
    return "%d bytes: %s" % (len(val), val[:24].hex())


def node_props(img, node_sub):
    """Return {prop_name: value_bytes} for the first node whose path contains
    node_sub. Importable helper so other tools can diff nodes."""
    info = parse_image(img)
    dtb = info["dtb"]
    off = dtb.find(struct.pack(">I", MAGIC))
    if off < 0:
        return {}
    for path, props in parse_fdt(dtb, off):
        if node_sub.lower() in path.lower():
            return dict(props)
    return {}


def main():
    img = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else "fg_cust"
    info = parse_image(img)
    dtb = info["dtb"]

    # a vendor_boot DTB can hold several concatenated FDTs
    offs, i = [], 0
    while True:
        i = dtb.find(struct.pack(">I", MAGIC), i)
        if i < 0:
            break
        offs.append(i)
        i += 4
    print("file :", os.path.basename(img))
    print("dtb  : %d bytes, %d FDT blob(s) at %s" % (len(dtb), len(offs), offs))

    for n, off in enumerate(offs):
        nodes = parse_fdt(dtb, off)
        hits = [nd for nd in nodes if want.lower() in nd[0].lower()]
        print("\n--- FDT #%d : %d nodes, %d match '%s' ---" % (n, len(nodes), len(hits), want))
        for path, props in hits:
            print("  /%s" % path)
            for nm, val in props:
                print("     %-32s = %s" % (nm, show(val)))


if __name__ == "__main__":
    main()
