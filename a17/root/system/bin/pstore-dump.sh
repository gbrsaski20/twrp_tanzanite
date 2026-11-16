#!/system/bin/sh
# pstore-dump.sh - selamatkan log kernel dari boot yang gagal.
#
# pstore/ramoops menyimpan dmesg boot terakhir di RAM, jadi masih ada walau
# boot-nya berhenti sebelum UI (kernel panic, driver tidak load, hang). Kalau
# recovery berikutnya boot dengan kernel yang sehat, isinya bisa dibaca di sini.
#
# Dipakai untuk kasus "flash kernel custom -> recovery tidak mau boot":
#   1. flash kernel custom, coba boot recovery (gagal), matikan paksa
#   2. flash boot.img stok, boot recovery
#   3. adb pull /tmp/pstore.log
#
# Dipanggil otomatis oleh init (service pstore-dump), bisa juga manual:
#   sh /system/bin/pstore-dump.sh

LOG=/tmp/pstore.log
: > "$LOG"

echo "date: $(date)" >> "$LOG"
echo "uname: $(uname -a)" >> "$LOG"

# pstore biasanya sudah di-mount init, tapi di recovery bisa belum.
if ! grep -q " /sys/fs/pstore " /proc/mounts 2>/dev/null; then
    mount -t pstore pstore /sys/fs/pstore 2>>"$LOG"
fi

if [ ! -d /sys/fs/pstore ]; then
    echo "pstore: /sys/fs/pstore tidak ada (kernel tanpa CONFIG_PSTORE)" >> "$LOG"
    echo "pstore-dump: tidak tersedia"
    exit 0
fi

n=0
for f in /sys/fs/pstore/*; do
    [ -f "$f" ] || continue
    echo "" >> "$LOG"
    echo "===== $f =====" >> "$LOG"
    cat "$f" >> "$LOG" 2>/dev/null
    n=$((n + 1))
done

if [ "$n" -eq 0 ]; then
    echo "pstore: kosong (tidak ada boot yang gagal, atau sudah dibaca)" >> "$LOG"
    echo "pstore-dump: kosong"
else
    echo "pstore-dump: $n file -> $LOG"
fi
