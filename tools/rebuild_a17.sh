#!/usr/bin/env bash
# =============================================================================
# rebuild_a17.sh - rakit ulang image recovery (TWRP / OrangeFox) di atas basis A17
# =============================================================================
#
# Pakai:
#   ./tools/rebuild_a17.sh twrp vendor_boot_a17.img vendor_boot_twrp_lama.img out.img
#   ./tools/rebuild_a17.sh ofox vendor_boot_a17.img OrangeFox-lama.img out.img
#
# Argumen 1 hanya menentukan nama file default kalau argumen 4 dikosongkan.
# Semua langkahnya sama untuk TWRP dan OrangeFox: fstab A17, 217 modul A17,
# fragmen init A17, crypto-diag.sh, format-data.sh.
#
# Kernel custom:
#   Modul vendor di ramdisk HARUS berasal dari kernel yang sama dengan yang ada
#   di boot.img (vermagic + versi simbol). Kalau memakai kernel custom, kasih
#   foldernya lewat env MODULES:
#
#     MODULES=/path/ke/modul-hasil-build ./tools/rebuild_a17.sh ofox ...
#
#   Folder itu boleh berisi .ko langsung atau struktur lib/modules/... .
# =============================================================================
set -eu

KIND=${1:?twrp|ofox}
BASE=${2:?vendor_boot A17 (Halcyon)}
REC=${3:?image recovery yang sekarang}
OUT=${4:-vendor_boot_${KIND}_tanzanite_a17.img}

HERE=$(cd "$(dirname "$0")/.." && pwd)

ARGS=""
if [ -n "${MODULES:-}" ]; then
    ARGS="--modules-from $MODULES"
    echo "modul      : dari $MODULES (bukan modul A17)"
fi

# shellcheck disable=SC2086
python3 "$HERE/tools/repack_vendor_boot.py" \
    --base-a17 "$BASE" \
    --recovery "$REC" \
    --overlay "$HERE/a17/root" \
    --fstab "$HERE/a17/fstab.mt6789" \
    --init-append "$HERE/a17/init.append.rc" \
    $ARGS \
    --out "$OUT"

echo
echo "selesai: $OUT"
echo "flash:"
echo "  fastboot flash vendor_boot $(basename "$OUT")"
echo "  fastboot reboot recovery"
