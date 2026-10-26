#!/usr/bin/env bash
#
# Quick flash script for TWRP vendor_boot on tanzanite
# Usage: ./flash_twrp.sh [path/to/vendor_boot.img]
#
# If no path given, looks for the image in common locations.

set -e

# Platform tools path on this machine
PLATFORM_TOOLS="/f/Tool RedmiNote14/platform-tools"
FASTBOOT="${PLATFORM_TOOLS}/fastboot.exe"
ADB="${PLATFORM_TOOLS}/adb.exe"

# Image path (from argument or search)
if [ -n "$1" ]; then
    IMG="$1"
else
    # Try common locations
    for candidate in \
        "vendor_boot_twrp_tanzanite.img" \
        "vendor_boot.img" \
        "/f/Tool RedmiNote14/vendor_boot_twrp_tanzanite.img" \
        "/f/Tool RedmiNote14/Rom + recovery/vendor_boot_twrp_tanzanite.img" \
        "$(pwd)/vendor_boot_twrp_tanzanite.img"; do
        if [ -f "$candidate" ]; then
            IMG="$candidate"
            break
        fi
    done
fi

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "ERROR: vendor_boot image not found!"
    echo ""
    echo "Usage: $0 <path/to/vendor_boot.img>"
    echo ""
    echo "Download the image from your GitHub Actions run artifacts,"
    echo "then pass the path to this script."
    exit 1
fi

echo "============================================================"
echo "  Flash TWRP vendor_boot for tanzanite"
echo "  Image: ${IMG}"
echo "  Size:  $(ls -lh "${IMG}" | awk '{print $5}')"
echo "============================================================"
echo ""

# Check if device is in fastboot
echo "Checking for fastboot device..."
if ! "${FASTBOOT}" devices | grep -q "fastboot"; then
    echo "Device not in fastboot mode."
    echo ""
    echo "Trying adb reboot bootloader..."
    if "${ADB}" devices | grep -q "device\|recovery"; then
        "${ADB}" reboot bootloader
        echo "Waiting for fastboot mode..."
        sleep 10
    else
        echo "ERROR: Device not connected via ADB or Fastboot."
        echo ""
        echo "Manual steps:"
        echo "  1. Power off phone"
        echo "  2. Hold Volume Down + Power together"
        echo "  3. Release when you see the fastboot logo"
        echo "  4. Run this script again"
        exit 1
    fi
fi

# Verify device is detected
echo "Fastboot devices:"
"${FASTBOOT}" devices

# Backup current vendor_boot (safety measure)
echo ""
echo "Backing up current vendor_boot..."
"${FASTBOOT}" getvar vendor_boot:partition-size 2>/dev/null || true

# Flash
echo ""
echo "Flashing vendor_boot..."
"${FASTBOOT}" flash vendor_boot "${IMG}"

echo ""
echo "============================================================"
echo "  FLASH SUCCESSFUL!"
echo "============================================================"
echo ""
echo "Booting to recovery..."
echo "  fastboot reboot recovery"
echo ""
"${FASTBOOT}" reboot recovery 2>/dev/null || {
    echo "Could not auto-reboot. Manual:"
    echo "  Hold Volume Up + Power to boot to TWRP"
}

echo ""
echo "If TWRP doesn't boot or has bugs, report back with:"
echo "  adb shell dmesg > dmesg.log"
echo "  adb shell logcat > logcat.log"
echo "We'll fix bugs together."
