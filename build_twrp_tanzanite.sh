#!/usr/bin/env bash
#
# =============================================================================
# Build Unofficial TWRP Recovery for Xiaomi Redmi Note 14 4G (tanzanite)
# =============================================================================
#
# Device:    Xiaomi Redmi Note 14 4G (codename: tanzanite)
# Chipset:   MediaTek Helio G99 Ultra (MT6789)
# Recovery:  vendor_boot partition (V4 header)
# Manifest:  minimal-manifest-twrp/platform_manifest_twrp_aosp (twrp-12.1)
#
# Requirements:
#   - Ubuntu 22.04 LTS (or WSL2 Ubuntu on Windows)
#   - At least 16GB RAM (32GB recommended)
#   - At least 250GB free disk space
#   - Python 3.10+, Java 17, build-essential, etc.
#
# This script must be run on a Linux environment (Ubuntu native or WSL2)
# =============================================================================

set -e

# ============================ CONFIGURATION ============================
# TWRP manifest branch (only twrp-12.1 exists in minimal-manifest-twrp)
TWRP_BRANCH="twrp-12.1"
# TWRP manifest URL
MANIFEST_URL="https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git"
# Device codename
DEVICE="tanzanite"
# Build directory
BUILD_DIR="${HOME}/twrp-build"
# Number of parallel jobs for make (use all cores)
JOBS=$(nproc --all)
# Script directory (where this file lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ========================================================================

echo "============================================================"
echo "  Building TWRP for Xiaomi Redmi Note 14 4G (tanzanite)"
echo "  Branch: ${TWRP_BRANCH}"
echo "  Build dir: ${BUILD_DIR}"
echo "  Jobs: ${JOBS}"
echo "  Script dir: ${SCRIPT_DIR}"
echo "============================================================"

# ==================== STEP 0: Environment Checks ====================
echo ""
echo "[0/7] Checking environment..."

# Check if we're on a Linux system
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: This script must be run on Linux (Ubuntu or WSL2)."
    echo "If you're on Windows, use WSL2 with Ubuntu 22.04."
    echo ""
    echo "To set up WSL2:"
    echo "  1. Open PowerShell as Admin"
    echo "  2. wsl --install -d Ubuntu-22.04"
    echo "  3. Restart your computer"
    echo "  4. Open Ubuntu, set up your user, then run this script"
    exit 1
fi

# Check available disk space (need at least 200GB)
AVAILABLE_SPACE=$(df -BG "${HOME}" | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "${AVAILABLE_SPACE}" -lt 200 ]; then
    echo "WARNING: Only ${AVAILABLE_SPACE}GB free in ${HOME}."
    echo "TWRP build needs at least 200GB. WSL2 disk may need expansion."
    echo ""
    echo "To expand WSL2 disk:"
    echo "  1. In PowerShell (Admin): wsl --shutdown"
    echo "  2. diskpart"
    echo "  3. select vdisk file=\"C:\\Users\\<you>\\AppData\\Local\\Packages\\CanonicalGroupLimited.Ubuntu22.04*\\LocalState\\ext4.vhdx\""
    echo "  4. compact vdisk"
    echo "  5. Or expand: resize vdisk maximum=<size_in_MB>"
    echo ""
    echo "Alternatively, set BUILD_DIR to a different drive:"
    echo "  BUILD_DIR=/mnt/f/twrp-build ./build_twrp_tanzanite.sh"
    echo ""
    read -p "Continue anyway? (y/N): " CONTINUE
    if [ "${CONTINUE}" != "y" ] && [ "${CONTINUE}" != "Y" ]; then
        exit 1
    fi
fi

