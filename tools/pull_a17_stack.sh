#!/usr/bin/env bash
# =============================================================================
# pull_a17_stack.sh - ambil stack TEE/keymint MILIK ROM Android 17 dari HP
# =============================================================================
#
# Kenapa perlu:
#   Recovery TWRP membawa salinan prebuilt /vendor dari vendor stock Android 14
#   (keymint AIDL V1 + TA lama). ROM Android 17 (Halcyon) memakai keymint AIDL
#   V3/V4 (lib android.hardware.security.keymint-V3-ndk-v35.so / -V4-ndk.so)
#   dan TA yang cocok dengan firmware TEE baru (partisi `tee` ikut di-flash OTA).
#   Salinan lama tidak bisa membuka key blob FBE yang dibuat TEE baru ->
#   dekripsi gagal. Script ini menyalin stack A17 ke a17/prebuilt/vendor/,
#   lalu workflow/build lokal memasukkannya ke ramdisk recovery.
#
# Syarat:
#   - HP boot ke TWRP (atau ROM A17 dengan adb root), /vendor ter-mount.
#   - adb tersedia di PATH.
#
# Pakai:
#   ./tools/pull_a17_stack.sh
#   git add a17/prebuilt && git commit -m "a17: refresh TEE/keymint stack"
# =============================================================================
set -u

ADB=${ADB:-adb}
OUT=$(cd "$(dirname "$0")/.." && pwd)/a17/prebuilt/vendor

FILES="
bin/hw/android.hardware.security.keymint@1.0-service.mitee
bin/hw/android.hardware.gatekeeper@1.0-service
bin/hw/android.hardware.gatekeeper-service.mitee
bin/tee-supplicant
bin/miteelog
lib64/libteecli.so
lib64/android.hardware.security.keymint-V3-ndk-v35.so
lib64/android.hardware.security.keymint-V4-ndk.so
lib64/libkeymint_support.so
lib64/libcppcose_rkp.so
lib64/librkp-V3-ndk.so
lib64/libgatekeeper_aidl.so
lib64/hw/gatekeeper.mitee.so
lib64/hw/gatekeeper.default.so
lib64/hw/gatekeeper.beanpod.so
lib64/hw/libSoftGatekeeper.so
etc/vintf/manifest/android.hardware.security.keymint-service.mitee.xml
etc/vintf/manifest/android.hardware.security.secureclock-service.mitee.xml
etc/vintf/manifest/android.hardware.security.sharedsecret-service.mitee.xml
etc/vintf/manifest/android.hardware.gatekeeper-service.mitee.xml
etc/init/android.hardware.security.keymint-service.mitee.rc
etc/init/tee-supplicant.rc
etc/init/miteelog.rc
"

if ! $ADB devices | grep -q "device$"; then
    echo "ERROR: tidak ada perangkat di adb. Boot ke TWRP dulu." >&2
    exit 1
fi

mkdir -p "$OUT"
ok=0
fail=0

for f in $FILES; do
    mkdir -p "$OUT/$(dirname "$f")"
    if $ADB pull "/vendor/$f" "$OUT/$f" >/dev/null 2>&1; then
        echo "  ok   /vendor/$f"
        ok=$((ok + 1))
    else
        echo "  lewat /vendor/$f (tidak ada)"
        fail=$((fail + 1))
    fi
done

# TA (Trusted Application) - sumber utama kegagalan keymaster di recovery.
echo "  tarik /vendor/mitee/ta/ ..."
mkdir -p "$OUT/mitee/ta"
if $ADB pull /vendor/mitee/ta/. "$OUT/mitee/ta/" >/dev/null 2>&1; then
    ta=$(ls -1 "$OUT/mitee/ta" 2>/dev/null | wc -l)
    echo "  ok   $ta file .ta"
else
    echo "  GAGAL tarik TA - cek apakah /vendor ter-mount di TWRP" >&2
fi

echo
echo "selesai: $ok file ok, $fail tidak ada"
echo "output : $OUT"

# --- verifikasi: apakah yang ditarik benar-benar stack A17? ------------------
KM="$OUT/bin/hw/android.hardware.security.keymint@1.0-service.mitee"
if [ -f "$KM" ]; then
    if grep -qa "keymint-V3-ndk\|keymint-V4-ndk" "$KM"; then
        echo "cek    : keymint A17 (V3/V4) terdeteksi - OK"
    else
        echo "cek    : PERINGATAN keymint masih versi V1 (A14)." >&2
        echo "         Pastikan /vendor ROM A17 benar-benar ter-mount saat pull." >&2
    fi
else
    echo "cek    : service keymint tidak ikut ter-tarik - build akan pakai prebuilt A14." >&2
fi

GK="$OUT/bin/hw/android.hardware.gatekeeper-service.mitee"
if [ -f "$GK" ]; then
    echo "cek    : gatekeeper AIDL A17 ikut ter-tarik - OK"
else
    echo "catatan: gatekeeper AIDL A17 tidak ada; ramdisk tetap pakai HIDL 1.0 (A14)."
fi

echo
echo "kalau ada .ta yang masuk, lanjut:"
echo "  git add a17/prebuilt && git commit -m 'a17: TEE stack dari ROM A17' && git push"
