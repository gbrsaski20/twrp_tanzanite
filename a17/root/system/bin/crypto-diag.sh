#!/system/bin/sh
# crypto-diag.sh - kumpulkan bukti kenapa dekripsi FBE gagal di recovery.
#
# Dijalankan otomatis setelah TWRP/OrangeFox mencoba dekripsi (lihat
# init.recovery.mt6789.rc) dan bisa juga dipanggil manual dari adb shell:
#
#     sh /system/bin/crypto-diag.sh
#     adb pull /tmp/crypto-diag.log
#
# Isi log tidak memuat kunci/data pribadi: hanya properti, daftar modul,
# status service HAL, nama file kunci, dan potongan logcat/dmesg.

OUT=/tmp/crypto-diag.log
: > "$OUT"

log() { echo "$@" >> "$OUT"; }
sec() { echo "" >> "$OUT"; echo "===== $* =====" >> "$OUT"; }

# Cari proses lewat /proc/*/cmdline (binary `service` tidak ada di ramdisk,
# dan `pidof` memakai nama comm yang di-truncate 15 karakter).
running() {
    for f in /proc/[0-9]*/cmdline; do
        [ -s "$f" ] || continue
        tr '\0' '\n' < "$f" 2>/dev/null | grep -Fq "$1" && return 0
    done
    return 1
}
hal_state() {  # $1 = nama service init, $2 = pola binary
    if running "$2"; then
        log "  $1: JALAN"
    else
        log "  $1: TIDAK JALAN"
    fi
}

sec "build"
log "date      : $(date)"
log "uname     : $(uname -a)"
log "recovery  : $(getprop ro.twrp.version) / $(getprop ro.build.version.release)"
log "device    : $(getprop ro.product.device) / sdk $(getprop ro.build.version.sdk)"
log "fox cfg   : $(grep -E 'FOX_CODE_BASE|FOX_BUILD_DATE' /system/etc/fox.cfg 2>/dev/null | tr '\n' ' ')"

sec "crypto properties"
getprop 2>/dev/null | grep -iE "crypto|keymaster|keymint|vold|fbe|fscrypt|metadata|of_skip" | sort >> "$OUT"

sec "partitions (by-name)"
ls -l /dev/block/by-name/ 2>/dev/null | grep -iE "metadata|userdata|vendor|tee" >> "$OUT"

sec "mounts"
cat /proc/mounts 2>/dev/null | grep -vE "^(proc|sysfs|devpts|tmpfs|cgroup)" >> "$OUT"

sec "modules (tee / dm / ice)"
grep -E "mitee|tee|dm-|ice|fscrypt|dm_default_key" /proc/modules 2>/dev/null >> "$OUT"

sec "tee devices"
ls -l /dev/tee* /dev/rpmb* /dev/mmcblk0rpmb 2>&1 >> "$OUT"

sec "hal services"
hal_state "tee-supplicant"  "tee-supplicant"
hal_state "keymint-mitee"   "keymint@1.0-service.mitee"
hal_state "gatekeeper-1-0"  "gatekeeper@1.0-service"
hal_state "keystore2"       "/system/bin/keystore2"
ps -A 2>/dev/null | grep -iE "keymint|keymaster|gatekeeper|tee-supplicant|miteelog|keystore" >> "$OUT"

sec "vendor tee stack (ramdisk copy)"
ls -l /vendor/bin/hw/ 2>/dev/null | grep -iE "keymint|gatekeeper" >> "$OUT"
ls -l /vendor/lib64/libteecli.so 2>&1 >> "$OUT"
ls -l /vendor/mitee/ta/ 2>&1 | head -30 >> "$OUT"

sec "keymaster version"
log "  keymaster_ver prop : $(getprop keymaster_ver)"
log "  (TW_FORCE_KEYMASTER_VER aktif: tanpa prop ini TWRP memakai versi default)"

sec "metadata encryption"
ls -l /metadata 2>&1 | head -5 >> "$OUT"
ls -l /metadata/vold/metadata_encryption/ 2>&1 | head -20 >> "$OUT"

sec "user 0 keys"
log "-- /data ter-mount? --"
grep " /data " /proc/mounts 2>/dev/null >> "$OUT"
log "-- vold user_keys --"
ls -l /data/misc/vold/user_keys/ 2>&1 >> "$OUT"
ls -l /data/misc/vold/user_keys/ce/0/current/ 2>&1 >> "$OUT"
ls -l /data/misc/vold/user_keys/de/0/ 2>&1 >> "$OUT"
log "-- gatekeeper handle user 0 --"
ls -l /data/system/users/0/gatekeeper.* 2>&1 >> "$OUT"
ls -l /data/system/users/gatekeeper.* 2>&1 >> "$OUT"
log "-- spblob --"
ls -l /data/system_de/0/spblob/ 2>&1 >> "$OUT"

sec "twrp decrypt log"
grep -iE "decrypt|keymaster|keymint|fbe|crypto|gatekeeper" /tmp/recovery.log 2>/dev/null | tail -200 >> "$OUT"

sec "logcat (filtered)"
logcat -d -v time 2>/dev/null \
    | grep -iE "keymint|keymaster|decrypt|fbe|fscrypt|metadata_encryption|vold|tee|mitee|gatekeeper" \
    | tail -300 >> "$OUT"

sec "dmesg (filtered)"
dmesg 2>/dev/null | grep -iE "tee|mitee|keymaster|dm-|ice|f2fs.*crypt" | tail -150 >> "$OUT"

sec "kesimpulan (heuristik)"
if ! running "gatekeeper@1.0-service"; then
    log "* gatekeeper TIDAK jalan. Ini penyebab klasik 'Failed to decrypt user 0':"
    log "  metadata/DE terbuka, tapi CE key user 0 butuh gatekeeper untuk"
    log "  memverifikasi PIN. Cek /tmp/crypto-hal.log."
fi
if ! running "keymint@1.0-service.mitee"; then
    log "* keymint TIDAK jalan -> metadata/DE key tidak bisa dibuka sama sekali."
fi
if [ "$(getprop of_skip_fbe_decryption)" = "1" ]; then
    log "* of_skip_fbe_decryption=1 (OrangeFox): dekripsi sengaja dilewati."
fi
if [ -d /data/misc/vold/user_keys/ce/0 ] && [ -z "$(ls -A /data/misc/vold/user_keys/ce/0 2>/dev/null)" ]; then
    log "* /data/misc/vold/user_keys/ce/0 kosong: kunci user 0 memang belum ada"
    log "  (wajar kalau ROM baru di-flash dan belum pernah boot dengan PIN)."
fi
log "* kalau semua di atas JALAN tetapi tetap gagal: kirim log ini + recovery.log."

sec "end"
log "log selesai: $OUT"

echo "crypto-diag: $OUT"