# Check RAM (need at least 16GB)
TOTAL_RAM=$(free -g | awk '/^Mem:/ {print $2}')
if [ "${TOTAL_RAM}" -lt 12 ]; then
    echo "WARNING: Only ${TOTAL_RAM}GB RAM detected. Minimum 16GB recommended."

    # Swap size: 8GB is enough. 16GB wastes too much disk on small drives.
    SWAP_SIZE_GB=8
    EXISTING_SWAP_GB=$(free -g | awk '/^Swap:/ {print $2}')

    if [ "${EXISTING_SWAP_GB:-0}" -ge "${SWAP_SIZE_GB}" ]; then
        echo "Swap already active: ${EXISTING_SWAP_GB}GB (OK, need ${SWAP_SIZE_GB}GB)"
    else
        echo "Creating ${SWAP_SIZE_GB}GB swap file..."
        sudo swapoff /swapfile 2>/dev/null || true
        sudo rm -f /swapfile
        sudo fallocate -l ${SWAP_SIZE_GB}G /swapfile 2>/dev/null || {
            echo "fallocate failed, trying dd..."
            sudo dd if=/dev/zero of=/swapfile bs=1G count=${SWAP_SIZE_GB} status=progress
        }
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
        fi
        echo "Swap enabled: $(free -h | awk '/^Swap:/ {print $2}')"
    fi

    # Warn if an oversized swapfile is eating disk
    if [ -f /swapfile ]; then
        SWAPFILE_GB=$(du -g /swapfile 2>/dev/null | awk '{print $1}')
        if [ "${SWAPFILE_GB:-0}" -gt 12 ]; then
            echo "NOTE: /swapfile is ${SWAPFILE_GB}GB - shrinking to ${SWAP_SIZE_GB}GB to free disk..."
            sudo swapoff /swapfile
            sudo rm -f /swapfile
            sudo fallocate -l ${SWAP_SIZE_GB}G /swapfile
            sudo chmod 600 /swapfile
            sudo mkswap /swapfile
            sudo swapon /swapfile
            echo "Swap now: $(free -h | awk '/^Swap:/ {print $2}')"
        fi
    fi

    # Reduce jobs to avoid OOM
    JOBS=$((JOBS / 2))
    if [ "${JOBS}" -lt 2 ]; then JOBS=2; fi
    echo "Reduced build jobs to ${JOBS} due to low RAM."
fi

# Space check AFTER swap setup (swap eats disk)
AVAIL_GB=$(df -BG "${HOME}" | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "${AVAIL_GB}" -lt 35 ]; then
    echo ""
    echo "ERROR: Only ${AVAIL_GB}GB free after swap setup."
    echo "TWRP build needs ~35GB free (source ~22GB + out ~13GB)."
    echo ""
    echo "Fix options:"
    echo "  1. Shrink swap:  sudo swapoff /swapfile && sudo rm /swapfile"
    echo "  2. Move WSL to bigger drive (F: has 65GB)"
    echo "  3. Free space on the drive hosting WSL"
    echo ""
    exit 1
fi
echo "Free space: ${AVAIL_GB}GB"

# ==================== STEP 1: Install Dependencies ====================
echo ""
echo "[1/7] Installing build dependencies..."

sudo apt-get update -y

# Detect Ubuntu version for package compatibility
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "0")
echo "Ubuntu version: ${UBUNTU_VERSION}"

# Base packages (compatible with both 22.04 and 24.04)
BASE_PACKAGES=" \
    git \
    gnupg \
    flex \
    bison \
    gperf \
    build-essential \
    zip \
    curl \
    zlib1g-dev \
    gcc-multilib \
    g++-multilib \
    libc6-dev-i386 \
    lib32z1-dev \
    libssl-dev \
    libstdc++6 \
    libxml2-utils \
    xsltproc \
    unzip \
    rsync \
    python3 \
    python3-pip \
    ccache \
    jq \
    bc \
    bsdmainutils \
    cpio \
    imagemagick \
    lz4 \
    openjdk-17-jdk \
    python-is-python3 \
    libncurses-dev \
    libreadline-dev \
    libgl1-mesa-dev \
    libwayland-dev"

# Version-specific packages
if [ "$(echo "${UBUNTU_VERSION} >= 24.04" | bc)" -eq 1 ]; then
    # Ubuntu 24.04 (noble/resolute) - uses t64 variants
    echo "Using Ubuntu 24.04 package names..."
    EXTRA_PACKAGES=" \
        libelf1t64 \
        libncurses-dev \
        libtinfo-dev \
        lib32ncurses-dev"
