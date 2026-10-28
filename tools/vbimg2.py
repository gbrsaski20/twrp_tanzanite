import struct, sys, os, lz4.block

MAGIC = b"VNDRBOOT"
LZ4_LEGACY_MAGIC = 0x184C2102
LZ4_BLOCK = 8 * 1024 * 1024


# --------------------------------------------------------------------- lz4 ---
def lz4_legacy_decompress(raw):
    if struct.unpack_from("<I", raw, 0)[0] != LZ4_LEGACY_MAGIC:
        raise SystemExit("not legacy lz4")
    out = bytearray()
    off = 4
    while off + 4 <= len(raw):
        bsize = struct.unpack_from("<I", raw, off)[0]
        off += 4
        if bsize == 0 or bsize > LZ4_BLOCK:
            break
        out += lz4.block.decompress(raw[off:off + bsize], uncompressed_size=LZ4_BLOCK)
        off += bsize
    return bytes(out)


def lz4_legacy_compress(data, level=9):
    # level 9 is a good trade: ~2.1 MB per 8 MB block instead of ~2.7 MB with
    # the fast default, and the resulting image stays far inside the 64 MB
    # vendor_boot partition.
    out = bytearray(struct.pack("<I", LZ4_LEGACY_MAGIC))
    for i in range(0, len(data), LZ4_BLOCK):
        chunk = data[i:i + LZ4_BLOCK]
        blk = lz4.block.compress(chunk, mode="high_compression",
                                 compression=level, store_size=False)
        out += struct.pack("<I", len(blk))
        out += blk
    return bytes(out)


# -------------------------------------------------------------------- cpio ---
def cpio_parse(data):
    entries = []
    off = 0
    while off + 110 <= len(data):
        if data[off:off + 6] not in (b"070701", b"070702"):
            break
        hdr = data[off:off + 110]
        vals = [int(hdr[6 + i * 8:6 + (i + 1) * 8], 16) for i in range(13)]
        namesize = vals[11]
        filesize = vals[6]
        name = data[off + 110:off + 110 + namesize - 1].decode("utf-8", "replace")
        body_off = (off + 110 + namesize + 3) & ~3
        body = data[body_off:body_off + filesize]
        entries.append({"hdr": hdr, "vals": vals, "name": name, "body": body})
        off = (body_off + filesize + 3) & ~3
        if name == "TRAILER!!!":
            break
    return entries


def cpio_build(entries):
    out = bytearray()
    for e in entries:
        body = e["body"]
        vals = list(e["vals"])
        vals[6] = len(body)
        name = e["name"]
        namesize = len(name.encode()) + 1
        vals[11] = namesize
        hdr = b"070701" + b"".join(b"%08X" % v for v in vals)
        out += hdr
        out += name.encode() + b"\0"
        while len(out) % 4:
            out += b"\0"
        out += body
        while len(out) % 4:
            out += b"\0"
    return bytes(out)


# ------------------------------------------------------------------- image ---
def parse_image(path):
    d = open(path, "rb").read()
    if d[:8] != MAGIC:
        raise SystemExit("not a vendor_boot image")
    hv, page = struct.unpack_from("<II", d, 8)
    vrsize, = struct.unpack_from("<I", d, 24)
    hsize, dtbsize = struct.unpack_from("<II", d, 2096)
    tsize, tnum, tesize, bcsize = struct.unpack_from("<IIII", d, 2112)

    def align(x):
        return (x + page - 1) // page * page

    vroff = align(hsize)
    dtboff = vroff + align(vrsize)
    taboff = dtboff + align(dtbsize)
    bcoff = taboff + align(tsize)

    frags = []
    for i in range(tnum):
        p = taboff + i * tesize
        rsize, roff, rtype = struct.unpack_from("<III", d, p)
        rname = d[p + 12:p + 44].split(b"\0")[0].decode("utf-8", "replace")
        frags.append({"size": rsize, "offset": roff, "type": rtype,
                      "name": rname,
                      "data": d[vroff + roff:vroff + roff + rsize]})

    return {
        "raw": d, "header": bytearray(d[:hsize]), "header_version": hv,
        "page": page, "hsize": hsize, "vrsize": vrsize,
        "dtb": d[dtboff:dtboff + dtbsize],
        "bootconfig": d[bcoff:bcoff + bcsize] if bcsize else b"",
        "frags": frags, "table_entry_size": tesize,
    }


def build_image(info, frags, out_path):
    page = info["page"]
    hsize = info["hsize"]

    def align(x):
        return (x + page - 1) // page * page

    vrd = b"".join(f["data"] for f in frags)
    vrsize = len(vrd)
    dtb = info["dtb"]
    bc = info["bootconfig"]
    tesize = info["table_entry_size"]

    table = bytearray()
    off = 0
    for f in frags:
        ent = bytearray(tesize)
        struct.pack_into("<III", ent, 0, len(f["data"]), off, f["type"])
        nm = f["name"].encode()[:31]
        ent[12:12 + len(nm)] = nm
        table += ent
        off += len(f["data"])

    hdr = bytearray(info["header"])
    struct.pack_into("<I", hdr, 24, vrsize)
    struct.pack_into("<I", hdr, 2100, len(dtb))
    struct.pack_into("<I", hdr, 2112, len(table))
    struct.pack_into("<I", hdr, 2116, len(frags))
    struct.pack_into("<I", hdr, 2120, tesize)
    struct.pack_into("<I", hdr, 2124, len(bc))
    hdr = hdr[:hsize]

    out = bytearray()
    out += hdr
    out += b"\0" * (align(hsize) - len(out))
    out += vrd
    out += b"\0" * (align(vrsize) - len(vrd))
    out += dtb
    out += b"\0" * (align(len(dtb)) - len(dtb))
    out += table
    out += b"\0" * (align(len(table)) - len(table))
    if bc:
        out += bc
        out += b"\0" * (align(len(bc)) - len(bc))

    with open(out_path, "wb") as f:
        f.write(bytes(out))
    return len(out)
