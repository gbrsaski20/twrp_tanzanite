#!/system/bin/sh
# =============================================================================
# battfixd.sh - battery gauge fix for TWRP / OrangeFox recovery (tanzanite)
#
# WHY THIS EXISTS
#   On tanzanite the kernel's fuel gauge node
#   /sys/class/power_supply/battery/capacity is wrong: the vendor OCV table
#   over-reports by roughly +60 points (at 3.68 V it claims 81% while the real
#   SOC is about 21%). TWRP reads that node, so recovery shows a nonsense value,
#   and worse, the kernel copies its own wrong figure into the RTC spare
#   register, which Android then inherits on the next boot.
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
#   then smoothed and rate-limited so the number does not jump around.
#
#   RMO = 95 mOhm was fitted on real tanzanite hardware (two current
#   transitions at 0.46 A and 0.35 A gave 91 and 103 mOhm). Verified again on
#   this unit: 3.677 V at ~20% gives 21-22% with this table, matching Android.
#   The generic default of 60 reads about 4% too low, so do not "simplify" it.
#
# ANTI-FLICKER (v3)
#   A single voltage read jitters by 5-15 mV because the load changes from
#   sample to sample. At 50 mV per 6% in the table that is ~1.2% of SOC, so a
#   naive implementation bounces 19 -> 20 -> 19 forever.
#   Two filters fix it:
#     1. Median of three reads. Rejects a single spike without lagging like an
#        average would.
#     2. Hysteresis deadband. The displayed value only moves when the computed
#        SOC is at least HYST points away, so 1-point noise is swallowed.
#
# UNITS
#   voltage_now : microvolts      current_now : microamps (negative = discharging)
#   i * RMO / 1000  converts uA * mOhm into uV.
# =============================================================================

OUT=/tmp/batt
OCV=/system/etc/battfix_ocv.txt
LOG=/tmp/battfix.log

# Fallback curve, embedded on purpose. The copy under /system lives in the
# recovery ramdisk, but /system gets shadowed by the real system partition as
# soon as TWRP mounts it, and then the file simply is not there any more. If
# that happens and the tmpfs copy is also gone (fresh /tmp, e.g. a later session
# or a manual restart of the daemon), the lookup has no table at all and every
# sample collapses to soc=0 -> clamped to 1%. That is what a display stuck at
# 1% means: the table is missing, not the battery.
# Keep this in sync with ocv.txt.
OCV_TABLE='4400 100
4350 99
4300 96
4250 92
4200 87
4150 82
4100 76
4050 70
4000 64
3950 58
3900 51
3850 44
3800 37
3750 30
3700 24
3650 18
3600 13
3550 9
3500 6
3450 3
3400 1
3350 0'

# Prefer the shipped file, then the tmpfs copy, then the embedded table.
# The tmpfs copy exists because this loop re-reads the curve on every sample
# and the source file can disappear mid-session.
if [ ! -s /tmp/battfix_ocv.txt ]; then
	if [ -s "$OCV" ]; then
		cp -f "$OCV" /tmp/battfix_ocv.txt 2>/dev/null
	fi
fi
if [ ! -s /tmp/battfix_ocv.txt ]; then
	printf '%s\n' "$OCV_TABLE" > /tmp/battfix_ocv.txt 2>/dev/null
	OCV_SRC="embedded"
else
	OCV_SRC="file"
fi
OCV=/tmp/battfix_ocv.txt

# Prefer the raw gauge (bms); fall back to the battery node if bms is absent.
BMS=/sys/class/power_supply/bms
[ -d "$BMS" ] || BMS=/sys/class/power_supply/battery
BAT=/sys/class/power_supply/battery

RMO=95          # internal resistance, mOhm
INTERVAL=5      # sample period, seconds (plus ~1 s spent sampling)
MAXDROP=3       # max decrease per sample, %
MAXRISE=2       # max increase per sample, %
ALPHA=3         # new-sample weight out of 10 (3 = fairly smooth)
HYST=2          # deadband: ignore changes smaller than this, %
SAMPLES=3       # reads per sample, median taken

rd() { cat "$1" 2>/dev/null | tr -d ' \r\n\t'; }

isnum() {
	case "$1" in
		''|*[!0-9-]*) return 1 ;;
	esac
	return 0
}

# Median of SAMPLES reads from $1, falling back to $2 when $1 is unreadable.
# Median (not mean) so one bad read cannot drag the result.
med_read() {
	_p=$1
	_q=$2
	_n=0
	_v1=
	_v2=
	_v3=
	while [ "$_n" -lt "$SAMPLES" ]; do
		_n=$((_n + 1))
		_x=$(rd "$_p")
		isnum "$_x" || _x=$(rd "$_q")
		isnum "$_x" || { echo ""; return; }
		case "$_n" in
			1) _v1=$_x ;;
			2) _v2=$_x ;;
			3) _v3=$_x ;;
		esac
		[ "$_n" -lt "$SAMPLES" ] && { sleep 0.3 2>/dev/null || sleep 1; }
	done
	# For SAMPLES=3 this is a 3-element sort-and-take-middle.
	if [ "$_v1" -gt "$_v2" ]; then _t=$_v1; _v1=$_v2; _v2=$_t; fi
	if [ "$_v2" -gt "$_v3" ]; then _t=$_v2; _v2=$_v3; _v3=$_t; fi
	if [ "$_v1" -gt "$_v2" ]; then _t=$_v1; _v1=$_v2; _v2=$_t; fi
	echo "$_v2"
}

mkdir -p "$OUT" 2>/dev/null

# One separator per daemon start, so a stale log cannot be mistaken for the
# current run, and so it is obvious which curve got used.
echo "=== start pid=$$ ocv=$OCV_SRC lines=$(wc -l < "$OCV" 2>/dev/null | tr -d ' ') ===" >> "$LOG"

# Seed immediately so TWRP never sees a missing file (it would show -1%).
# This value is the kernel's wrong figure, but it only lives for the few
# milliseconds before the first real sample replaces it outright.
seed=$(rd "$BAT/capacity")
isnum "$seed" || seed=50
echo "$seed" > "$OUT/capacity"
echo "Discharging" > "$OUT/status"

VS=
DISP=
TICK=0

while true; do
	TICK=$((TICK + 1))

	V=$(med_read "$BMS/voltage_now" "$BAT/voltage_now")
	I=$(med_read "$BMS/current_now" "$BAT/current_now")
	ST=$(rd "$BAT/status")

	if ! isnum "$V"; then
		echo "$TICK v=$V INVALID" >> "$LOG"
		sleep "$INTERVAL"
		continue
	fi
	isnum "$I" || I=0

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
	# would make the number crawl down from a wrong value at MAXDROP per tick.
	if [ -z "$DISP" ]; then
		DISP=$soc
	else
		d=$(( soc - DISP ))
		# Deadband: a difference smaller than HYST is noise, leave it alone.
		if [ "$d" -ge "$HYST" ] || [ "$d" -le $((0 - HYST)) ]; then
			[ "$d" -gt "$MAXRISE" ] && d=$MAXRISE
			[ "$d" -lt $((0 - MAXDROP)) ] && d=$((0 - MAXDROP))
			DISP=$(( DISP + d ))
		fi
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