else
    # Ubuntu 22.04 (jammy) - legacy package names
    echo "Using Ubuntu 22.04 package names..."
    EXTRA_PACKAGES=" \
        libelf1 \
        libncurses5 \
        libtinfo5 \
        lib32ncurses-dev"
fi

echo "Installing packages..."
sudo apt-get install -y ${BASE_PACKAGES} ${EXTRA_PACKAGES}

# Ubuntu 24.04: create symlinks for legacy library names that AOSP expects
if [ "$(echo "${UBUNTU_VERSION} >= 24.04" | bc)" -eq 1 ]; then
    echo ""
    echo "Creating legacy library symlinks for AOSP compatibility..."
    # libncurses5 -> libncurses.so.6 (AOSP expects libncurses5)
    if [ -f /usr/lib/x86_64-linux-gnu/libncurses.so.6 ] && [ ! -f /usr/lib/x86_64-linux-gnu/libncurses.so.5 ]; then
        sudo ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5
        echo "  Linked libncurses.so.5 -> libncurses.so.6"
    fi
    if [ -f /usr/lib/x86_64-linux-gnu/libtinfo.so.6 ] && [ ! -f /usr/lib/x86_64-linux-gnu/libtinfo.so.5 ]; then
        sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
        echo "  Linked libtinfo.so.5 -> libtinfo.so.6"
    fi
    # 32-bit versions
    if [ -f /usr/lib32/libncurses.so.6 ] && [ ! -f /usr/lib32/libncurses.so.5 ]; then
        sudo ln -sf /usr/lib32/libncurses.so.6 /usr/lib32/libncurses.so.5
        echo "  Linked lib32/libncurses.so.5 -> libncurses.so.6"
    fi
    if [ -f /usr/lib32/libtinfo.so.6 ] && [ ! -f /usr/lib32/libtinfo.so.5 ]; then
        sudo ln -sf /usr/lib32/libtinfo.so.6 /usr/lib32/libtinfo.so.5
        echo "  Linked lib32/libtinfo.so.5 -> libtinfo.so.6"
    fi
    # libelf1 -> libelf1t64
    if [ -f /usr/lib/x86_64-linux-gnu/libelf.so.1 ] && [ ! -L /usr/lib/x86_64-linux-gnu/libelf.so.1t64 ]; then
        echo "  libelf already available as libelf.so.1"
    fi
    echo "Legacy symlinks done."
fi

# Verify Python 3
python3 --version || { echo "ERROR: Python 3 is required"; exit 1; }

# Verify Java
java -version || { echo "ERROR: Java is required"; exit 1; }

# Configure git (required by repo)
if [ -z "$(git config --global user.name)" ]; then
    git config --global user.name "TWRP Builder"
fi
if [ -z "$(git config --global user.email)" ]; then
    git config --global user.email "builder@localhost"
fi

# Install repo tool
if ! command -v repo &> /dev/null; then
    echo "Installing repo tool..."
    mkdir -p "${HOME}/bin"
    curl -sL https://storage.googleapis.com/git-repo-downloads/repo -o "${HOME}/bin/repo"
    chmod +x "${HOME}/bin/repo"
    export PATH="${HOME}/bin:${PATH}"
    # Persist for future sessions
    if ! grep -q '${HOME}/bin' "${HOME}/.bashrc"; then
        echo 'export PATH="${HOME}/bin:${PATH}"' >> "${HOME}/.bashrc"
    fi
fi

echo "Dependencies installed."

# ==================== STEP 2: Initialize TWRP Source Tree ====================
echo ""
echo "[2/7] Initializing TWRP source tree..."

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Check if already initialized
if [ -d "${BUILD_DIR}/.repo" ]; then
    echo "Repo already initialized. Reusing existing source tree."
    echo "To start fresh, delete ${BUILD_DIR} and re-run."
else
    echo "Initializing repo with TWRP ${TWRP_BRANCH} manifest..."
    repo init --depth=1 \
        -u "${MANIFEST_URL}" \
        -b "${TWRP_BRANCH}" \
        -g default,-mips,-darwin,-notdefault
fi

