#!/system/bin/sh
# =============================================================================
# oc_apply.sh - apply the overclock described in config.conf
#
# Called by service.sh at boot, and safe to run by hand:
#     sh /data/adb/modules/tanzanite_oc/common/oc_apply.sh
#
# Returns 0 only if every enabled part was written AND read back as requested.
# A non-zero return is what feeds the boot counter in service.sh.
#
# Nothing here touches the kernel image. These are the MTK debug hooks:
#   CPU : /proc/cpuhvfs/phyclk   "<cluster> <KHz>"
#         /proc/cpuhvfs/phyvolt  "<cluster> <uV>"
#   GPU : /proc/gpufreqv2/fix_custom_freq_volt  "<KHz> <mV*100>"
# =============================================================================

MOD=${1:-/data/adb/modules/tanzanite_oc}
HVD=${HVFSDIR:-/proc/cpuhvfs}
GPUD=${GPUDIR:-/proc/gpufreqv2}
CLK=$HVD/phyclk
VLT=$HVD/phyvolt
GPUN=$GPUD/fix_custom_freq_volt
LOG=$MOD/last.log

. "$MOD/config.conf" 2>/dev/null

rd() { cat "$1" 2>/dev/null; }

log() {
	echo "$(date '+%m-%d %H:%M:%S' 2>/dev/null) $*" >> "$LOG"
	echo "$*"
}

cur_freq() {
	v=$(rd "$CLK" | sed -n "s/.*C$1, freq = \([0-9]*\).*/\1/p" | head -1)
	[ -n "$v" ] || v=$(rd "$CLK" | awk -v c="$1" '$1 == c { print $2; exit }')
	echo "$v"
}

cur_volt() {
	v=$(rd "$VLT" | sed -n "s/.*C$1, volt = \([-0-9]*\).*/\1/p" | head -1)
	[ -n "$v" ] || v=$(rd "$VLT" | awk -v c="$1" '$1 == c { print $2; exit }')
	echo "$v"
}

RC=0

apply_cpu() {
	C=$1
	MHZ=$2
	MV=$3

	[ -n "$MHZ" ] && [ -n "$MV" ] || { log "CPU C$C: no value in config, skipped"; return 0; }
	[ -e "$CLK" ] && [ -e "$VLT" ] || { log "CPU C$C: $CLK or $VLT missing"; RC=1; return 1; }

	FK=$(( MHZ * 1000 ))
	VU=$(( MV * 1000 ))

	# voltage first: the clock must never arrive without headroom
	printf '%s %s' "$C" "$VU" > "$VLT" 2>/dev/null
	rc1=$?
	sleep 1
	printf '%s %s' "$C" "$FK" > "$CLK" 2>/dev/null
	rc2=$?
	sleep 1

	NF=$(cur_freq "$C")
	NV=$(cur_volt "$C")

	if [ "$rc1" != "0" ] || [ "$rc2" != "0" ]; then
		log "CPU C$C FAIL: write rejected (clk=$rc2 volt=$rc1)"
		RC=1
		return 1
	fi
	if [ "$NF" = "$FK" ]; then
		log "CPU C$C ok: ${MHZ} MHz / ${MV} mV  (read back $NF KHz / $NV uV)"
		return 0
	fi
	log "CPU C$C FAIL: asked $FK KHz, read back $NF KHz (PLL rounded it, or DVFS took it back)"
	RC=1
	return 1
}

apply_gpu() {
	[ -n "$GPU_KHZ" ] && [ -n "$GPU_MV" ] || { log "GPU: no value in config, skipped"; return 0; }
	[ -e "$GPUN" ] || { log "GPU: $GPUN missing"; RC=1; return 1; }

	VW=$(( GPU_MV * 100 ))
	printf '%s %s' "$GPU_KHZ" "$VW" > "$GPUN" 2>/dev/null
	rc=$?
	sleep 1
	RB=$(rd "$GPUN")

	if [ "$rc" != "0" ]; then
		log "GPU FAIL: write rejected"
		RC=1
		return 1
	fi
	case "$RB" in
		*"$GPU_KHZ"*)
			log "GPU ok: $GPU_KHZ KHz / $GPU_MV mV  (read back: $RB)"
			return 0
			;;
		*)
			log "GPU FAIL: asked $GPU_KHZ KHz, read back: $RB"
			RC=1
			return 1
			;;
	esac
}

log "--- apply start (kernel $(uname -r 2>/dev/null)) ---"

[ "$ENABLE_CPU" = "1" ] && {
	apply_cpu 0 "$A55_MHZ" "$A55_MV"
	apply_cpu 1 "$A76_MHZ" "$A76_MV"
}

[ "$ENABLE_GPU" = "1" ] && apply_gpu

if [ "$RC" = "0" ]; then
	log "--- apply done: all requested values held ---"
else
	log "--- apply done: something did NOT hold, see above ---"
fi

exit $RC
