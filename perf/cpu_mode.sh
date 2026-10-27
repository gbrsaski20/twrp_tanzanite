#!/system/bin/sh
# =============================================================================
# cpu_mode.sh - pin the CPU at its top row (this does NOT raise the ceiling)
#
# WHAT THIS CAN AND CANNOT DO
#   On MT6789 the CPU freq/volt table is compiled into the kernel
#   (mt_cpufreq / cpuhvfs, "mediatek,cpufreq-hybrid"). Userspace cannot add a
#   row to it, so 2.2 GHz stays 2.2 GHz - there is no CPU overclock here.
#
#   What userspace CAN do is stop the governor from ramping down: set
#   scaling_governor=performance and scaling_min_freq=scaling_max_freq. The
#   effect is "always at the top row" instead of "top row after 200 ms".
#
#   On MTK the hybrid DVFS driver sometimes ignores sysfs writes and keeps its
#   own limit. This script writes, waits, reads back, and tells you plainly
#   whether the write stuck. Same empirical rule as the rest of this toolkit:
#   do not trust the write, trust the read.
#
# USAGE
#   sh cpu_mode.sh            status
#   sh cpu_mode.sh perf       pin every policy to its max freq
#   sh cpu_mode.sh reset      restore the values saved before the first 'perf'
#   sh cpu_mode.sh watch [s]  sample cur_freq for s seconds, print the spread
#
# Nothing persists across a reboot.
# =============================================================================

# overridable so the script can be tested against a fake tree
CPU=${CPUDIR:-/sys/devices/system/cpu}
SNAP=${SNAPFILE:-/data/local/tmp/cpu_mode.snapshot}
[ -d /data/local/tmp ] || SNAP=${SNAPFILE:-/tmp/cpu_mode.snapshot}

rd() { cat "$1" 2>/dev/null; }

isnum() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

policies() {
	for p in "$CPU"/cpufreq/policy*; do
		[ -d "$p" ] || continue
		echo "$p"
	done
}

show_status() {
	n=0
	for p in $(policies); do
		n=$(( n + 1 ))
		echo "--- $(basename "$p")  cpus: $(rd "$p/related_cpus")"
		echo "    cur      : $(rd "$p/scaling_cur_freq") KHz"
		echo "    min/max  : $(rd "$p/scaling_min_freq") / $(rd "$p/scaling_max_freq") KHz"
		echo "    hw max   : $(rd "$p/cpuinfo_max_freq") KHz"
		echo "    governor : $(rd "$p/scaling_governor")"
	done
	[ "$n" = "0" ] && echo "no cpufreq policies found"
	echo
	if [ -f "$SNAP" ]; then
		echo "snapshot : $SNAP"
		sed 's/^/  /' "$SNAP"
	else
		echo "snapshot : none yet (created on first 'perf')"
	fi
}

snapshot() {
	[ -f "$SNAP" ] && return 0
	: > "$SNAP"
	for p in $(policies); do
		echo "$(basename "$p") $(rd "$p/scaling_governor") $(rd "$p/scaling_min_freq") $(rd "$p/scaling_max_freq")" >> "$SNAP"
	done
	echo "snapshot saved to $SNAP"
}

do_perf() {
	snapshot
	echo
	for p in $(policies); do
		MAX=$(rd "$p/cpuinfo_max_freq")
		[ -z "$MAX" ] && MAX=$(rd "$p/scaling_max_freq")
		isnum "$MAX" || continue

		GOV=$(rd "$p/scaling_governor")
		OLD_MAX=$(rd "$p/scaling_max_freq")

		# order matters: raise max first, otherwise min cannot reach it
		echo "$MAX" > "$p/scaling_max_freq" 2>/dev/null
		echo performance > "$p/scaling_governor" 2>/dev/null
		echo "$MAX" > "$p/scaling_min_freq" 2>/dev/null

		sleep 1
		NGOV=$(rd "$p/scaling_governor")
		NMIN=$(rd "$p/scaling_min_freq")
		NMAX=$(rd "$p/scaling_max_freq")

		echo "--- $(basename "$p")  target $MAX KHz"
		echo "    governor : $GOV -> $NGOV"
		echo "    min/max  : $NMIN / $NMAX KHz"
		if [ "$NMIN" = "$MAX" ] && [ "$NGOV" = "performance" ]; then
			echo "    RESULT   : pinned at top row"
		elif [ "$NMAX" != "$OLD_MAX" ] || [ "$NGOV" != "$GOV" ]; then
			echo "    RESULT   : partially applied - driver took some values"
		else
			echo "    RESULT   : REVERTED - the MTK DVFS driver owns this policy"
			echo "               and does not accept the sysfs write."
		fi
	done
	echo
	echo "Pinned means the cores no longer idle down. Expect more heat and"
	echo "faster battery drain. 'sh $0 reset' or reboot to undo."
}

do_reset() {
	if [ ! -f "$SNAP" ]; then
		echo "no snapshot - nothing to restore. Falling back to schedutil."
		for p in $(policies); do
			echo schedutil > "$p/scaling_governor" 2>/dev/null
			MIN=$(rd "$p/cpuinfo_min_freq")
			[ -n "$MIN" ] && echo "$MIN" > "$p/scaling_min_freq" 2>/dev/null
		done
		return 0
	fi
	while read -r name gov mn mx; do
		p="$CPU/cpufreq/$name"
		[ -d "$p" ] || continue
		[ -n "$mn" ] && echo "$mn" > "$p/scaling_min_freq" 2>/dev/null
		[ -n "$mx" ] && echo "$mx" > "$p/scaling_max_freq" 2>/dev/null
		[ -n "$gov" ] && echo "$gov" > "$p/scaling_governor" 2>/dev/null
		echo "$name -> governor=$gov min=$mn max=$mx"
	done < "$SNAP"
	rm -f "$SNAP"
	echo
	echo "restored. snapshot removed."
}

do_watch() {
	S=$1
	isnum "$S" || S=20
	echo "sampling scaling_cur_freq for $S s"
	i=0
	while [ "$i" -lt "$S" ]; do
		line=""
		for p in $(policies); do
			line="$line $(rd "$p/scaling_cur_freq")"
		done
		echo "  t+${i}s :$line"
		sleep 2
		i=$(( i + 2 ))
	done
}

UID_NOW=$(id -u 2>/dev/null)
if [ "$UID_NOW" != "0" ]; then
	echo "FAIL - not root (uid=$UID_NOW). Run with su or adb root."
	exit 1
fi

echo "=============================================================="
echo "CPU mode - pin at top row (no clock increase)"
echo "=============================================================="
echo "kernel : $(uname -r 2>/dev/null)"
echo

case "$1" in
	"")     show_status ;;
	status) show_status ;;
	perf)   do_perf ;;
	reset)  do_reset ;;
	watch)  do_watch "$2" ;;
	*)
		echo "usage: sh $0 [status|perf|reset|watch [s]]"
		exit 1
		;;
esac
