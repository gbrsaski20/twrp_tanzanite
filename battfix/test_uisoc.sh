#!/system/bin/sh
# =============================================================================
# test_uisoc.sh - does writing battery/uisoc actually steer the kernel gauge?
#
# WHAT THE SOURCE SAYS (itswill00/android_kernel_xiaomi_tanzanite, GKI 5.10)
#   mtk_battery.h declares:
#       BAT_SYSFS_FIELD_WO(uisoc, BAT_PROP_UISOC)
#   and BAT_SYSFS_FIELD_WO is __ATTR(name, 0200, ...) -> write-only, so the node
#   exists and root can always write it regardless of the mode.
#
#   uisoc_set() does:
#       pdata->ui_old_soc = daemon_ui_soc;
#       gm->ui_soc        = (daemon_ui_soc + 50) / 100;   <- hundredths in
#       gm->bs_data.bat_capacity = gm->ui_soc;
#       battery_update(gm);
#
#   So the unit is PERCENT x 100: 2200 means 22%.
#
#   BUT mtk_battery_algo.c never reads ui_old_soc, and on every FG interrupt
#   fgr_int_end_flow() does:
#       battery_set_property(BAT_PROP_UISOC, algo->ui_soc);   <- re-runs uisoc_set
#       gauge_set_property(GAUGE_PROP_RTC_UI_SOC, (algo->ui_soc + 50) / 100);
#   so the algorithm is expected to overwrite our value within one interrupt
#   cycle. This script measures whether that actually happens in recovery.
#
# THREE POSSIBLE OUTCOMES
#   A) capacity changes and HOLDS      -> usable override, we can build on it
#   B) capacity changes then REVERTS   -> confirmed: algo owns the value, we need
#                                         the RTC route (FG_DAEMON_CMD_SET_RTC_UI_SOC)
#   C) capacity never changes          -> gm->fixed_uisoc is set (0xffff default),
#                                         which is an even stronger override
#
# SAFE TO RUN: this is the same write the Android fuel-gauge daemon performs.
# A wrong value only makes the number wrong for a few seconds; the algorithm
# restores its own value on the next interrupt flow.
# =============================================================================

U=/sys/class/power_supply/battery/uisoc
C=/sys/class/power_supply/battery/capacity
V=/sys/class/power_supply/bms/voltage_now
D=/tmp/batt/capacity

echo "=============================================================="
echo " uisoc override test"
echo "=============================================================="

if [ ! -e "$U" ]; then
	echo "RESULT: FAIL - $U does not exist"
	echo "        the attribute group is not registered on this build."
	echo "        Report this, it changes the plan."
	exit 1
fi

echo "node     : $U"
echo "perms    : $(ls -l "$U" 2>/dev/null)"
echo "capacity : $(cat "$C" 2>/dev/null)"
echo "voltage  : $(cat "$V" 2>/dev/null) uV"
echo "daemon   : $(cat "$D" 2>/dev/null)"

BEFORE=$(cat "$C" 2>/dev/null | tr -d ' \r\n\t')
case "$BEFORE" in ''|*[!0-9]*) BEFORE=-1 ;; esac

TARGET=$(cat "$D" 2>/dev/null | tr -d ' \r\n\t')
case "$TARGET" in ''|*[!0-9]*) TARGET=50 ;; esac

# Pick a target that is clearly different from the current reading, otherwise
# a "no change" result would be ambiguous.
if [ "$TARGET" -eq "$BEFORE" ]; then
	if [ "$BEFORE" -gt 50 ]; then
		TARGET=20
	else
		TARGET=80
	fi
fi

WRITE=$(( TARGET * 100 ))

echo
echo "current capacity = $BEFORE"
echo "will write $WRITE to uisoc  ( = ${TARGET}.00% )"

if ! echo "$WRITE" > "$U" 2>/tmp/.uisocerr; then
	echo "RESULT: FAIL - write rejected: $(cat /tmp/.uisocerr 2>/dev/null)"
	rm -f /tmp/.uisocerr
	exit 1
fi
echo "write accepted"

echo
echo "watching capacity for 30 s (algo interrupts should fire in this window)"
A0=$(cat "$C" 2>/dev/null | tr -d ' \r\n\t')
echo "  t+0s    $A0"
sleep 5
A5=$(cat "$C" 2>/dev/null | tr -d ' \r\n\t')
echo "  t+5s    $A5"
sleep 5
A10=$(cat "$C" 2>/dev/null | tr -d ' \r\n\t')
echo "  t+10s   $A10"
sleep 10
A20=$(cat "$C" 2>/dev/null | tr -d ' \r\n\t')
echo "  t+20s   $A20"
sleep 10
A30=$(cat "$C" 2>/dev/null | tr -d ' \r\n\t')
echo "  t+30s   $A30"

echo
echo "--------------------------------------------------------------"
if [ "$A0" = "$BEFORE" ] && [ "$A30" = "$BEFORE" ]; then
	echo "OUTCOME C: capacity never moved."
	echo "  -> gm->fixed_uisoc is probably set, uisoc writes are ignored."
	echo "  -> that is a STRONGER override; we would target it instead."
elif [ "$A30" = "$TARGET" ] || [ "$A30" = "$((TARGET + 1))" ] || [ "$A30" = "$((TARGET - 1))" ]; then
	echo "OUTCOME A: capacity followed our write and HELD for 30 s."
	echo "  -> uisoc is a usable override in recovery."
	echo "  -> next step: battfixd v5 writes uisoc every tick."
else
	echo "OUTCOME B: capacity moved to $A0 then reverted to $A30."
	echo "  -> confirmed, the algorithm owns the value (fgr_int_end_flow)."
	echo "  -> uisoc is display-only; the durable fix needs the RTC route"
	echo "     (netlink FG_DAEMON_CMD_SET_RTC_UI_SOC)."
fi
echo "--------------------------------------------------------------"
echo
echo "send this whole output back and I will pick the next step."
