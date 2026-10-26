#!/system/bin/sh
# =============================================================================
# battcheck.sh - compare what Android REPORTS against the real SOC from voltage
#
# WHY
#   On tanzanite the MTK/Xiaomi gauge keeps its UI SOC in an RTC-backed register
#   (GAUGE_PROP_RTC_UI_SOC). At boot the algorithm seeds itself from that value,
#   and then writes it back on every fuel-gauge interrupt. That is a closed
#   loop: RTC -> seed -> algorithm -> RTC. Any offset is self-perpetuating and
#   can never heal on its own.
#
#   The offset gets in whenever the phone boots into RECOVERY while the charger
#   is plugged in, or when it is already poisoned and simply carries over.
#
#   This script measures that offset so you can tell whether a full-charge
#   cycle actually re-synced the gauge, instead of guessing from the icon.
#
# HOW TO RUN (in Android, normal boot)
#   adb push battcheck.sh /sdcard/battcheck.sh
#   adb shell sh /sdcard/battcheck.sh
#
#   Reading /sys/class/power_supply/* usually needs root on Android; if the
#   reads come back empty, run `adb root` first or use a terminal app with su.
#
# UNITS
#   voltage_now: microvolts   current_now: microamps (positive = charging)
#   RMO = 95 mOhm, fitted on real tanzanite hardware. Do not change it.
# =============================================================================

BAT=/sys/class/power_supply/battery
BMS=/sys/class/power_supply/bms
[ -d "$BMS" ] || BMS="$BAT"

RMO=95
SAMPLES=3

# Same curve as battfix/ocv.txt. Keep the two in sync.
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

rd() { cat "$1" 2>/dev/null | tr -d ' \r\n\t'; }

isnum() {
	case "$1" in
		''|*[!0-9-]*) return 1 ;;
	esac
	return 0
}

# Median of three reads: one noisy sample cannot drag the result.
med() {
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
		[ "$_n" -lt "$SAMPLES" ] && sleep 1
	done
	if [ "$_v1" -gt "$_v2" ]; then _t=$_v1; _v1=$_v2; _v2=$_t; fi
	if [ "$_v2" -gt "$_v3" ]; then _t=$_v2; _v2=$_v3; _v3=$_t; fi
	if [ "$_v1" -gt "$_v2" ]; then _t=$_v1; _v1=$_v2; _v2=$_t; fi
	echo "$_v2"
}

V=$(med "$BMS/voltage_now" "$BAT/voltage_now")
I=$(med "$BMS/current_now" "$BAT/current_now")
REPORTED=$(rd "$BAT/capacity")
STATUS=$(rd "$BAT/status")
TEMP=$(rd "$BAT/temp")

echo "=============================================================="
echo " battcheck - reported vs real state of charge"
echo "=============================================================="

if ! isnum "$V"; then
	echo "Cannot read the battery voltage."
	echo "  tried: $BMS/voltage_now and $BAT/voltage_now"
	echo "  On Android this usually needs root: run 'adb root' or use su."
	exit 1
fi
isnum "$I" || I=0
isnum "$REPORTED" || REPORTED=""

voc=$(( (V - I * RMO / 1000) / 1000 ))

# Piecewise-linear OCV -> SOC, same lookup as the recovery daemon.
soc=""
pmv=""
ppc=""
while read -r mv pc; do
	case "$mv" in ''|\#*) continue ;; esac
	if [ -z "$pmv" ]; then
		if [ "$voc" -ge "$mv" ]; then soc=$pc; break; fi
	else
		if [ "$voc" -ge "$mv" ] && [ "$voc" -le "$pmv" ]; then
			soc=$(( ppc + (pc - ppc) * (voc - pmv) / (mv - pmv) ))
			break
		fi
	fi
	pmv=$mv
	ppc=$pc
done <<EOF
$OCV_TABLE
EOF
[ -z "$soc" ] && soc=${ppc:-0}
[ "$soc" -lt 1 ] && soc=1
[ "$soc" -gt 100 ] && soc=100

echo "voltage_now    : $V uV  ($(( V / 1000 )) mV terminal)"
echo "current_now    : $I uA  ($(( I / 1000 )) mA, + = charging)"
echo "status         : ${STATUS:-?}"
[ -n "$TEMP" ] && echo "temp           : $(( TEMP / 10 )) C"
echo "internal R     : $RMO mOhm"
echo "OCV (compensated): $voc mV"
echo
echo "REAL soc       : $soc %   <- from voltage, this is the truth"
echo "ANDROID says   : ${REPORTED:-?} %"
echo
if [ -z "$REPORTED" ]; then
	echo "offset         : unknown (capacity unreadable)"
else
	OFF=$(( REPORTED - soc ))
	echo "offset         : $OFF  (reported minus real)"
	echo
	# +-5 is inside the noise floor: the OCV table is piecewise linear, RMO is
	# a single fitted constant, and a load change of a few hundred mA moves the
	# compensated voltage by ~20 mV which is already ~2.5% at mid-curve.
	if [ "$OFF" -ge -5 ] && [ "$OFF" -le 5 ]; then
		echo "VERDICT: in sync (offset within the +-5 noise floor)."
		echo "  The gauge agrees with the real voltage."
	elif [ "$OFF" -gt 5 ] && [ "$OFF" -le 15 ]; then
		echo "VERDICT: slightly over-reporting by $OFF points."
		echo "  Not dangerous yet, but it will drift further if the phone keeps"
		echo "  booting into recovery with the charger plugged in."
		echo "  A full charge while powered OFF will pull it back to zero."
	elif [ "$OFF" -gt 15 ]; then
		echo "VERDICT: OVER-reporting by $OFF points. This is the dangerous state."
		echo "  The phone will shut down suddenly while still showing a high %,"
		echo "  exactly like it did on YouTube."
		echo "  Cure: charge to real full and hold 1-2 h, ideally powered OFF."
		echo "  At the top of the curve the plateau is unambiguous, so the gauge"
		echo "  re-syncs to 100 and the countdown is then correct."
	else
		echo "VERDICT: under-reporting by $(( 0 - OFF )) points."
		echo "  Harmless, just pessimistic. Usually happens right after a fresh"
		echo "  calibration, before the first full discharge. A full charge"
		echo "  will settle it."
	fi
fi
echo
echo "note: if the battery is charging right now, the voltage is elevated and"
echo "      the current is large, so the computed soc is less accurate. The"
echo "      most trustworthy reading is at rest, unplugged, after 5 minutes."
