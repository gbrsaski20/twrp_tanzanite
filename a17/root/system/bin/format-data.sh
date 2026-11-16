#!/system/bin/sh
# =============================================================================
# format-data.sh - format /data manual dari TWRP / OrangeFox
# =============================================================================
#
# Kenapa ada script ini:
#   Tombol "Format Data" di recovery memakai jalur yang sama dengan dekripsi:
#   setelah filesystem dibuat, recovery minta keystore2/keymint membuat kunci
#   FBE baru. Kalau keymint/TEE gagal (stack TEE lama vs ROM Android 17),
#   hasilnya "Unable to format data" / "Failed to mount /data" - padahal
#   filesystem-nya sendiri belum tentu masalah.
#   Script ini memisahkan dua langkah itu: format filesystem dulu, lihat
#   hasilnya, baru urus kunci.
#
# Pakai (dari TWRP/OFox, Advanced > Terminal, atau adb shell):
#   sh /system/bin/format-data.sh                     # format /data saja
#   sh /system/bin/format-data.sh --wipe-metadata     # + hapus kunci metadata
#
# PENTING: --wipe-metadata menghapus kunci enkripsi metadata. Semua data di
# /data hilang (memang tujuannya) dan ROM akan membuat kunci baru saat boot
# pertama. Pakai ini kalau kunci metadata sudah tidak bisa dibuka TEE
# (mis. habis ganti ROM / partisi tee ter-flash ulang).
# =============================================================================

DEV_DATA=/dev/block/by-name/userdata
DEV_META=/dev/block/by-name/metadata
LOG=/tmp/format-data.log

WIPE_META=0
[ "$1" = "--wipe-metadata" ] && WIPE_META=1

say() { echo "$@" | tee -a "$LOG"; }
run() {
    say "\$ $*"
    "$@" >> "$LOG" 2>&1
    rc=$?
    say "  -> rc=$rc"
    return $rc
}

: > "$LOG"
say "=== format-data $(date) ==="
say "data: $DEV_DATA  meta: $DEV_META  wipe_metadata=$WIPE_META"

say ""
say "--- sebelum: mount & modul ---"
grep -E " /data | /metadata " /proc/mounts >> "$LOG" 2>&1
grep -E "mitee|tee" /proc/modules >> "$LOG" 2>&1

say ""
say "--- lepas mount ---"
umount /data 2>/dev/null
umount /metadata 2>/dev/null
umount -l /data 2>/dev/null
umount -l /metadata 2>/dev/null
sleep 1
grep -E " /data | /metadata " /proc/mounts >> "$LOG" 2>&1

say ""
say "--- format /data (f2fs) ---"
# Opsi mengikuti fstab ROM A17: encrypt + quota + casefold.
# compression sengaja tidak dipakai: fstab A17 tidak memintanya dan
# f2fs-tools di recovery bisa menolak opsi itu.
run make_f2fs -f -O encrypt -O quota -O casefold "$DEV_DATA"
rc_data=$?

if [ "$WIPE_META" = "1" ]; then
    say ""
    say "--- format /metadata (ext4) ---"
    run mke2fs -t ext4 -m 0 "$DEV_META"
    rc_meta=$?
else
    rc_meta="dilewati"
fi

sync
say ""
say "--- sesudah ---"
grep -E " /data | /metadata " /proc/mounts >> "$LOG" 2>&1

say ""
if [ "$rc_data" = "0" ]; then
    say "HASIL: /data terformat."
    say "Langkah berikutnya: reboot ke recovery, lalu coba Mount /data."
    say "Kalau mount masih gagal, kunci FBE belum bisa dibuat -> jalankan:"
    say "  adb pull /tmp/crypto-diag.log"
else
    say "HASIL: format /data GAGAL (rc=$rc_data)."
    say "Cek: dmesg | tail -40  (cari error UFS/eMMC atau read-only)"
    say "Kalau partisi read-only, itu bukan masalah recovery."
fi
[ "$WIPE_META" = "1" ] && say "metadata: rc=$rc_meta"
say ""
say "log lengkap: $LOG"
