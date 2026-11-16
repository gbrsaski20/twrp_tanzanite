#!/usr/bin/env bash
# =============================================================================
# pull_pstore.sh - ambil log kernel dari boot yang gagal (pstore/ramoops)
# =============================================================================
#
# Urutan pemakaian (penting, jangan diubah):
#   1. flash kernel yang mau diuji, coba boot recovery sampai gagal/mati
#   2. tahan power sampai mati  (JANGAN boot ke ROM dulu - pstore bisa tertimpa)
#   3. fastboot flash boot boot_halcyon_A17_stok.img
#      fastboot flash vendor_boot vendor_boot_orangefox_tanzanite_A17_brand.img
#   4. boot ke recovery, lalu jalankan:  ./tools/pull_pstore.sh
#
# Script ini menjalankan pstore-dump.sh di recovery, menarik /tmp/pstore.log,
# dan kalau service-nya tidak jalan, membaca /sys/fs/pstore langsung.
# =============================================================================
set -u

ADB=${ADB:-}
if [ -z "$ADB" ]; then
    if command -v adb >/dev/null 2>&1; then
        ADB=adb
    elif [ -x "/f/Tool RedmiNote14/platform-tools/adb" ]; then
        ADB="/f/Tool RedmiNote14/platform-tools/adb"
    else
        echo "ERROR: adb tidak ditemukan. Set ADB=/path/ke/adb" >&2
        exit 1
    fi
fi

OUT="pstore-$(date +%Y%m%d-%H%M%S).log"

if ! "$ADB" devices | grep -q "device$"; then
    echo "Tidak ada perangkat di adb."
    echo
    echo "Cek dulu:  fastboot devices"
    if command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -q "fastboot"; then
        echo "Perangkat ada di FASTBOOT. Flash dulu supaya bisa masuk recovery:"
        echo "  fastboot flash boot boot_halcyon_A17_stok.img"
        echo "  fastboot flash vendor_boot vendor_boot_orangefox_tanzanite_A17_brand.img"
        echo "  fastboot reboot recovery"
    else
        echo "Boot perangkat ke recovery (TWRP/OFox), lalu jalankan script ini lagi."
    fi
    exit 1
fi

echo "== perangkat =="
"$ADB" shell 'uname -a; echo "slot: $(getprop ro.boot.slot_suffix)"' 2>/dev/null | head -3

echo
echo "== jalankan pstore-dump.sh =="
if "$ADB" shell "[ -f /system/bin/pstore-dump.sh ]" 2>/dev/null; then
    "$ADB" shell sh /system/bin/pstore-dump.sh 2>&1 | tail -3
else
    echo "  pstore-dump.sh tidak ada di image ini - baca /sys/fs/pstore langsung"
fi

echo
echo "== tarik log =="
if "$ADB" pull /tmp/pstore.log "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ]; then
    echo "  tersimpan: $OUT ($(wc -c <"$OUT") byte)"
else
    echo "  /tmp/pstore.log kosong, baca pstore langsung..."
    "$ADB" shell 'mount | grep -q " /sys/fs/pstore " || mount -t pstore pstore /sys/fs/pstore 2>/dev/null; for f in /sys/fs/pstore/*; do [ -f "$f" ] && { echo "===== $f ====="; cat "$f"; }; done' >"$OUT" 2>/dev/null
    if [ -s "$OUT" ]; then
        echo "  tersimpan: $OUT ($(wc -c <"$OUT") byte)"
    else
        echo "  pstore KOSONG. Kemungkinan:"
        echo "   - boot yang gagal tidak sempat menulis ramoops (hang sangat awal), atau"
        echo "   - sudah ada boot sukses setelahnya (ramoops tertimpa), atau"
        echo "   - perangkat sempat mati total / baterai dicabut (RAM hilang)."
        exit 2
    fi
fi

echo
echo "== ringkasan isi =="
grep -iE "disagrees about version|version magic|Unknown symbol|module verification|Kernel panic|Unable to handle|Call trace" "$OUT" | head -12
echo
echo "kirim file $OUT ke chat kalau butuh dianalisa."
