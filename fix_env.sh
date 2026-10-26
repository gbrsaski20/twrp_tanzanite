#!/usr/bin/env bash
#
# =============================================================================
# Diagnose + fix TWRP build environment problems
# =============================================================================
# Usage:
#   chmod +x fix_env.sh
#   ./fix_env.sh              # diagnose only
#   ./fix_env.sh --clean      # clean corrupted .repo and re-sync
# =============================================================================

BUILD_DIR="${HOME}/twrp-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================================"
echo "  TWRP build environment diagnostics"
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# 1. Where is the WSL disk?
# ------------------------------------------------------------------
echo "--- 1. Disk location and space ---"
df -h / | tee /tmp/.dfout
echo ""
ROOT_AVAIL_KB=$(df -k / | awk 'NR==2 {print $4}')
ROOT_AVAIL_GB=$((ROOT_AVAIL_KB / 1024 / 1024))
echo "Root filesystem free: ${ROOT_AVAIL_GB} GB"
echo ""

# Detect if running from C: (WSL not moved)
if mount | grep -qE "^/dev/sd[a-z] on / type ext4"; then
    ok "Root is a real ext4 device (WSL disk, not /mnt/c)"
else
    warn "Root mount looks unusual - check 'mount | grep \" / \"'"
fi

# ------------------------------------------------------------------
# 2. Read-only check
# ------------------------------------------------------------------
echo "--- 2. Write test ---"
if touch "${HOME}/.write_test" 2>/dev/null; then
    rm -f "${HOME}/.write_test"
    ok "Home is writable"
else
    err "HOME IS READ-ONLY - disk is full!"
    echo ""
    echo "  This is why repo sync failed with 'Read-only file system'."
    echo "  Fix from Windows (PowerShell as Admin):"
    echo ""
    echo "    wsl --shutdown"
    echo ""
    echo "  Then either:"
    echo "    A) Free space on the drive hosting WSL, OR"
    echo "    B) Move WSL to a bigger drive (see move_wsl_to_E.bat)"
    echo ""
    echo "  After freeing space, restart WSL and run this script again."
    exit 1
fi
echo ""

# ------------------------------------------------------------------
# 3. Space requirement estimate
# ------------------------------------------------------------------
echo "--- 3. Space requirement ---"
NEEDED=45   # GB: base + source + out (swap excluded, checked separately)
echo "Estimated need for source + out: ~${NEEDED} GB (excluding swap)"
SWAP_GB=$(free -g | awk '/^Swap:/ {print $2}')
echo "Current swap: ${SWAP_GB} GB"
echo ""
if [ "${ROOT_AVAIL_GB}" -lt $((NEEDED + SWAP_GB)) ]; then
    err "NOT ENOUGH SPACE"
    echo "  Available: ${ROOT_AVAIL_GB} GB"
    echo "  Needed:    ~$((NEEDED + SWAP_GB)) GB (${NEEDED} GB build + ${SWAP_GB} GB swap)"
    echo ""
    echo "  Recommended actions (pick one or more):"
    echo "    1. Reduce swap to 8GB:"
    echo "         sudo swapoff /swapfile"
    echo "         sudo rm /swapfile"
    echo "         sudo fallocate -l 8G /swapfile"
    echo "         sudo chmod 600 /swapfile"
    echo "         sudo mkswap /swapfile"
    echo "         sudo swapon /swapfile"
    echo "    2. Move WSL to a bigger drive (F: has 65GB free)"
    echo "    3. Disable ccache (saves ~10GB): export USE_CCACHE=0"
    exit 1
else
    ok "Space looks sufficient"
fi
echo ""

# ------------------------------------------------------------------
# 4. Check .repo integrity
# ------------------------------------------------------------------
echo "--- 4. .repo integrity ---"
if [ ! -d "${BUILD_DIR}/.repo" ]; then
    warn "No .repo found at ${BUILD_DIR} - fresh start needed"
    NEED_CLEAN=1
