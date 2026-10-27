#!/system/bin/sh
# =============================================================================
# oc_probe.sh - inventory of everything that can be tuned on THIS kernel
#
# WHY THIS EXISTS
#   "Overclock" needs two different answers on MT6789, and they are not the
#   same problem:
#
#     CPU  - the frequency/voltage table is compiled into the kernel
#            (mt_cpufreq / cpuhvfs). Userspace cannot add a row to it.
#            Best case: you can pin the existing maximum, not exceed it.
#
#     GPU  - the table lives in the kernel too, BUT the driver exports a
#            write path that accepts an arbitrary freq/volt pair:
#                /proc/gpufreqv2/fix_custom_freq_volt   ("<KHz> <mV*100>")
#            The driver only validates against hard limits, not against the
#            table, so a value ABOVE the stock maximum is accepted. That is a
#            real overclock, and it needs no kernel rebuild.
#
#   This script changes NOTHING. It reports which of the two is available on
#   the kernel you are actually running, because the nodes come from the
#   kernel build (HayaseYuuka), not from the ROM.
#
# USAGE
#   sh oc_probe.sh
#   sh oc_probe.sh > /sdcard/oc_probe.txt
#
# Runs in Android (needs root) and in recovery.
# =============================================================================

PS=/sys/class/power_supply

# --- helpers -----------------------------------------------------------------
rd() { cat "$1" 2>/dev/null; }

hr() {
	echo "--------------------------------------------------------------"
}

sec() {
	echo
	echo "=============================================================="
	echo "$1"
	echo "=============================================================="
}

isnum() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# --- root --------------------------------------------------------------------
UID_NOW=$(id -u 2>/dev/null)
if [ "$UID_NOW" != "0" ]; then
	echo "FAIL - not root (uid=$UID_NOW). Run with su or adb root."
	exit 1
fi

echo "=============================================================="
echo "OC probe - what can be tuned on this kernel"
echo "=============================================================="

# --- 1. identity -------------------------------------------------------------
sec "1. kernel"
echo "uname    : $(uname -r 2>/dev/null)"
echo "version  : $(rd /proc/version)"
echo "soc      : $(rd /proc/device-tree/model | tr -d '\000')"
echo "platform : $(rd /proc/device-tree/compatible | tr -d '\000' | tr '\000' ' ')"
echo "selinux  : $(getenforce 2>/dev/null)"
if [ -d /data/adb/ksu ] || [ -d /data/adb/ap ]; then
	echo "root mgr : KernelSU detected"
elif [ -d /data/adb/magisk ]; then
	echo "root mgr : Magisk detected"
fi

# --- 2. CPU ------------------------------------------------------------------
sec "2. CPU frequency domains"
FOUND_POLICY=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -d "$p" ] || continue
	FOUND_POLICY=1
	echo
	echo "--- $(basename "$p")  cpus: $(rd "$p/related_cpus")"
	echo "  cur        : $(rd "$p/scaling_cur_freq") KHz"
	echo "  min / max  : $(rd "$p/scaling_min_freq") / $(rd "$p/scaling_max_freq") KHz"
	echo "  hw limits  : $(rd "$p/cpuinfo_min_freq") / $(rd "$p/cpuinfo_max_freq") KHz"
	echo "  governor   : $(rd "$p/scaling_governor")   available: $(rd "$p/scaling_available_governors")"
	echo "  available  :"
	echo "    $(rd "$p/scaling_available_frequencies")"
done
if [ "$FOUND_POLICY" = "0" ]; then
	echo "  no /sys/devices/system/cpu/cpufreq/policy* - cpufreq sysfs absent"
fi

# MTK-specific CPU DVFS controls, if the kernel exposes them
echo
echo "--- MTK CPU DVFS nodes"
for n in /proc/ppm /proc/cpufreq /proc/cpuhvfs /sys/kernel/ppm; do
	if [ -e "$n" ]; then
		echo "  $n  -> PRESENT"
		ls "$n" 2>/dev/null | sed 's/^/      /'
	else
		echo "  $n  -> -"
	fi
done

# /proc/cpuhvfs is the one that matters: phyclk and phyvolt are RW and write
# straight to the PLL and the regulator, bypassing the DVFS table.
if [ -d /proc/cpuhvfs ]; then
	echo
	echo "--- /proc/cpuhvfs detail (the CPU OC hook)"
	for f in phyclk phyvolt usram_repo; do
		if [ -e "/proc/cpuhvfs/$f" ]; then
			echo "  $f  perms: $(ls -l "/proc/cpuhvfs/$f" 2>/dev/null | cut -c1-10)"
			rd "/proc/cpuhvfs/$f" | head -6 | sed 's/^/      /'
		else
			echo "  $f  -> -"
		fi
	done
	echo "  (phyclk write format: '<cluster> <freq_KHz>')"
	echo "  (phyvolt write format: '<cluster> <volt_uV>')"
