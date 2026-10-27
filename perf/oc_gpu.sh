#!/system/bin/sh
# =============================================================================
# oc_gpu.sh - GPU overclock for MT6789 (Mali-G57 MC2) at runtime
#
# THE KEY FACT
#   The gpufreq v2 driver accepts an arbitrary freq/volt pair through
#       /proc/gpufreqv2/fix_custom_freq_volt      format: "<KHz> <mV*100>"
#   and only checks it against hard limits, not against the OPP table:
#       freq  475000 .. 1900000 KHz
#       volt   50000 ..  129300  (i.e. 500.00 .. 1293.00 mV)
#   Stock maximum is OPP0 = 1100000 KHz @ 90000 (900 mV). Anything above that
#   is a genuine overclock, and it needs no kernel rebuild.
#
# WHY THIS IS SAFER THAN AN OC KERNEL
#   Nothing is persisted. The value lives in RAM in the running kernel; a
#   reboot restores the stock table and normal DVFS. A bad value can therefore
#   never cause a bootloop - worst case the phone freezes while you are using
#   it, you force a reboot, and it comes back stock.
#
# WHAT IT COSTS
#   While a custom value is set the driver clears normal DVFS (DVFS_DEBUG_KEEP),
#   so the GPU sits at that clock permanently - idle or load. That means heat
#   and battery drain even on the home screen. Always `reset` when done.
#
# USAGE
#   sh oc_gpu.sh                        status only
#   sh oc_gpu.sh preset light           +50 MHz, +30 mV   (recommended start)
#   sh oc_gpu.sh preset medium          +100 MHz, +60 mV
#   sh oc_gpu.sh preset max             +150 MHz, +100 mV (experimental)
#   sh oc_gpu.sh set 1150000 930        explicit, KHz and mV
#   sh oc_gpu.sh test 1150000 930 60    apply, watch 60 s, then auto-reset
#   sh oc_gpu.sh reset                  back to stock DVFS
#
#   Add --force to go past the conservative caps (1250 MHz / 1100 mV).
# =============================================================================

# overridable so the script can be tested against a fake tree
DIR=${GPUDIR:-/proc/gpufreqv2}
G=$DIR/fix_custom_freq_volt

# driver hard limits (from gpufreq_mt6789.h: POSDIV_8_MIN_FREQ, POSDIV_2_MAX_FREQ,
# VGPU_MAX_VOLT, VGPU_MIN_VOLT)
HARD_MIN_F=475000
HARD_MAX_F=1900000
HARD_MIN_V=500
HARD_MAX_V=1293

# conservative caps applied unless --force
SOFT_MAX_F=1250000
SOFT_MAX_V=1100

STOCK_F=1100000
STOCK_V=900

TEMP_ABORT=80

rd() { cat "$1" 2>/dev/null; }

isnum() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

hot() {
	m=0
	for z in /sys/class/thermal/thermal_zone*; do
		t=$(rd "$z/temp")
		isnum "$t" || continue
		[ "$t" -gt "$m" ] && m=$t
	done
	echo $(( m / 1000 ))
}

show_status() {
	echo "node     : $G"
	if [ ! -e "$G" ]; then
		echo "           ABSENT - this kernel does not expose GPU freq control."
		return 1
	fi
	echo "current  : $(rd "$G")"
	echo
	echo "top OPPs (stock table):"
	rd "$DIR/gpu_working_opp_table" | head -4 | sed 's/^/  /'
	echo
	echo "live freq:"
	rd "$DIR/gpufreq_status" | grep -i "freq\|opp" | head -6 | sed 's/^/  /'
	echo
	echo "hottest thermal zone: $(hot) C"
}

