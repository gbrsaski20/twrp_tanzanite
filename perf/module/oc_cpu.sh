#!/system/bin/sh
# =============================================================================
# oc_cpu.sh - CPU overclock via the MTK cpuhvfs debug hook
#
# WHERE THIS COMES FROM (real source, not guesswork)
#   drivers/misc/mediatek/cpufreq_v1/cpufreq-dbg.c creates /proc/cpuhvfs with
#   0664 entries. Two of them are RW and take a "<cluster> <value>" pair:
#
#     phyclk_proc_write : sscanf(buf, "%d %d", &cluster, &freq)
#                         cpuhvfs_set_freq(cluster, freq);      freq in KHz
#
#     phyvolt_proc_write: sscanf(buf, "%d %d", &cluster, &volt)
#                         cpuhvfs_set_volt(cluster, volt);      volt in uV
#
#   These write the PLL and the regulator DIRECTLY, bypassing the DVFS table.
#   That is the only reason a clock above the stock row is reachable at all -
#   the table itself is compiled into the kernel and cannot be edited.
#
# CLUSTER ORDER
#   The driver names clusters C0..C3 with the comment
#       C0 = "L or LL", C1 = "BL or L", C2 = "B or CCI"
#   On a two-cluster SoC like MT6789: C0 = little (A55), C1 = big (A76).
#   Do not trust this blindly - run `status` and compare against the cpufreq
#   policies, they must agree before you write anything.
#
# WHY THIS IS RISKY AND WHY IT IS STILL SAFE TO TRY
#   Risky: an overclocked clock at too low a voltage hangs the phone instantly;
#   too high a voltage is worse for the silicon. There is no EEM/PV table
#   entry for these clocks, so the algorithm's own compensation is bypassed.
#   Safe : nothing is persisted. These are debug hooks in a running kernel.
#   Reboot and the stock table is back. A hang costs you a force-reboot, not
#   a brick, and never a bootloop.
#
# USAGE
#   sh oc_cpu.sh                          status (nodes + live freq/volt)
#   sh oc_cpu.sh test 1 2500 1100 60      try A76 at 2.5 GHz, 60 s, auto-restore
#   sh oc_cpu.sh set 1 2500 1100          apply and leave it
#   sh oc_cpu.sh preset a76-25            same as above with saved values
#   sh oc_cpu.sh preset a55-23            A55 at 2.3 GHz
#   sh oc_cpu.sh preset both              both clusters, volt raised first
#   sh oc_cpu.sh restore                  back to each cluster's stock top
#
#   --force lifts the conservative caps (2600 MHz / 1150 mV).
# =============================================================================

HVD=${HVFSDIR:-/proc/cpuhvfs}
CLK=$HVD/phyclk
VLT=$HVD/phyvolt
CPU=${CPUDIR:-/sys/devices/system/cpu}
SNAP=${SNAPFILE:-/tmp/oc_cpu_orig}

STOCK_A55=2000000
STOCK_A76=2200000

# all frequency limits here are in MHz, matching what the user types
HARD_MAX_F=3000        # refuse anything above this outright
HARD_MAX_V=1300        # mV, refuse outright
SOFT_MAX_F=2600        # unless --force
SOFT_MAX_V=1150        # unless --force
MIN_V=550

rd() { cat "$1" 2>/dev/null; }

isnum() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# "old cluster: C0, freq = 2001000" -> 2001000
# falls back to the raw "<cluster> <value>" form, which is also what a plain
# file looks like, so the script stays readable if the kernel format differs
cur_freq() {
	v=$(rd "$CLK" | sed -n "s/.*C$1, freq = \([0-9]*\).*/\1/p" | head -1)
	[ -n "$v" ] || v=$(rd "$CLK" | awk -v c="$1" '$1 == c { print $2; exit }')
	echo "$v"
}

# "old cluster: C0, volt = 850000" -> 850000
cur_volt() {
	v=$(rd "$VLT" | sed -n "s/.*C$1, volt = \([-0-9]*\).*/\1/p" | head -1)
	[ -n "$v" ] || v=$(rd "$VLT" | awk -v c="$1" '$1 == c { print $2; exit }')
	echo "$v"
}

policy_of() {
	i=0
	for p in "$CPU"/cpufreq/policy*; do
		[ -d "$p" ] || continue
		if [ "$i" = "$1" ]; then
			echo "$p"
			return 0
		fi
		i=$(( i + 1 ))
	done
	return 1
}

