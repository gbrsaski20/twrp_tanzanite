#!/system/bin/sh
# =============================================================================
# post-fs-data: boot counter, nothing else.
#
# WHY HERE AND NOT THE OC ITSELF
#   At this stage the cpuhvfs and gpufreqv2 modules are often not loaded yet, so
#   writing phyclk here would fail silently. This stage exists only to count
#   boots, because it runs early enough that a hang later in boot still leaves
#   the counter incremented.
#
#   service.sh applies the clocks and clears the counter only after the phone
#   has survived SURVIVE_SECONDS with them active. So:
#
#     boot 1 with OC -> freeze      counter = 1
#     boot 2 with OC -> freeze      counter = 2
#     boot 3 with OC -> freeze      counter = 3
#     boot 4            -> skipped, phone boots normally
#
#   That is the whole bootloop protection. No key combos needed.
# =============================================================================

MODDIR=${0%/*}
CNT="$MODDIR/.bootcount"

[ -f "$MODDIR/config.env" ] && . "$MODDIR/config.env" 2>/dev/null

n=0
[ -f "$CNT" ] && n=$(cat "$CNT" 2>/dev/null)
case "$n" in
	''|*[!0-9]*) n=0 ;;
esac
n=$(( n + 1 ))
echo "$n" > "$CNT"

if [ "$n" -gt 3 ]; then
	echo "OC skipped - $n boots without reaching the survive window." > "$MODDIR/.last_status"
	echo "Set CPU_ENABLE=0 in config.env, or delete this module, then reboot." >> "$MODDIR/.last_status"
fi