apply() {
	F=$1
	V=$2
	FORCE=$3

	if ! isnum "$F" || ! isnum "$V"; then
		echo "REFUSED: freq and volt must be plain integers."
		return 1
	fi
	if [ "$F" -lt "$HARD_MIN_F" ] || [ "$F" -gt "$HARD_MAX_F" ]; then
		echo "REFUSED: freq must be $HARD_MIN_F..$HARD_MAX_F KHz (driver limit)."
		return 1
	fi
	if [ "$V" -lt "$HARD_MIN_V" ] || [ "$V" -gt "$HARD_MAX_V" ]; then
		echo "REFUSED: volt must be $HARD_MIN_V..$HARD_MAX_V mV (driver limit)."
		return 1
	fi
	if [ "$F" -gt "$SOFT_MAX_F" ] && [ "$FORCE" != "1" ]; then
		echo "REFUSED: $F KHz is above the conservative cap of $SOFT_MAX_F KHz."
		echo "         That is $(( (F - STOCK_F) * 100 / STOCK_F ))% over stock."
		echo "         Re-run with --force if you really want it."
		return 1
	fi
	if [ "$V" -gt "$SOFT_MAX_V" ] && [ "$FORCE" != "1" ]; then
		echo "REFUSED: $V mV is above the conservative cap of $SOFT_MAX_V mV."
		echo "         Re-run with --force if you really want it."
		return 1
	fi

	if [ ! -e "$G" ]; then
		echo "FAIL: $G not found - nothing to write."
		return 1
	fi

	# driver unit is mV * 100
	VW=$(( V * 100 ))
	printf '%s %s' "$F" "$VW" > "$G" 2>/dev/null
	rc=$?

	sleep 1
	echo "wrote    : $F KHz  $V mV  (raw: $F $VW)"
	echo "read back: $(rd "$G")"
	if [ "$rc" != "0" ]; then
		echo
		echo "write FAILED. Either the node is not writable, or the driver"
		echo "rejected the pair (out of range). Nothing changed."
		return 1
	fi

	echo
	echo "ACTIVE - GPU DVFS is now pinned. Heat will build even at idle."
	echo "Run 'sh $0 reset' when you are done, or just reboot."
	return 0
}

do_test() {
	F=$1
	V=$2
	S=$3
	isnum "$S" || S=60

	echo "=== test: $F KHz @ $V mV for $S s ==="
	apply "$F" "$V" "$FORCE" || exit 1
	echo
	echo "sampling every 5 s (abort above ${TEMP_ABORT} C)"
	i=0
	while [ "$i" -lt "$S" ]; do
		sleep 5
		i=$(( i + 5 ))
		T=$(hot)
		cf=$(rd "$DIR/gpufreq_status" | grep -i "gpu freq" | head -1)
		echo "  t+${i}s  ${T} C  ${cf}"
		if [ "$T" -ge "$TEMP_ABORT" ]; then
			echo
			echo "ABORT: ${T} C reached the ${TEMP_ABORT} C limit. Resetting."
			break
		fi
	done
	echo
	echo "--- resetting ---"
	do_reset
	echo
	echo "If it survived without freezing or aborting, that clock is usable"
	echo "for short bursts. If it froze, the previous step down is your ceiling."
}

do_reset() {
	if [ ! -e "$G" ]; then
		echo "node absent, nothing to reset."
		return 0
	fi
	printf '0 0' > "$G" 2>/dev/null
	sleep 1
	echo "reset -> $(rd "$G")   (0 0 = stock DVFS running)"
}

# --- parse args --------------------------------------------------------------
MODE=$1
FORCE=0
for a in "$@"; do
	[ "$a" = "--force" ] && FORCE=1
done

UID_NOW=$(id -u 2>/dev/null)
if [ "$UID_NOW" != "0" ]; then
	echo "FAIL - not root (uid=$UID_NOW). Run with su or adb root."
	exit 1
fi

echo "=============================================================="
echo "GPU overclock - MT6789 gpufreq v2"
echo "=============================================================="
echo "kernel : $(uname -r 2>/dev/null)"
echo

case "$MODE" in
	"")
		show_status
		;;
	status)
		show_status
		;;
	set)
		show_status >/dev/null 2>&1
		apply "$2" "$3" "$FORCE"
		;;
	preset)
		case "$2" in
			stock)  apply 1100000 900  "$FORCE" ;;
			light)  apply 1150000 930  "$FORCE" ;;
			medium) apply 1200000 960  "$FORCE" ;;
			max)    apply 1250000 1000 "$FORCE" ;;
			*)
				echo "usage: sh $0 preset stock|light|medium|max"
				exit 1
				;;
		esac
		;;
	test)
		do_test "$2" "$3" "$4"
		;;
	reset)
		do_reset
		;;
	*)
		echo "usage:"
		echo "  sh $0                     status"
		echo "  sh $0 preset light        +50 MHz"
		echo "  sh $0 preset medium       +100 MHz"
		echo "  sh $0 preset max          +150 MHz"
		echo "  sh $0 set <KHz> <mV>      explicit"
		echo "  sh $0 test <KHz> <mV> [s] apply, sample, auto-reset"
		echo "  sh $0 reset               back to stock DVFS"
		exit 1
		;;
esac