show_status() {
	if [ ! -d "$HVD" ]; then
		echo "  $HVD ABSENT - this kernel does not expose the cpuhvfs hook."
		echo "  CPU overclock is not possible on this build."
		return 1
	fi
	echo "--- $HVD"
	ls -l "$HVD" 2>/dev/null | sed 's/^/  /' | head -14
	echo
	echo "--- phyclk (live PLL frequency per cluster)"
	rd "$CLK" | sed 's/^/  /'
	echo "--- phyvolt (live regulator voltage per cluster)"
	rd "$VLT" | sed 's/^/  /'
	echo
	echo "--- cpufreq view (for cross-checking cluster order)"
	i=0
	for p in "$CPU"/cpufreq/policy*; do
		[ -d "$p" ] || continue
		echo "  policy$i  cpus=$(rd "$p/related_cpus")  cur=$(rd "$p/scaling_cur_freq")  max=$(rd "$p/cpuinfo_max_freq")"
		i=$(( i + 1 ))
	done
	echo
	echo "stock tops: A55 $STOCK_A55 KHz, A76 $STOCK_A76 KHz"
}

# apply volt first, then freq - never the other way round
apply_one() {
	C=$1
	F=$2
	V=$3
	FORCE=$4

	if ! isnum "$C" || ! isnum "$F" || ! isnum "$V"; then
		echo "REFUSED: cluster, MHz and mV must be plain integers."
		return 1
	fi
	if [ "$F" -gt "$HARD_MAX_F" ]; then
		echo "REFUSED: $F MHz above the hard cap of $HARD_MAX_F MHz."
		return 1
	fi
	if [ "$V" -gt "$HARD_MAX_V" ] || [ "$V" -lt "$MIN_V" ]; then
		echo "REFUSED: $V mV outside $MIN_V..$HARD_MAX_V mV."
		return 1
	fi
	if [ "$F" -gt "$SOFT_MAX_F" ] && [ "$FORCE" != "1" ]; then
		echo "REFUSED: $F MHz above the conservative cap of $SOFT_MAX_F MHz."
		echo "         Use --force if you accept the risk."
		return 1
	fi
	if [ "$V" -gt "$SOFT_MAX_V" ] && [ "$FORCE" != "1" ]; then
		echo "REFUSED: $V mV above the conservative cap of $SOFT_MAX_V mV."
		echo "         Use --force if you accept the risk."
		return 1
	fi
	if [ ! -e "$CLK" ] || [ ! -e "$VLT" ]; then
		echo "FAIL: $CLK or $VLT missing."
		return 1
	fi

	FK=$(( F * 1000 ))
	VU=$(( V * 1000 ))

	echo "--- cluster C$C"
	echo "    now      : freq=$(cur_freq "$C") KHz  volt=$(cur_volt "$C") uV"

	# 1. voltage up first, so the new clock has headroom when it appears
	printf '%s %s' "$C" "$VU" > "$VLT" 2>/dev/null
	rc1=$?
	sleep 1
	# 2. then the clock
	printf '%s %s' "$C" "$FK" > "$CLK" 2>/dev/null
	rc2=$?
	sleep 1

	NF=$(cur_freq "$C")
	NV=$(cur_volt "$C")

	echo "    target   : freq=$FK KHz  volt=$VU uV"
	echo "    read back: freq=$NF KHz  volt=$NV uV"

	if [ "$rc1" != "0" ] || [ "$rc2" != "0" ]; then
		echo "    RESULT   : write FAILED (node read-only, or driver rejected it)"
		return 1
	fi
	if [ "$NF" = "$FK" ]; then
		echo "    RESULT   : HELD at $F MHz"
		return 0
	fi
	echo "    RESULT   : freq did NOT hold (asked $FK, got $NF)"
	echo "               Either the PLL cannot produce that exact clock and"
	echo "               rounded it, or DVFS re-asserted its own value."
	return 2
}

restore_one() {
	C=$1
	P=$(policy_of "$C" 2>/dev/null)
	if [ -n "$P" ]; then
		MAX=$(rd "$P/cpuinfo_max_freq")
	fi
	if [ -z "$MAX" ]; then
		case "$C" in
			0) MAX=$STOCK_A55 ;;
			1) MAX=$STOCK_A76 ;;
			*) MAX= ;;
		esac
	fi
	[ -n "$MAX" ] || return 1
	printf '%s %s' "$C" "$MAX" > "$CLK" 2>/dev/null
	sleep 1
	echo "  C$C -> $(cur_freq "$C") KHz (stock top $MAX)"
}

