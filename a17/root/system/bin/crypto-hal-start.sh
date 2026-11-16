#!/system/bin/sh
# crypto-hal-start.sh - pastikan stack TEE/keymint/gatekeeper benar-benar JALAN.
#
# Kenapa perlu:
#   Service HAL di init.recovery.mt6789.rc bersifat `disabled` + `oneshot`.
#   Kalau satu kali gagal start (tee-supplicant telat, TEE belum siap,
#   servicemanager belum jalan), init tidak pernah mencoba lagi. Akibatnya
#   gatekeeper/keymint mati, dan setiap percobaan dekripsi berakhir dengan
#   "Failed to decrypt user 0" walau /metadata dan /data sudah terbuka.
#
#   Script ini dipanggil init (service crypto-hal-start) saat
#   servicemanager.ready / hwservicemanager.ready, lalu:
#     1. tunggu servicemanager siap,
#     2. nyalakan tee-supplicant -> keymint -> gatekeeper dengan retry,
#     3. tulis hasilnya ke /tmp/crypto-hal.log.
#
#   Log: adb pull /tmp/crypto-hal.log

LOG=/tmp/crypto-hal.log
: > "$LOG"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# Cari proses lewat /proc/*/cmdline. `pidof` tidak dipakai karena nama proses
# di-truncate 15 karakter (comm), sedangkan nama HAL jauh lebih panjang.
running() {
    for f in /proc/[0-9]*/cmdline; do
        [ -s "$f" ] || continue
        if tr '\0' '\n' < "$f" 2>/dev/null | grep -Fq "$1"; then
            return 0
        fi
    done
    return 1
}

ensure() {  # $1 = nama service init, $2 = potongan path binary, $3 = retry
    svc="$1"; pat="$2"; max="${3:-4}"; n=0
    while [ "$n" -lt "$max" ]; do
        if running "$pat"; then
            log "$svc: jalan"
            return 0
        fi
        log "$svc: start (percobaan $((n + 1))/$max)"
        setprop ctl.start "$svc"
        sleep 2
        n=$((n + 1))
    done
    if running "$pat"; then
        log "$svc: jalan"
        return 0
    fi
    log "$svc: GAGAL start - lihat /tmp/recovery.log dan /tmp/crypto-diag.log"
    return 1
}

# --- 1. tunggu servicemanager ------------------------------------------------
i=0
while [ "$i" -lt 15 ]; do
    [ "$(getprop servicemanager.ready)" = "true" ] && break
    i=$((i + 1))
    sleep 1
done
log "servicemanager.ready=$(getprop servicemanager.ready) (tunggu ${i}s)"
log "hwservicemanager.ready=$(getprop hwservicemanager.ready)"
log "ro.crypto.state=$(getprop ro.crypto.state)"

# --- 2. nyalakan HAL sesuai urutan ketergantungan ---------------------------
# tee-supplicant dulu: keymint butuh /dev/tee* + supplicant untuk load TA.
ensure tee-supplicant  "tee-supplicant"
ensure keymint-mitee   "keymint@1.0-service.mitee"
ensure gatekeeper-1-0  "gatekeeper@1.0-service"

log "selesai"
echo "crypto-hal-start: $LOG"
