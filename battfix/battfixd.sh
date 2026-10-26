#!/system/bin/sh
# =============================================================================
# battfixd.sh - battery gauge fix for TWRP / OrangeFox recovery (tanzanite)
#
# WHY THIS EXISTS
#   On tanzanite the kernel's fuel gauge node
#   /sys/class/power_supply/battery/capacity gets stuck at 100 (wrong OCV table
#   in the vendor fuel algorithm). TWRP reads that node, so recovery shows a
#   permanent 100%. The same bug is documented by the battfix Magisk module,
#   whose fix is: ignore the kernel percentage, compute SOC in userspace from
#   the honest bms voltage/current, and push the result back.
#
#   TWRP has no Android framework, so "cmd battery set level" is not available.
#   Instead we write a sysfs-style capacity/status pair into a tmpfs directory
#   and point TWRP at it with:
#       TW_CUSTOM_BATTERY_PATH := "/tmp/batt"
#   TWRP then re-reads /tmp/batt/capacity once per second.
#
# ALGORITHM (ported from battfix-tanzanite v1.2)
#   OCV  = V_terminal - I * R_internal
#   SOC  = piecewise-linear lookup of OCV in etc/ocv.txt
#   then rate-limited and smoothed so the number does not jump around.
#
#   RMO = 95 mOhm was fitted on real tanzanite hardware (two current
#   transitions at 0.46 A and 0.35 A gave 91 and 103 mOhm). The generic
#   default of 60 reads about 4% too low, so do not "simplify" this to 60.
#
# UNITS
#   voltage_now : microvolts      current_now : microamps (negative = discharging)
#   i * RMO / 1000  converts uA * mOhm into uV.
# =============================================================================

OUT=/tmp/batt
OCV=/system/etc/battfix_ocv.txt
LOG=/tmp/battfix.log

# The ramdisk's /system gets shadowed once the system partition is mounted, and
# this loop re-reads the curve on every sample. Keep a tmpfs copy.
if [ -f "$OCV" ]; then
	cp -f "$OCV" /tmp/battfix_ocv.txt 2>/dev/null
fi
[ -f /tmp/battfix_ocv.txt ] && OCV=/tmp/battfix_ocv.txt

# Prefer the raw gauge (bms); fall back to the battery node if bms is absent.
BMS=/sys/class/power_supply/bms
[ -d "$BMS" ] || BMS=/sys/class/power_supply/battery
BAT=/sys/class/power_supply/battery

RMO=95          # internal resistance, mOhm
INTERVAL=5      # sample period, seconds
MAXDROP=3       # max decrease per sample, %
MAXRISE=2       # max increase per sample, %
ALPHA=3         # new-sample weight out of 10 (3 = fairly smooth)

rd() { cat "$1" 2>/dev/null | tr -d ' \r\n\t'; }

mkdir -p "$OUT" 2>/dev/null

# Seed immediately so TWRP never sees a missing file (it would show -1%).
seed=$(rd "$BAT/capacity")
case "$seed" in ''|*[!0-9]*) seed=50 ;; esac
echo "$seed" > "$OUT/capacity"
echo "Discharging" > "$OUT/status"

VS=
DISP=
TICK=0

while true; do
	TICK=$((TICK + 1))

	V=$(rd "$BMS/voltage_now")
	[ -z "$V" ] && V=$(rd "$BAT/voltage_now")
	I=$(rd "$BMS/current_now")
	[ -z "$I" ] && I=$(rd "$BAT/current_now")
	ST=$(rd "$BAT/status")

	case "$V" in
		''|*[!0-9-]*) echo "$TICK v=$V INVALID" >> "$LOG"; sleep "$INTERVAL"; continue ;;
	esac
	case "$I" in
		''|*[!0-9-]*) I=0 ;;
	esac

	# Internal-resistance compensation, converted to millivolts because the
	# OCV table is in mV. Works for both directions: discharging reports
	# negative current, charging positive.
	voc=$(( (V - I * RMO / 1000) / 1000 ))

	# Exponential smoothing, integer only.
	if [ -z "$VS" ]; then
		VS=$voc
	else
		VS=$(( (ALPHA * voc + (10 - ALPHA) * VS) / 10 ))
	fi

	# Piecewise-linear OCV -> SOC lookup. Table must be sorted descending.
	soc=""
	pmv=""
	ppc=""
	while read -r mv pc; do
		case "$mv" in ''|\#*) continue ;; esac
		if [ -z "$pmv" ]; then
			if [ "$VS" -ge "$mv" ]; then soc=$pc; break; fi
		else
			if [ "$VS" -ge "$mv" ] && [ "$VS" -le "$pmv" ]; then
				soc=$(( ppc + (pc - ppc) * (VS - pmv) / (mv - pmv) ))
				break
			fi
		fi
		pmv=$mv
		ppc=$pc
	done < "$OCV"
	[ -z "$soc" ] && soc=${ppc:-0}

	[ "$soc" -lt 1 ] && soc=1
	[ "$soc" -gt 100 ] && soc=100

	# First real reading wins outright. Seeding DISP from the kernel capacity
	# would make the number crawl down from a wrong 100 at MAXDROP per sample.
	if [ -z "$DISP" ]; then
		DISP=$soc
	else
		d=$(( soc - DISP ))
		[ "$d" -gt "$MAXRISE" ] && d=$MAXRISE
		[ "$d" -lt $((0 - MAXDROP)) ] && d=$((0 - MAXDROP))
		DISP=$(( DISP + d ))
	fi
	[ "$DISP" -lt 1 ] && DISP=1
	[ "$DISP" -gt 100 ] && DISP=100

	echo "$DISP" > "$OUT/capacity"
	case "$ST" in
		Charging*|Full*) echo "Charging" > "$OUT/status" ;;
		*)               echo "Discharging" > "$OUT/status" ;;
	esac

	# Keep the log small but always useful for debugging.
	echo "$TICK v=$V i=$I voc=$voc vs=$VS soc=$soc disp=$DISP st=$ST" >> "$LOG"
	SZ=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
	[ -n "$SZ" ] && [ "$SZ" -gt 65536 ] && mv -f "$LOG" "$LOG.1"

	sleep "$INTERVAL"
done
