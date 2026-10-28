import struct, sys, os, json

MAGIC = b"VNDRBOOT"

def parse(path):
    d = open(path, "rb").read()
    info = {"path": path, "file_size": len(d)}
    if d[:8] != MAGIC:
        info["error"] = "not a vendor_boot image (magic=%r)" % d[:8]
        return info, d
    (header_version, page_size, kernel_addr, ramdisk_addr,
     vendor_ramdisk_size) = struct.unpack_from("<IIIII", d, 8)
    cmdline = d[28:28 + 2048].split(b"\0")[0].decode("utf-8", "replace")
    tags_addr, = struct.unpack_from("<I", d, 2076)
    name = d[2080:2096].split(b"\0")[0].decode("utf-8", "replace")
    header_size, dtb_size = struct.unpack_from("<II", d, 2096)
    dtb_addr, = struct.unpack_from("<Q", d, 2104)

    info.update(dict(header_version=header_version, page_size=page_size,
                     kernel_addr=hex(kernel_addr), ramdisk_addr=hex(ramdisk_addr),
                     vendor_ramdisk_size=vendor_ramdisk_size, cmdline=cmdline,
                     name=name, header_size=header_size, dtb_size=dtb_size,
                     dtb_addr=hex(dtb_addr)))

    table_size = table_num = table_esize = bootconfig_size = 0
    if header_version >= 4:
        table_size, table_num, table_esize, bootconfig_size = struct.unpack_from("<IIII", d, 2112)
        info.update(vendor_ramdisk_table_size=table_size,
                    vendor_ramdisk_table_entry_num=table_num,
                    vendor_ramdisk_table_entry_size=table_esize,
                    bootconfig_size=bootconfig_size)

    def align(x):
        return (x + page_size - 1) // page_size * page_size

    off = align(header_size)
    info["vendor_ramdisk_offset"] = off
    off += align(vendor_ramdisk_size)
    info["dtb_offset"] = off
    off += align(dtb_size)
    info["table_offset"] = off
    off += align(table_size)
    info["bootconfig_offset"] = off
    off += align(bootconfig_size)
    info["total_consumed"] = off

    entries = []
    if header_version >= 4 and table_num:
        base = info["table_offset"]
        for i in range(table_num):
            p = base + i * table_esize
            rsize, roff, rtype = struct.unpack_from("<III", d, p)
            rname = d[p + 12:p + 44].split(b"\0")[0].decode("utf-8", "replace")
            entries.append({"index": i, "size": rsize, "offset": roff,
                            "type": rtype, "name": rname})
    info["fragments"] = entries
    return info, d

if __name__ == "__main__":
    for path in sys.argv[1:]:
        info, _ = parse(path)
        print(json.dumps(info, indent=2, ensure_ascii=False))
        print("-" * 60)