fi

# --- 3. GPU ------------------------------------------------------------------
sec "3. GPU frequency control"
GPUDIR=
if [ -d /proc/gpufreqv2 ]; then
	GPUDIR=/proc/gpufreqv2
	echo "driver   : gpufreq v2  ($GPUDIR)"
elif [ -d /proc/gpufreq ]; then
	GPUDIR=/proc/gpufreq
	echo "driver   : gpufreq v1  ($GPUDIR)"
else
	echo "driver   : NONE - neither /proc/gpufreqv2 nor /proc/gpufreq exists"
	echo "           GPU overclock is not exposed on this kernel build."
fi

if [ -n "$GPUDIR" ]; then
	echo
	echo "--- entries in $GPUDIR"
	ls "$GPUDIR" 2>/dev/null | sed 's/^/    /'

	echo
	echo "--- current fixed freq/volt (0 0 means DVFS is running normally)"
	echo "    $(rd "$GPUDIR/fix_custom_freq_volt")"

	echo
	echo "--- status"
	rd "$GPUDIR/gpufreq_status" | head -14 | sed 's/^/    /'

	echo
	echo "--- working OPP table (top 8 = highest clocks)"
	rd "$GPUDIR/gpu_working_opp_table" | head -8 | sed 's/^/    /'

	echo
	echo "--- signed OPP table (top 8)"
	rd "$GPUDIR/gpu_signed_opp_table" | head -8 | sed 's/^/    /'

	echo
	echo "--- current limit table"
	rd "$GPUDIR/limit_table" | head -8 | sed 's/^/    /'
fi

# --- 4. devfreq (DDR / EMI / CCI) -------------------------------------------
sec "4. devfreq devices (DDR, EMI, interconnect)"
for d in /sys/class/devfreq/*; do
	[ -d "$d" ] || continue
	echo
	echo "--- $(basename "$d")"
	echo "    cur       : $(rd "$d/cur_freq")"
	echo "    min/max   : $(rd "$d/min_freq") / $(rd "$d/max_freq")"
	echo "    available : $(rd "$d/available_frequencies")"
	echo "    governor  : $(rd "$d/governor")  avail: $(rd "$d/available_governors")"
done

# --- 5. thermal --------------------------------------------------------------
sec "5. thermal zones"
MAXT=0
for z in /sys/class/thermal/thermal_zone*; do
	[ -d "$z" ] || continue
	t=$(rd "$z/temp")
	isnum "$t" || t=0
	[ "$t" -gt "$MAXT" ] && MAXT=$t
	printf '  %-16s %-26s %6s  mode=%s\n' \
		"$(basename "$z")" "$(rd "$z/type")" "$t" "$(rd "$z/mode")"
	# first few trip points, only if the zone actually has them
	tp=""
	i=0
	while [ "$i" -lt 6 ]; do
		v=$(rd "$z/trip_point_${i}_temp")
		[ -z "$v" ] && break
		tp="$tp $v"
		i=$(( i + 1 ))
	done
	[ -n "$tp" ] && echo "      trips:$tp"
done
echo
if [ "$MAXT" -gt 0 ]; then
	echo "  hottest now: $(( MAXT / 1000 )) C"
fi

# --- 6. verdict --------------------------------------------------------------
sec "6. verdict"
if [ -n "$GPUDIR" ] && [ -e "$GPUDIR/fix_custom_freq_volt" ]; then
	echo "GPU overclock : POSSIBLE"
	echo "  node    : $GPUDIR/fix_custom_freq_volt"
	echo "  format  : echo '<freq_KHz> <volt_mVx100>' > $GPUDIR/fix_custom_freq_volt"
	echo "  restore : echo '0 0' > $GPUDIR/fix_custom_freq_volt"
	echo "  note    : writing disables GPU DVFS until you reset it, so the clock"
	echo "            stays pinned and heat builds up. Reset after testing."
else
	echo "GPU overclock : NOT AVAILABLE on this kernel build"
fi
echo
echo "CPU overclock : NOT POSSIBLE from userspace"
echo "  The freq/volt table is compiled into the kernel. The sysfs max is the"
echo "  hardware max; writing a higher value is rejected or ignored."
echo "  What you CAN do: pin the governor to 'performance' so it stays at the"
echo "  top row instead of ramping - that changes responsiveness, not the ceiling."
echo
echo "Nothing was modified by this script."
