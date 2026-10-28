import struct, sys, gzip, bz2, lzma, re, os

def parse_boot(path):
    d = open(path, "rb").read()
    if d[:8] != b"ANDROID!":
        raise SystemExit("not an android boot image: %r" % d[:8])
    kernel_size, ramdisk_size, os_version = struct.unpack_from("<III", d, 8)
    header_size, = struct.unpack_from("<I", d, 20)
    header_version, = struct.unpack_from("<I", d, 40)
    if header_version >= 3:
        cmdline = d[44:44 + 1536].split(b"\0")[0].decode("utf-8", "replace")
        page = 4096
        off = page
    else:
        page, = struct.unpack_from("<I", d, 36)
        cmdline = d[64:64 + 512].split(b"\0")[0].decode("utf-8", "replace")
        off = page
    kernel = d[off:off + kernel_size]
    return {"path": path, "size": len(d), "header_version": header_version,
            "header_size": header_size, "kernel_size": kernel_size,
            "ramdisk_size": ramdisk_size, "cmdline": cmdline, "kernel": kernel}


def decompress(k):
    if k[:2] == b"\x1f\x8b":
        return "gzip", gzip.decompress(k)
    if k[:3] == b"BZh":
        return "bzip2", bz2.decompress(k)
    if k[:6] == b"\xfd7zXZ\x00":
        return "xz", lzma.decompress(k)
    if k[:4] == b"\x28\xb5\x2f\xfd":
        try:
            import zstandard
            return "zstd", zstandard.ZstdDecompressor().decompress(k)
        except Exception:
            return "zstd(unsupported)", b""
    if k[:4] == b"\x02\x21\x4c\x18":
        sys.path.insert(0, os.path.dirname(__file__))
        from vbimg2 import lz4_legacy_decompress
        return "lz4", lz4_legacy_decompress(k)
    return "raw", k


def main():
    for path in sys.argv[1:]:
        info = parse_boot(path)
        print("=" * 70)
        print("file       :", info["path"])
        print("size       :", info["size"])
        print("hdr ver    :", info["header_version"], " hdr size:", info["header_size"])
        print("kernel     :", info["kernel_size"], "bytes")
        print("ramdisk    :", info["ramdisk_size"], "bytes")
        print("cmdline    :", info["cmdline"][:150])
        kind, raw = decompress(info["kernel"])
        print("compression:", kind, "->", len(raw))
        m = re.search(rb"Linux version [0-9][^\x00\x20]{0,120}", raw)
        if m:
            print("KERNEL VER :", m.group().decode("latin1"))
        else:
            print("KERNEL VER : not found in plaintext")


if __name__ == "__main__":
    main()
