import sys, os, struct

SRC = sys.argv[1]
WANT = sys.argv[2:]
data = open(SRC, "rb").read()

off = 0
found = {}
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
    body_off = off + 110 + namesize
    body_off = (body_off + 3) & ~3
    body = data[body_off:body_off + filesize]
    for w in WANT:
        if name == w:
            found[name] = (mode, body)
    off = body_off + filesize
    off = (off + 3) & ~3
    if name == "TRAILER!!!":
        break

os.makedirs("work/extracted", exist_ok=True)
for name, (mode, body) in found.items():
    out = os.path.join("work/extracted", name.replace("/", "_"))
    open(out, "wb").write(body)
    print("%07o %8d %s -> %s" % (mode, len(body), name, out))

missing = [w for w in WANT if w not in found]
if missing:
    print("MISSING:", missing)
