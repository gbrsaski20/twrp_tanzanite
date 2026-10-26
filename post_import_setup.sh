#!/usr/bin/env bash
#
# =============================================================================
# Post-import setup: prepare a freshly restored WSL for the TWRP build
# =============================================================================
# Run INSIDE WSL (after restore_wsl.ps1 has imported the distro):
#   bash /mnt/e/workbuddyainew/2026-10-26-15-33-38/twrp_tanzanite/post_import_setup.sh
# =============================================================================

set -u

SRC="/mnt/e/workbuddyainew/2026-10-26-15-33-38/twrp_tanzanite"
DST="${HOME}/twrp_tanzanite"
WANT_USER="gian_br"

echo "============================================================"
echo "  Post-import setup for TWRP build"
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# 0. Must be Linux
# ------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: run this inside WSL, not PowerShell."
    exit 1
fi

CURRENT_USER=$(id -un)
echo "Current user: ${CURRENT_USER}"
echo "Home:         ${HOME}"
echo ""

# ------------------------------------------------------------------
# 1. Fix default user if we're root (import resets to root)
# ------------------------------------------------------------------
if [ "${CURRENT_USER}" = "root" ] && id "${WANT_USER}" >/dev/null 2>&1; then
    echo "--- Setting default user to ${WANT_USER} ---"
    if [ -f /etc/wsl.conf ] && grep -q '^default=' /etc/wsl.conf; then
        sed -i "s/^default=.*/default=${WANT_USER}/" /etc/wsl.conf
    else
        if ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
            printf '\n[user]\ndefault=%s\n' "${WANT_USER}" >> /etc/wsl.conf
        else
            sed -i "/^\[user\]/a default=${WANT_USER}" /etc/wsl.conf
        fi
    fi
    echo "  /etc/wsl.conf updated (takes effect after 'wsl --shutdown'):"
    cat /etc/wsl.conf
    echo ""
    echo "  NOTE: continuing as root for this setup run is fine."
    echo ""
fi

# ------------------------------------------------------------------
# 2. Show current space
# ------------------------------------------------------------------
echo "--- Disk state ---"
df -h / | tail -1
echo ""

# ------------------------------------------------------------------
# 3. Clean up the corrupted build tree
# ------------------------------------------------------------------
if [ -d "${HOME}/twrp-build" ]; then
    SZ=$(du -sh "${HOME}/twrp-build" 2>/dev/null | awk '{print $1}')
    echo "--- Removing corrupted build tree (${SZ}) ---"
    rm -rf "${HOME}/twrp-build"
    echo "  removed ${HOME}/twrp-build"
else
    echo "--- No existing build tree (clean) ---"
fi
echo ""

# ------------------------------------------------------------------
# 4. Swap: keep it small (8GB). 16GB wasted too much disk.
# ------------------------------------------------------------------
echo "--- Swap setup ---"
SWAP_GB_NOW=$(free -g | awk '/^Swap:/ {print $2}')
echo "Current swap: ${SWAP_GB_NOW} GB"

TARGET_SWAP=8
if [ "${SWAP_GB_NOW:-0}" -gt 10 ]; then
    echo "Shrinking swap to ${TARGET_SWAP}GB..."
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile
    sudo fallocate -l ${TARGET_SWAP}G /swapfile 2>/dev/null || \
        sudo dd if=/dev/zero of=/swapfile bs=1G count=${TARGET_SWAP} status=progress
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    echo "  swap now: $(free -h | awk '/^Swap:/ {print $2}')"
elif [ "${SWAP_GB_NOW:-0}" -eq 0 ]; then
    echo "Creating ${TARGET_SWAP}GB swap..."
    sudo fallocate -l ${TARGET_SWAP}G /swapfile 2>/dev/null || \
        sudo dd if=/dev/zero of=/swapfile bs=1G count=${TARGET_SWAP} status=progress
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    fi
    echo "  swap now: $(free -h | awk '/^Swap:/ {print $2}')"
else
    echo "  swap size OK (${SWAP_GB_NOW}GB)"
fi
echo ""

# ------------------------------------------------------------------
# 5. Sync the fixed scripts into place
# ------------------------------------------------------------------
echo "--- Syncing scripts ---"
if [ -d "${SRC}" ]; then
    mkdir -p "${DST}/local_manifests"
    for f in fix_env.sh build_twrp_tanzanite.sh flash_twrp.sh SOURCES.md README.md; do
        [ -f "${SRC}/${f}" ] && cp -f "${SRC}/${f}" "${DST}/${f}" && echo "  ok ${f}"
    done
    for f in tanzanite.xml tanzanite-nathan-kernel.xml; do
        [ -f "${SRC}/local_manifests/${f}" ] && cp -f "${SRC}/local_manifests/${f}" "${DST}/local_manifests/${f}" && echo "  ok local_manifests/${f}"
    done
    chmod +x "${DST}"/*.sh 2>/dev/null
else
    echo "  WARNING: ${SRC} not reachable. Is E: mounted at /mnt/e ?"
fi
echo ""

# ------------------------------------------------------------------
# 6. Final space report
# ------------------------------------------------------------------
echo "--- Final disk state ---"
df -h / | tail -1
AVAIL_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
echo ""
if [ "${AVAIL_GB}" -lt 35 ]; then
    echo "WARNING: only ${AVAIL_GB}GB free. Build needs ~35GB."
    echo "Consider: shrink swap, or move WSL to a bigger drive."
else
    echo "Space OK: ${AVAIL_GB}GB free"
fi
echo ""

echo "============================================================"
echo "  NEXT STEPS"
echo "============================================================"
echo ""
echo "1. If /etc/wsl.conf was changed, restart WSL from PowerShell:"
echo "     wsl --shutdown"
echo "     wsl -d Ubuntu"
echo ""
echo "2. Run diagnostics:"
echo "     cd ~/twrp_tanzanite && ./fix_env.sh"
echo ""
echo "3. Build:"
echo "     ./build_twrp_tanzanite.sh"
echo ""