# ==================== STEP 3: Add Local Manifests ====================
echo ""
echo "[3/7] Adding local manifest for tanzanite..."

mkdir -p "${BUILD_DIR}/.repo/local_manifests"

# Manifest selection: default is puuuuh kernel (HyperOS-patched touchscreen).
# Override with: MANIFEST=tanzanite-nathan-kernel.xml ./build_twrp_tanzanite.sh
MANIFEST_FILE="${MANIFEST:-tanzanite.xml}"

if [ -f "${SCRIPT_DIR}/local_manifests/${MANIFEST_FILE}" ]; then
    # Remove any other tanzanite manifest to avoid duplicate project entries
    rm -f "${BUILD_DIR}"/.repo/local_manifests/tanzanite*.xml
    cp -v "${SCRIPT_DIR}/local_manifests/${MANIFEST_FILE}" \
          "${BUILD_DIR}/.repo/local_manifests/${MANIFEST_FILE}"
elif [ -f "${BUILD_DIR}/.repo/local_manifests/${MANIFEST_FILE}" ]; then
    echo "Local manifest already present."
else
    echo "ERROR: local_manifests/${MANIFEST_FILE} not found!"
    echo "Available manifests:"
    ls -1 "${SCRIPT_DIR}/local_manifests/" 2>/dev/null
    exit 1
fi

echo "Local manifest installed: ${MANIFEST_FILE}"
echo "Contents:"
cat "${BUILD_DIR}/.repo/local_manifests/${MANIFEST_FILE}"

# ==================== STEP 4: Sync Source Code ====================
echo ""
echo "[4/7] Syncing source code (this will take a while)..."
echo "Downloading ~15-20GB of source code..."

# Retry sync up to 3 times on failure
SYNC_SUCCESS=0
for ATTEMPT in 1 2 3; do
    echo ""
    echo "Sync attempt ${ATTEMPT}/3..."
    if repo sync -c \
        -j${JOBS} \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        --optimized-fetch \
        --prune; then
        SYNC_SUCCESS=1
        break
    else
        echo "Sync attempt ${ATTEMPT} failed. Retrying in 10s..."
        sleep 10
        # Reduce jobs on retry
        JOBS=$((JOBS > 4 ? JOBS / 2 : JOBS))
        echo "Reduced jobs to ${JOBS}."
    fi
done

if [ ${SYNC_SUCCESS} -eq 0 ]; then
    echo "ERROR: repo sync failed after 3 attempts."
    echo "Try running manually: repo sync -c -j4 --force-sync"
    exit 1
fi

echo "Source sync complete!"

# ==================== STEP 5: Setup Build Environment ====================
echo ""
echo "[5/7] Setting up build environment..."

export ALLOW_MISSING_DEPENDENCIES=true
export ALLOW_MISSING_DEPENDENCIES_ON_RECOVERY=true
export TW_DEVICE_VERSION="A14_Tanzanite"
export LC_ALL="C.UTF-8"

# ccache: default max is 50GB which will fill a small disk. Cap it tightly.
# Set USE_CCACHE=0 in env to disable entirely (saves the most space).
if [ "${USE_CCACHE:-1}" = "1" ]; then
    export USE_CCACHE=1
    export CCACHE_EXEC=$(command -v ccache)
    ccache -M 5G >/dev/null 2>&1 || true
    echo "ccache enabled, capped at 5GB"
else
    export USE_CCACHE=0
    unset CCACHE_EXEC
    echo "ccache disabled (USE_CCACHE=0)"
fi

# Source the build environment
cd "${BUILD_DIR}"
source build/envsetup.sh

# Lunch the target
echo ""
echo "Lunching twrp_${DEVICE}-eng..."
lunch twrp_${DEVICE}-eng

# ==================== STEP 6: Build vendor_boot Recovery Image ====================
echo ""
echo "[6/7] Building TWRP vendor_boot image..."
echo "This will take 30-90 minutes depending on your machine."
echo ""

