#!/system/bin/sh
# crypto-diag.sh - kumpulkan bukti kenapa dekripsi FBE gagal di recovery.
#
# Dijalankan otomatis saat recovery boot (lihat init.recovery.mt6789.rc) dan
# bisa juga dipanggil manual dari adb shell:
#
#     sh /system/bin/crypto-diag.sh
#     adb pull /tmp/crypto-diag.log
#
# Isi log tidak memuat kunci/data pribadi: hanya properti, daftar modul,
# status service HAL, dan potongan logcat/dmesg.

OUT=/tmp/crypto-diag.log
: > "$OUT"

log() { echo "$@" >> "$OUT"; }
sec() { echo "" >> "$OUT"; echo "===== $* =====" >> "$OUT"; }

sec "build"
log "date      : $(date)"
log "uname     : $(uname -a)"
log "recovery  : $(getprop ro.twrp.version) / $(getprop ro.build.version.release)"
log "device    : $(getprop ro.product.device) / sdk $(getprop ro.build.version.sdk)"

sec "crypto properties"
getprop 2>/dev/null | grep -iE "crypto|keymaster|keymint|vold|fbe|fscrypt|metadata" | sort >> "$OUT"

sec "partitions (by-name)"
ls -l /dev/block/by-name/ 2>/dev/null | grep -iE "metadata|userdata|vendor|tee" >> "$OUT"

sec "mounts"
cat /proc/mounts 2>/dev/null | grep -vE "^(proc|sysfs|devpts|tmpfs|cgroup)" >> "$OUT"

sec "modules (tee / dm / ice)"
grep -E "mitee|tee|dm-|ice|fscrypt|dm_default_key" /proc/modules 2>/dev/null >> "$OUT"

sec "tee devices"
ls -l /dev/tee* /dev/rpmb* /dev/mmcblk0rpmb 2>&1 >> "$OUT"

sec "hal services"
ps -A 2>/dev/null | grep -iE "keymint|keymaster|gatekeeper|tee-supplicant|miteelog" >> "$OUT"

sec "vendor tee stack (ramdisk copy)"
ls -l /vendor/bin/hw/ 2>/dev/null | grep -iE "keymint|gatekeeper" >> "$OUT"
ls -l /vendor/lib64/libteecli.so /vendor/mitee/ta/ 2>&1 | head -30 >> "$OUT"

sec "vendor tee stack (ROM, if mounted)"
ls -l /vendor/mitee/ta/ 2>&1 | head -30 >> "$OUT"

sec "keymint interface version"
dumpsys 2>/dev/null | grep -iA2 keymint >> "$OUT"
service list 2>/dev/null | grep -iE "keymint|keymaster|gatekeeper" >> "$OUT"

sec "twrp decrypt log"
grep -iE "decrypt|keymaster|keymint|fbe|crypto" /tmp/recovery.log 2>/dev/null | tail -200 >> "$OUT"

sec "logcat (filtered)"
logcat -d -v time 2>/dev/null \
    | grep -iE "keymint|keymaster|decrypt|fbe|fscrypt|metadata_encryption|vold|tee|mitee" \
    | tail -300 >> "$OUT"

sec "dmesg (filtered)"
dmesg 2>/dev/null | grep -iE "tee|mitee|keymaster|dm-|ice|f2fs.*crypt" | tail -150 >> "$OUT"

sec "end"
log "log selesai: $OUT"

echo "crypto-diag: $OUT"
