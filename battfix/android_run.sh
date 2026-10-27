#!/system/bin/sh
# =============================================================================
# android_run.sh - battery diagnostics on the running Android system
#
# The counterpart of twrp_run.sh. Same two stages, but executed against the
# kernel Android actually boots - which is the kernel whose wrong capacity
# kills the phone, so this is the run that matters.
#
#     probe_batt.sh   read-only inventory (never writes to a sysfs node)
#     test_uisoc.sh   the experiment: write battery/uisoc, watch capacity
#
# REQUIRES ROOT. Android's / is read-only and battery/uisoc is mode 0200, so
# without root both the scratch dir and the write fail.
#
#   KernelSU / Magisk : su -c "sh /data/local/tmp/android_run.sh"
#   adb (rooted ROM)  : adb root; adb shell sh /data/local/tmp/android_run.sh
#
# Output: /sdcard/batt_android_report.txt (survives reboot, unlike /tmp)
# =============================================================================

HERE=$(dirname "$0")
BAT=/sys/class/power_supply/battery
OUT=/sdcard/batt_android_report.txt

echo "=============================================================="
echo " tanzanite battery diagnostics - Android"
echo "=============================================================="

# --- root check -------------------------------------------------------------
if [ "$(id -u 2>/dev/null)" != "0" ]; then
	echo "ERROR: not root (uid=$(id -u 2>/dev/null))."
	echo "       try: su -c \"sh $HERE/android_run.sh\""
	exit 1
fi
echo "uid        : 0 (root)"

# --- locate the payload -----------------------------------------------------
if [ -f "$HERE/test_uisoc.sh" ]; then
	SRC=$HERE
elif [ -f /data/local/tmp/test_uisoc.sh ]; then
	SRC=/data/local/tmp
elif [ -f /sdcard/test_uisoc.sh ]; then
	SRC=/sdcard
else
	echo "ERROR: test_uisoc.sh not found."
	echo "       adb push android_run.sh test_uisoc.sh probe_batt.sh /data/local/tmp/"
	exit 1
fi
echo "scripts in : $SRC"

# --- environment snapshot ---------------------------------------------------
echo "--- context ---"
echo "kernel     : $(cat /proc/version 2>/dev/null)"
echo "release    : $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
echo "rom        : $(getprop ro.build.display.id 2>/dev/null)"
echo "fingerprint: $(getprop ro.build.fingerprint 2>/dev/null)"
echo "capacity   : $(cat "$BAT/capacity" 2>/dev/null)   <- what Android reports"
echo "status     : $(cat "$BAT/status" 2>/dev/null)"
echo "voltage    : $(cat /sys/class/power_supply/bms/voltage_now 2>/dev/null) uV"
echo "current    : $(cat /sys/class/power_supply/bms/current_now 2>/dev/null) uA"
if [ -d /data/adb/ksu ] || [ -d /data/adb/ap ]; then
	echo "root mgr   : KernelSU/APatch present"
elif [ -d /data/adb/magisk ]; then
	echo "root mgr   : Magisk present"
else
	echo "root mgr   : none detected (su may still work)"
fi
echo

# --- run the two stages -----------------------------------------------------
run() {
	echo "##############################################################" >> "$OUT"
	echo "# $1" >> "$OUT"
	echo "##############################################################" >> "$OUT"
	if command -v tee >/dev/null 2>&1; then
		sh "$SRC/$1" 2>&1 | tee -a "$OUT"
	else
		sh "$SRC/$1" >> "$OUT" 2>&1
	fi
	echo
}

: > "$OUT" 2>/dev/null || OUT=/data/local/tmp/batt_android_report.txt

echo "=== tanzanite battery diagnostics - Android ===" >> "$OUT"
echo "kernel: $(cat /proc/version 2>/dev/null)" >> "$OUT"
echo "rom   : $(getprop ro.build.display.id 2>/dev/null)" >> "$OUT"
echo >> "$OUT"

run probe_batt.sh
run test_rtc_ui_soc.sh
run test_uisoc.sh

# --- post-run state ---------------------------------------------------------
{
	echo
	echo "--- after the test ---"
	echo "capacity : $(cat "$BAT/capacity" 2>/dev/null)"
	echo "status   : $(cat "$BAT/status" 2>/dev/null)"
} | tee -a "$OUT" 2>/dev/null

echo
echo "=============================================================="
echo " report saved to $OUT"
echo " pull it with:  adb pull $OUT"
echo "=============================================================="
