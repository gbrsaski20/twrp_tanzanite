import re, datetime

pat = re.compile(r"^(10-28 \d\d:\d\d:\d\d\.\d+) +([VDIWEF])/([^(]*?)\( *(\d+)\): (.*)$")
rows = []
for ln in open("work/logcat_rec.txt", encoding="utf-8", errors="replace"):
    m = pat.match(ln.rstrip())
    if not m:
        continue
    t = datetime.datetime.strptime("2026-" + m.group(1), "%Y-%m-%d %H:%M:%S.%f")
    rows.append((t, m.group(2), m.group(3), m.group(5)))

rows.sort(key=lambda r: r[0])
print("rows:", len(rows))
print("span:", rows[0][0].time(), "->", rows[-1][0].time())

t0 = rows[0][0]
prev = t0
print()
print("GAPS >= 0.2s:")
for r in rows:
    d = (r[0] - prev).total_seconds()
    if d >= 0.2:
        print("  +%5.2fs  at %s  %s/%s: %s"
              % (d, r[0].time(), r[1], r[2], r[3][:80]))
    prev = r[0]
