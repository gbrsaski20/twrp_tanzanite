#!/usr/bin/env bash
#
# Sync latest scripts from Windows workspace into WSL home,
# then run environment diagnostics.
#
# Usage (inside WSL, NOT PowerShell):
#   bash /mnt/e/workbuddyainew/2026-10-26-15-33-38/twrp_tanzanite/update_and_diagnose.sh
#
set -u

SRC="/mnt/e/workbuddyainew/2026-10-26-15-33-38/twrp_tanzanite"
DST="${HOME}/twrp_tanzanite"

echo "============================================================"
echo "  Sync scripts + diagnose"
echo "============================================================"
echo ""

# Sanity: are we actually in WSL/Linux?
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: This must be run inside WSL/Linux, not PowerShell."
    echo "Type 'wsl' first, then run this script."
    exit 1
fi

# Sanity: can we see the Windows drive?
if [ ! -d "${SRC}" ]; then
    echo "ERROR: Cannot find ${SRC}"
    echo ""
    echo "Check that E: is mounted. Try: ls /mnt/e"
    echo "If /mnt/e is empty, run from PowerShell: wsl --shutdown  then reopen WSL."
    exit 1
fi

mkdir -p "${DST}/local_manifests"

echo "--- Copying scripts ---"
for f in fix_env.sh build_twrp_tanzanite.sh flash_twrp.sh SOURCES.md README.md; do
    if [ -f "${SRC}/${f}" ]; then
        cp -f "${SRC}/${f}" "${DST}/${f}" && echo "  ok  ${f}"
    else
        echo "  skip ${f} (not found)"
    fi
done

for f in tanzanite.xml tanzanite-nathan-kernel.xml; do
    if [ -f "${SRC}/local_manifests/${f}" ]; then
        cp -f "${SRC}/local_manifests/${f}" "${DST}/local_manifests/${f}" && echo "  ok  local_manifests/${f}"
    fi
done

chmod +x "${DST}/fix_env.sh" "${DST}/build_twrp_tanzanite.sh" 2>/dev/null

echo ""
echo "--- Files now in ${DST} ---"
ls -1 "${DST}"
echo ""
echo "--- local_manifests ---"
ls -1 "${DST}/local_manifests"
echo ""

echo "============================================================"
echo "  Running diagnostics"
echo "============================================================"
echo ""

cd "${DST}" || exit 1
exec bash ./fix_env.sh
