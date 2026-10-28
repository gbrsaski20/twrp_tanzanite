import sys, os, gzip, struct, io
sys.path.insert(0, os.path.dirname(__file__))
from vbimg2 import parse_image, lz4_legacy_decompress, cpio_parse

IMG = sys.argv[1]
OUTDIR = sys.argv[2] if len(sys.argv) > 2 else "work/pi"

info = parse_image(IMG)
os.makedirs(OUTDIR, exist_ok=True)

for fr in info["frags"]:
    raw = fr["data"]
    name = fr["name"] or "platform"
    print("fragment %-10s %9d bytes  magic=%s" % (name, len(raw), raw[:4].hex()))
    if raw[:2] == b"\x1f\x8b":
        data = gzip.decompress(raw)
        print("  gzip ->", len(data))
    elif raw[:4] == b"\x02\x21\x4c\x18":
        data = lz4_legacy_decompress(raw)
        print("  lz4 legacy ->", len(data))
    elif raw[:6] in (b"070701", b"070702"):
        data = raw
        print("  plain cpio ->", len(data))
    else:
        print("  unknown container, dumping raw")
        open(os.path.join(OUTDIR, "frag_%s.raw" % name), "wb").write(raw)
        continue

    ents = cpio_parse(data)
    print("  entries:", len(ents))
    base = os.path.join(OUTDIR, "root")
    for e in ents:
        nm = e["name"]
        if nm in (".", "..", "TRAILER!!!"):
            continue
        p = os.path.join(base, nm.lstrip("/"))
        if e["vals"][1] & 0o170000 == 0o040000:
            os.makedirs(p, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            try:
                with open(p, "wb") as f:
                    f.write(e["body"])
            except OSError as ex:
                print("   skip", nm, ex)
    print("  extracted to", base)
