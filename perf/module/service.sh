#!/system/bin/sh
# =============================================================================
# service.sh: wait for boot, apply the clocks, confirm survival.
#
# Order inside this file is deliberate:
#   1. bail out if the counter already tripped (3 failed boots)
#   2. wait for sys.boot_completed - not a fixed sleep, that is unreliable
#   3. apply CPU cluster C0 then C1, each through oc_cpu.sh which writes
#      voltage BEFORE frequency and reads back afterwards
#   4. apply GPU only if enabled
#   5. sleep SURVIVE_SECONDS; if we are still here, clear the counter
#
# Everything is logged to oc.log next to this script so you can see what
# actually happened instead of guessing.
# =============================================================================

MODDIR=${0%/*}
LOG="$MODDIR/oc.log"
CNT="$MODDIR/.bootcount"
STATUS="$MODDIR/.last_status"

[ -f "$MODDIR/config.env" ] && . "$MODDIR/config.env" 2>/dev/null

: > "$LOG"
log() { echo "$(date '+%H:%M:%S' 2>/dev/null) $*" >> "$LOG"; }

log "=== tanzanite OC start ==="
log "kernel: $(uname -r 2>/dev/null)"

n=0
[ -f "$CNT" ] && n=$(cat "$CNT" 2>/dev/null)
case "$n" in
	''|*[!0-9]*) n=0 ;;
esac
log "boot count: $n"

if [ "$n" -gt 3 ]; then
	log "DISABLED - too many boots without surviving. Nothing applied."
	echo "disabled after $n boots" > "$STATUS"
	exit 0
fi

# --- wait for the system to actually finish booting --------------------------
i=0
while [ "$i" -lt 120 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 1
	i=$(( i + 1 ))
done
if [ "$i" -ge 120 ]; then
	log "boot_completed never arrived - aborting, nothing applied"
	echo "boot_completed timeout" > "$STATUS"
	exit 0
fi
log "boot_completed after ${i}s"

sleep "${APPLY_DELAY:-10}"
log "applying after ${APPLY_DELAY:-10}s delay"

# --- CPU ---------------------------------------------------------------------
if [ "${CPU_ENABLE:-0}" = "1" ]; then
	if [ -e /proc/cpuhvfs/phyclk ]; then
		log "CPU C0 ${CPU_C0_MHZ}MHz / ${CPU_C0_MV}mV"
		OUT=$(SNAPFILE="$MODDIR/.orig" sh "$MODDIR/oc_cpu.sh" set 0 "$CPU_C0_MHZ" "$CPU_C0_MV" 2>&1)
		echo "$OUT" >> "$LOG"

		log "CPU C1 ${CPU_C1_MHZ}MHz / ${CPU_C1_MV}mV"
		OUT=$(SNAPFILE="$MODDIR/.orig" sh "$MODDIR/oc_cpu.sh" set 1 "$CPU_C1_MHZ" "$CPU_C1_MV" 2>&1)
		echo "$OUT" >> "$LOG"
	else
		log "CPU skipped - /proc/cpuhvfs/phyclk absent on this kernel"
	fi
else
	log "CPU disabled in config.env"
fi

# --- GPU ---------------------------------------------------------------------
if [ "${GPU_ENABLE:-0}" = "1" ]; then
	if [ -e /proc/gpufreqv2/fix_custom_freq_volt ]; then
		FK=$(( ${GPU_MHZ:-1150} * 1000 ))
		log "GPU ${GPU_MHZ}MHz / ${GPU_MV}mV"
		OUT=$(sh "$MODDIR/oc_gpu.sh" set "$FK" "$GPU_MV" 2>&1)
		echo "$OUT" >> "$LOG"
	else
		log "GPU skipped - /proc/gpufreqv2 absent on this kernel"
	fi
else
	log "GPU disabled in config.env"
fi

# --- survival check ----------------------------------------------------------
log "holding for ${SURVIVE_SECONDS:-30}s to confirm stability"
sleep "${SURVIVE_SECONDS:-30}"

echo 0 > "$CNT"
echo "applied and stable" > "$STATUS"
log "survived - boot counter cleared"
log "=== done ==="