# Retry build up to 3 times (AOSP builds sometimes fail on transient errors)
BUILD_SUCCESS=0
for ATTEMPT in 1 2 3; do
    echo ""
    echo "Build attempt ${ATTEMPT}/3..."
    if mka vendorbootimage -j${JOBS}; then
        BUILD_SUCCESS=1
        break
    else
        echo ""
        echo "Build attempt ${ATTEMPT} failed."
        if [ ${ATTEMPT} -lt 3 ]; then
            echo "Retrying with fewer jobs..."
            JOBS=$((JOBS > 4 ? JOBS / 2 : 4))
            echo "New jobs count: ${JOBS}"
            # Re-source environment (some state may be lost)
            source build/envsetup.sh
            lunch twrp_${DEVICE}-eng
            sleep 5
        fi
    fi
done

if [ ${BUILD_SUCCESS} -eq 0 ]; then
    echo ""
    echo "============================================================"
    echo "  BUILD FAILED after 3 attempts"
    echo "============================================================"
    echo ""
    echo "Common fixes:"
    echo "  1. Out of memory: sudo fallocate -l 16G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
    echo "  2. Disk full: check with df -h"
    echo "  3. Missing deps: export ALLOW_MISSING_DEPENDENCIES=true"
    echo "  4. Try fewer jobs: mka vendorbootimage -j4"
    echo "  5. Clean build: make clean && mka vendorbootimage"
    echo ""
    echo "Paste the error output above and we'll fix it together."
    exit 1
fi

# ==================== STEP 7: Locate Output ====================
echo ""
echo "[7/7] Build complete! Locating output..."

# Find the built vendor_boot.img
OUTPUT_IMG=$(find "${BUILD_DIR}/out" -name "vendor_boot.img" -type f 2>/dev/null | head -1)

if [ -z "${OUTPUT_IMG}" ]; then
    echo ""
    echo "Searching for output image..."
    find "${BUILD_DIR}/out" -name "*.img" -type f 2>/dev/null
    echo ""
    echo "WARNING: vendor_boot.img not found in expected location."
    echo "Searching broader..."
    OUTPUT_IMG=$(find "${BUILD_DIR}/out" -name "vendor_boot*.img" -type f 2>/dev/null | head -1)
    if [ -z "${OUTPUT_IMG}" ]; then
        echo "ERROR: Could not find vendor_boot.img anywhere in output."
        exit 1
    fi
fi

echo ""
echo "============================================================"
echo "  BUILD SUCCESSFUL!"
echo "============================================================"
echo ""
echo "Output image: ${OUTPUT_IMG}"
echo "Image size: $(ls -lh "${OUTPUT_IMG}" | awk '{print $5}')"
echo ""

# Copy to script directory for easy access
COPY_DEST="${SCRIPT_DIR}/vendor_boot_twrp_tanzanite.img"
cp -v "${OUTPUT_IMG}" "${COPY_DEST}"
echo "Copied to: ${COPY_DEST}"

# If running in WSL2, also copy to Windows accessible path
if [ -d "/mnt/f/Tool RedmiNote14" ]; then
    WIN_COPY="/mnt/f/Tool RedmiNote14/vendor_boot_twrp_tanzanite.img"
    cp -v "${OUTPUT_IMG}" "${WIN_COPY}"
    echo "Also copied to Windows: ${WIN_COPY}"
    echo "  (Accessible at: F:\\Tool RedmiNote14\\vendor_boot_twrp_tanzanite.img)"
fi

echo ""
echo "============================================================"
echo "  NEXT STEPS"
echo "============================================================"
echo ""
echo "To flash this to your device:"
echo "  1. Boot to fastboot mode:   adb reboot bootloader"
echo "  2. Flash the recovery:      fastboot flash vendor_boot ${COPY_DEST}"
echo "  3. Reboot to recovery:      fastboot reboot recovery"
echo ""
echo "Or on Windows (from F:\\Tool RedmiNote14\\):"
echo "  flash_twrp.bat vendor_boot_twrp_tanzanite.img"
echo ""
echo "If TWRP has bugs, grab logs and we'll fix together:"
echo "  adb shell dmesg > dmesg.log"
echo "  adb shell logcat > logcat.log"
echo ""
echo "See flash_instructions.txt for detailed flashing steps."