else
    BROKEN=0

    # Check for zero-length or malformed packed-refs
    while IFS= read -r f; do
        if [ ! -s "$f" ]; then
            warn "Empty packed-refs: $f"
            BROKEN=1
        elif ! tail -c 1 "$f" | od -An -c | grep -q '\\n'; then
            warn "Unterminated packed-refs (missing newline): $f"
            BROKEN=1
        fi
    done < <(find "${BUILD_DIR}/.repo/projects" -name packed-refs 2>/dev/null)

    # Check for missing git dirs referenced by repo
    MISSING_GIT=0
    if [ -d "${BUILD_DIR}/.repo/projects" ]; then
        while IFS= read -r d; do
            if [ ! -f "$d/HEAD" ] && [ ! -f "$d/config" ]; then
                MISSING_GIT=$((MISSING_GIT + 1))
            fi
        done < <(find "${BUILD_DIR}/.repo/projects" -maxdepth 8 -name "*.git" -type d 2>/dev/null)
    fi

    if [ "${MISSING_GIT}" -gt 0 ]; then
        warn "Found ${MISSING_GIT} broken/empty git dirs"
        BROKEN=1
    fi

    if [ "${BROKEN}" -eq 1 ]; then
        err ".repo IS CORRUPTED - clean re-sync required"
        NEED_CLEAN=1
    else
        ok ".repo looks intact"
        NEED_CLEAN=0
    fi
fi
echo ""

# ------------------------------------------------------------------
# 5. Device tree presence
# ------------------------------------------------------------------
echo "--- 5. Device tree ---"
if [ -d "${BUILD_DIR}/device/xiaomi/tanzanite" ]; then
    ok "device/xiaomi/tanzanite exists"
    if [ -f "${BUILD_DIR}/device/xiaomi/tanzanite/BoardConfig.mk" ]; then
        ok "BoardConfig.mk present"
    else
        warn "BoardConfig.mk missing"
    fi
else
    warn "device/xiaomi/tanzanite missing"
fi

if [ -d "${BUILD_DIR}/device/xiaomi/tanzanite-kernel" ]; then
    ok "device/xiaomi/tanzanite-kernel exists"
    for f in Image.gz dtbo.img modules.load.recovery; do
        if [ -f "${BUILD_DIR}/device/xiaomi/tanzanite-kernel/$f" ]; then
            ok "  $f present"
        else
            warn "  $f MISSING"
        fi
    done
else
    warn "device/xiaomi/tanzanite-kernel missing"
fi
echo ""

# ------------------------------------------------------------------
# Summary / action
# ------------------------------------------------------------------
echo "============================================================"
if [ "${NEED_CLEAN}" = "1" ]; then
    echo "  ACTION NEEDED: clean re-sync"
    echo "============================================================"
    echo ""
    echo "Run:  ./fix_env.sh --clean"
    echo ""
else
    echo "  ENVIRONMENT OK"
    echo "============================================================"
    echo ""
    echo "Run the build:"
    echo "  cd ~/twrp_tanzanite && ./build_twrp_tanzanite.sh"
    echo ""
fi

# ------------------------------------------------------------------
# Clean mode
# ------------------------------------------------------------------
if [ "$1" = "--clean" ]; then
    echo ""
    echo "=== Cleaning corrupted .repo ==="
    cd "${BUILD_DIR}" || exit 1

    # Keep only .repo/manifests + .repo/repo to avoid full re-init
    if [ -d .repo ]; then
        echo "Removing .repo/projects and .repo/project-objects..."
        rm -rf .repo/projects .repo/project-objects
        rm -rf .repo/local_manifests/*.xml
        echo "Done."
    fi

    # Remove partially checked-out projects (keep .repo)
    echo "Removing checked-out source (keeping .repo)..."
    find . -maxdepth 1 -mindepth 1 ! -name '.repo' -exec rm -rf {} + 2>/dev/null
    echo "Done."
    echo ""
    echo "=== Re-running build script (will re-init local manifest + sync) ==="
    echo ""
    cd "${SCRIPT_DIR}" || exit 1
    exec ./build_twrp_tanzanite.sh
fi