# Capture what the clusters were doing BEFORE we touch anything. Restoring from
# this is exact; guessing from the cpufreq policy index can pick the wrong
# cluster and write a wrong value.
snapshot_hv() {
	[ -f "$SNAP" ] && return 0
	[ -e "$CLK" ] || return 0
	: > "$SNAP"
	i=0
	while [ "$i" -lt 4 ]; do
		f=$(cur_freq "$i")
		[ -n "$f" ] || break
		echo "C$i $f $(cur_volt "$i")" >> "$SNAP"
		i=$(( i + 1 ))
	done
	[ -s "$SNAP" ] && echo "(original values saved to $SNAP)"
}

restore_snapshot() {
	[ -f "$SNAP" ] || return 1
	while read -r name f v; do
		c=${name#C}
		# voltage first, then clock - same order as applying
		if [ -n "$v" ] && [ "$v" != "-" ] && [ "$v" -gt 0 ] 2>/dev/null; then
			printf '%s %s' "$c" "$v" > "$VLT" 2>/dev/null
		fi
		if [ -n "$f" ]; then
			printf '%s %s' "$c" "$f" > "$CLK" 2>/dev/null
		fi
		sleep 1
		echo "  $name -> freq=$(cur_freq "$c") KHz  volt=$(cur_volt "$c") uV"
	done < "$SNAP"
	rm -f "$SNAP"
	return 0
}

do_test() {
	C=$1
	F=$2
	V=$3
	S=$4
	isnum "$S" || S=60

	echo "=== test C$C at $F MHz / $V mV for $S s ==="
	snapshot_hv
	apply_one "$C" "$F" "$V" "$FORCE"
	rc=$?
	if [ "$rc" = "1" ]; then
		exit 1
	fi

	echo
	echo "sampling every 5 s"
	i=0
	lost=0
	while [ "$i" -lt "$S" ]; do
		sleep 5
		i=$(( i + 5 ))
		nf=$(cur_freq "$C")
		echo "  t+${i}s  C$C = $nf KHz"
		if [ "$nf" != "$(( F * 1000 ))" ]; then
			lost=$(( lost + 1 ))
		else
			lost=0
		fi
		if [ "$lost" -ge 2 ]; then
			echo
			echo "  DVFS took the clock back - this hook does not stick on"
			echo "  this kernel. Stopping the test."
			break
		fi
	done

	echo
	echo "--- restoring ---"
	restore_snapshot || restore_one "$C"
	echo
	echo "If the phone froze or rebooted during the test, that clock/voltage"
	echo "pair is not stable on this unit. Step down 100 MHz or raise 25 mV."
}

do_preset() {
	snapshot_hv
	case "$1" in
		a76-25) apply_one 1 2500 1100 "$FORCE" ;;
		a55-23) apply_one 0 2300 950  "$FORCE" ;;
		both)
			apply_one 0 2300 950  "$FORCE"
			echo
			apply_one 1 2500 1100 "$FORCE"
			;;
		*)
			echo "usage: sh $0 preset a76-25|a55-23|both"
			return 1
			;;
	esac
}

UID_NOW=$(id -u 2>/dev/null)
if [ "$UID_NOW" != "0" ]; then
	echo "FAIL - not root (uid=$UID_NOW). Run with su or adb root."
	exit 1
fi

MODE=$1
FORCE=0
for a in "$@"; do
	[ "$a" = "--force" ] && FORCE=1
done

echo "=============================================================="
echo "CPU overclock - MT6789 cpuhvfs debug hook"
echo "=============================================================="
echo "kernel : $(uname -r 2>/dev/null)"
echo

case "$MODE" in
	"")      show_status ;;
	status)  show_status ;;
	set)
		snapshot_hv
		apply_one "$2" "$3" "$4" "$FORCE"
		;;
	preset)  do_preset "$2" ;;
	test)    do_test "$2" "$3" "$4" "$5" ;;
	restore)
		if [ ! -e "$CLK" ]; then
			echo "node absent, nothing to restore."
			exit 0
		fi
		if restore_snapshot; then
			exit 0
		fi
		echo "no snapshot - falling back to each cluster's stock top"
		i=0
		while [ "$i" -lt 4 ]; do
			[ -n "$(cur_freq "$i")" ] || break
			restore_one "$i"
			i=$(( i + 1 ))
		done
		;;
	*)
		echo "usage: sh $0 [status|set <c> <MHz> <mV>|preset a76-25|a55-23|both|test <c> <MHz> <mV> [s]|restore]"
		exit 1
		;;
esac
