import re, datetime

rows = []
pat = re.compile(r"^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+([VDIWEF])/([^(]*?)\(\s*(\d+)\):\s?(.*)$")
for ln in open("work/logcat_rec.txt", encoding="utf-8", errors="replace"):
    m = pat.match(ln.rstrip("\r\n"))
    if not m:
        continue
    try:
        t = datetime.datetime.strptime("2026-" + m.group(1), "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        continue
    rows.append((t, m.group(2), m.group(3), m.group(5)))

rows.sort(key=lambda r: r[0])
print("entries", len(rows))
if not rows:
    raise SystemExit("no rows parsed")
print("first", rows[0][0].time(), "last", rows[-1][0].time())

t0 = rows[0][0]
prev = t0
print()
print("GAPS >= 0.25s, first 60s:")
for r in rows:
    rel = (r[0] - t0).total_seconds()
    if rel > 60:
        break
    d = (r[0] - prev).total_seconds()
    if d >= 0.25:
        print("  t=%5.2fs  +%.2fs  %s/%s: %s" % (rel, d, r[1], r[2], r[3][:80]))
    prev = r[0]

print()
print("LAST 5 EVENTS within 60s:")
cnt = 0
for r in rows:
    rel = (r[0] - t0).total_seconds()
    if rel <= 60:
        cnt += 1
        last = (rel, r[1], r[2], r[3])
print("  t=%5.2fs  %s/%s: %s" % (last[0], last[1], last[2], last[3][:90]))
