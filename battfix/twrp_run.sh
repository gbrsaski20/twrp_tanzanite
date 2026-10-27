#!/system/bin/sh
# =============================================================================
# twrp_run.sh - one-shot battery diagnostics for TWRP / OrangeFox (tanzanite)
#
# Run this INSIDE recovery, not in Android. It chains the two recovery-side
# scripts and saves everything to a single file you can pull afterwards:
#
#     probe_batt.sh   read-only inventory (never writes to any sysfs node)
#     test_uisoc.sh   the one experiment: write battery/uisoc, watch capacity
#
# WHY NOT battcheck.sh HERE
#   battcheck.sh compares the kernel's reported capacity against a real SOC
#   computed from OCV. In recovery the kernel is a DIFFERENT build from the one
#   Android boots, so its capacity value is not the number that kills the phone.
#   Run battcheck.sh in Android; run this here.
#
# SAFE: the only write is the same one the Android fuel-gauge daemon performs
# (battery/uisoc). The algorithm restores its own value on the next interrupt.
# =============================================================================

OUT=/tmp/twrp_batt_report.txt
HERE=$(dirname "$0")
BAT=/sys/class/power_supply/battery

echo "=============================================================="
echo " tanzanite recovery battery diagnostics"
echo "=============================================================="

# --- locate the payload -----------------------------------------------------
# Accept the scripts either next to this file, in /tmp, or in /sdcard.
if [ -f "$HERE/test_uisoc.sh" ]; then
	SRC=$HERE
elif [ -f /tmp/test_uisoc.sh ]; then
	SRC=/tmp
elif [ -f /sdcard/test_uisoc.sh ]; then
	SRC=/sdcard
else
	echo "ERROR: test_uisoc.sh not found."
	echo "       push it next to this script, e.g.:"
	echo "       adb push test_uisoc.sh probe_batt.sh twrp_run.sh /tmp/"
	exit 1
fi
echo "scripts in : $SRC"

# --- environment snapshot ---------------------------------------------------
echo "--- context ---"
echo "kernel     : $(cat /proc/version 2>/dev/null)"
echo "cmdline    : $(cat /proc/cmdline 2>/dev/null | cut -c1-120)"
echo "recovery   : $(getprop ro.twrp.version 2>/dev/null)$(getprop ro.fox.version 2>/dev/null)"
echo "capacity   : $(cat "$BAT/capacity" 2>/dev/null)   <- KERNEL value, not what TWRP shows"
echo "twrp shows : $(cat /tmp/batt/capacity 2>/dev/null) <- battfixd value (TW_CUSTOM_BATTERY_PATH)"
if ps 2>/dev/null | grep -q '[b]attfixd'; then
	echo "daemon     : battfixd RUNNING"
else
	echo "daemon     : battfixd NOT running (TWRP may show the kernel's raw value)"
fi
echo

# --- run the two stages -----------------------------------------------------
# tee keeps the output visible live AND appends it to the report. If the
# recovery has no tee, fall back to a plain append (nothing shown until the end).
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

: > "$OUT" 2>/dev/null || OUT=/tmp/twrp_batt_report.$$.txt

echo "=== tanzanite recovery battery diagnostics ===" >> "$OUT"
echo "kernel: $(cat /proc/version 2>/dev/null)" >> "$OUT"
echo >> "$OUT"

run probe_batt.sh
run test_rtc_ui_soc.sh
run test_uisoc.sh

# --- post-run state ---------------------------------------------------------
{
	echo
	echo "--- after the test ---"
	echo "capacity : $(cat "$BAT/capacity" 2>/dev/null)"
	echo "uisoc    : $(cat "$BAT/uisoc" 2>/dev/null) (usually unreadable: write-only)"
	echo "twrp     : $(cat /tmp/batt/capacity 2>/dev/null)"
	echo "daemon   : $(tail -n 3 /tmp/battfix.log 2>/dev/null)"
} | tee -a "$OUT" 2>/dev/null

echo
echo "=============================================================="
echo " report saved to $OUT"
echo " pull it with:  adb pull $OUT"
echo "=============================================================="
