import struct, sys, os, lz4.block

def lz4_legacy_decompress(raw):
    MAGIC = 0x184C2102
    out = bytearray()
    off = 0
    if struct.unpack_from("<I", raw, 0)[0] != MAGIC:
        raise SystemExit("not legacy lz4: %s" % raw[:4].hex())
    off = 4
    while off + 4 <= len(raw):
        bsize = struct.unpack_from("<I", raw, off)[0]
        off += 4
        if bsize == 0 or bsize > 8 * 1024 * 1024:
            break
        blk = raw[off:off + bsize]
        off += bsize
        out += lz4.block.decompress(blk, uncompressed_size=8 * 1024 * 1024)
    return bytes(out)

def cpio_list(data):
    entries = []
    off = 0
    while off + 110 <= len(data):
        if data[off:off + 6] not in (b"070701", b"070702"):
            break
        hdr = data[off:off + 110]
        def f(i):
            return int(hdr[6 + i * 8:6 + (i + 1) * 8], 16)
        mode = f(1)
        filesize = f(6)
        namesize = f(11)
        name = data[off + 110:off + 110 + namesize - 1].decode("utf-8", "replace")
        entries.append((name, mode, filesize, off))
        off = off + 110 + namesize
        off = (off + 3) & ~3
        off += filesize
        off = (off + 3) & ~3
        if name == "TRAILER!!!":
            break
    return entries

if __name__ == "__main__":
    src = sys.argv[1]
    dst = sys.argv[2]
    raw = open(src, "rb").read()
    data = lz4_legacy_decompress(raw)
    open(dst, "wb").write(data)
    print("decompressed", len(raw), "->", len(data))
    ents = cpio_list(data)
    print("entries:", len(ents))
    KEY = ("battfix", "init.recovery", "init.rc", "batt", "ocv")
    for name, mode, size, off in ents:
        if any(k in name.lower() for k in KEY):
            print("%07o %9d %s" % (mode, size, name))
