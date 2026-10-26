#!/system/bin/sh
# =============================================================================
# probe_batt.sh - find a writable battery interface on tanzanite (MT6789)
#
# WHY
#   The recovery kernel blindly trusts the RTC spare FG register on a
#   RECOVERY_BOOT, and while a charger is present it runs
#   mt_battery_100Percent_tracking_check() which pushes UI_SOC up to 100 and
#   then stores that 100 back into the RTC spare register. Android inherits it.
#   That is why using TWRP with the USB cable plugged in corrupts the gauge.
#
#   Layer 1 (battfixd.sh) only fixes what TWRP DISPLAYS. To fix it for real we
#   need to either write the correct SOC into the kernel, or stop the kernel
#   from writing the wrong one. This script answers "is that even possible
#   from userspace on this build?" - it does not change anything.
#
# HOW TO RUN (in TWRP, USB may stay plugged - that is the whole point)
#   adb push probe_batt.sh /tmp/pb.sh
#   adb shell sh /tmp/pb.sh
#   adb pull /sdcard/battprobe.txt
#
#   The only mutation is a NO-OP write in section 5: it writes back the value
#   it just read, on nodes that are supposed to be read-only. If a node turns
#   out to be writable that is exactly the discovery we want, and writing the
#   same value back cannot change anything.
# =============================================================================

OUT=/sdcard/battprobe.txt
if ! ( : > "$OUT" ) 2>/dev/null; then
	OUT=/tmp/battprobe.txt
	: > "$OUT" 2>/dev/null
fi

{
	echo "=============================================================="
	echo " battprobe - tanzanite battery interface discovery"
	echo " time: $(date 2>/dev/null)"
	echo "=============================================================="

	echo
	echo "--- 1. kernel ---"
	uname -a 2>/dev/null
	cat /proc/version 2>/dev/null

	echo
	echo "--- 2. boot args (boot_mode / bootreason / charger) ---"
	cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -i -E 'boot|charg|androidboot|mtk'
	echo
	echo "raw cmdline:"
	cat /proc/cmdline 2>/dev/null

	echo
	echo "--- 3. power_supply nodes (perms + value) ---"
	for d in /sys/class/power_supply/*; do
		[ -d "$d" ] || continue
		echo
		echo "### $d"
		for f in "$d"/*; do
			[ -f "$f" ] || continue
			printf '  %-52s %s\n' "$(basename "$f")" "$(ls -l "$f" 2>/dev/null | cut -d' ' -f1)"
			printf '      = %s\n' "$(cat "$f" 2>/dev/null | head -c 100 | tr '\n' ' ')"
		done
	done

	echo
	echo "--- 4. vendor proc / debug interfaces ---"
	for n in /proc/mtk_battery_cmd /proc/mtk_battery_cmd/battery_cmd /proc/battery_cmd \
		/proc/mtk_charger /proc/mtk_charger_cmd /proc/mtk_charger/charger_cmd \
		/proc/rtc /proc/rtc_spare /proc/rtc_spare_fg /proc/driver/rtc \
		/proc/fuel_gauge /proc/mtk_gauge /proc/battery_log /proc/mtk_battery_log
	do
		if [ -e "$n" ]; then
			echo "  FOUND  $(ls -l "$n" 2>/dev/null)"
			echo "    head: $(head -c 400 "$n" 2>/dev/null | tr '\n' '|')"
		else
			echo "  missing $n"
		fi
	done

	echo
	echo "--- 5. WRITE TEST (no-op: writes the value it just read) ---"
	echo "    a WRITABLE result here is the discovery we are looking for"
	wt() {
		n=$1
		if [ ! -e "$n" ]; then
			echo "  SKIP   (missing) $n"
			return
		fi
		cur=$(cat "$n" 2>/dev/null | tr -d ' \r\n\t')
		echo "  node   $n"
		echo "  perms  $(ls -l "$n" 2>/dev/null)"
		echo "  value  $cur"
		if [ -z "$cur" ]; then
			echo "  RESULT unreadable, skipped"
			return
		fi
		if echo "$cur" > "$n" 2>/tmp/.wterr; then
			echo "  RESULT *** WRITABLE ***"
		else
			echo "  RESULT read-only -> $(cat /tmp/.wterr 2>/dev/null)"
		fi
	}
	wt /sys/class/power_supply/battery/capacity
	wt /sys/class/power_supply/bms/capacity
	rm -f /tmp/.wterr 2>/dev/null

	echo
	echo "--- 6. battery platform devices ---"
	ls -d /sys/devices/platform/*batt* /sys/devices/platform/*charg* \
		/sys/devices/platform/*gauge* 2>/dev/null

	echo
	echo "--- 7. loaded modules (is the gauge built-in or a .ko?) ---"
	cat /proc/modules 2>/dev/null | grep -i -E 'batt|charg|gauge|rtc'
	echo
	echo "  lsmod present: $(command -v lsmod 2>/dev/null || echo no)"

	echo
	echo "--- 8. module parameters (tunables) ---"
	for m in /sys/module/*batt* /sys/module/*charg* /sys/module/*gauge*; do
		[ -d "$m" ] || continue
		[ -d "$m/parameters" ] || continue
		echo "### $m/parameters"
		for pf in "$m"/parameters/*; do
			[ -f "$pf" ] || continue
			printf '  %-40s %s  [%s]\n' "$(basename "$pf")" \
				"$(cat "$pf" 2>/dev/null | tr '\n' ' ')" \
				"$(ls -l "$pf" 2>/dev/null | cut -d' ' -f1)"
		done
	done

	echo
	echo "--- 9. RTC device ---"
	ls -l /dev/rtc* 2>/dev/null
	echo "  (no /proc/driver/rtc on MTK is normal)"

	echo
	echo "--- 10. dmesg: gauge / rtc_spare / charger ---"
	dmesg 2>/dev/null | grep -i -E 'rtc_spare|fg_soc|gFG|battery_meter|gauge|charger_exist|100Percent|UI_SOC' | tail -80

	echo
	echo "--- 11. current readings ---"
	for f in /sys/class/power_supply/battery/capacity \
		/sys/class/power_supply/battery/status \
		/sys/class/power_supply/battery/voltage_now \
		/sys/class/power_supply/battery/current_now \
		/sys/class/power_supply/bms/voltage_now \
		/sys/class/power_supply/bms/current_now \
		/sys/class/power_supply/bms/capacity
	do
		[ -e "$f" ] && echo "  $f = $(cat "$f" 2>/dev/null | tr -d ' \r\n')"
	done
	echo "  our daemon (/tmp/batt/capacity) = $(cat /tmp/batt/capacity 2>/dev/null)"

	echo
	echo "--- 12. is adb-over-wifi possible in this build? ---"
	echo "  adbd path: $(command -v adbd 2>/dev/null || echo 'not in PATH')"
	echo "  service.adb.tcp.port = $(getprop service.adb.tcp.port 2>/dev/null)"
	echo "  wifi interface:"
	ip link 2>/dev/null | grep -E '^[0-9]+: (wlan|wifi)' 
	echo "  (if a wlan interface exists, adb over wifi is a real option)"

	echo
	echo "=============================================================="
	echo " done -> $OUT"
	echo "=============================================================="
} > "$OUT" 2>&1

cat "$OUT"
