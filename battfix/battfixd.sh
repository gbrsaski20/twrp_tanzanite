#!/system/bin/sh
# =============================================================================
# battfixd.sh - battery gauge fix for TWRP / OrangeFox recovery (tanzanite)
#
# WHY THIS EXISTS
#   In recovery the kernel's /sys/class/power_supply/battery/capacity is not
#   usable: it reports 83% on a battery that is really around 21%, and it can
#   sit at 1% for the whole session. Android is unaffected because it reads
#   bms/capacity instead, which is correct.
#
#   TWRP is hardcoded to read <TW_CUSTOM_BATTERY_PATH>/capacity, so this daemon
#   computes an honest SOC from the battery voltage and writes it to /tmp/batt,
#   which the recovery binary was compiled to read:
#       TW_CUSTOM_BATTERY_PATH := "/tmp/batt"
#
# ALGORITHM
#   OCV = V_terminal - I * R_internal
#   SOC = piecewise-linear lookup of OCV in the table below
#   then smoothed and rate-limited so the number does not jump around.
#
#   RMO = 95 mOhm was fitted on real tanzanite hardware (two current
#   transitions at 0.46 A and 0.35 A gave 91 and 103 mOhm). Verified again on
#   this unit: 3.677 V at ~20% gives 21-22% with this table, matching Android.
#   The generic default of 60 reads about 4% too low, so do not "simplify" it.
#
#   The table is embedded in this script on purpose. An earlier version read it
#   from /tmp/battfix_ocv.txt; when that file was missing the lookup produced
#   no match at all, every sample collapsed to 0 and the clamp turned it into
#   1%, which is exactly the "stuck at 1%" symptom. A shell function cannot go
#   missing, so that failure mode is gone for good.
#
# ANTI-FLICKER
#   The displayed number used to jump 2 points on its own. The cause was not
#   voltage noise but CURRENT noise: logs show current_now swinging from
#   51 mA to 349 mA inside one session. At RMO = 95 mOhm that is a 28 mV spread
#   in the IR correction, and around 20% the curve moves ~8.3 mV per 1% of SOC,
#   so 28 mV is 3.4 points of pure noise. Four filters now handle it:
#
#     1. Per-sample OCV. Each (V,I) read is combined immediately, so V and I
#        always belong to the same instant. The previous version took the median
#        of V and the median of I separately, which can pair a high V with a low
#        I and produce an OCV that was never physically measured.
#     2. Prefer low current. If any sample was taken below LOWI (100 mA) its
#        terminal voltage IS the open-circuit voltage and the IR term stops
#        mattering, so RMO accuracy becomes irrelevant. Otherwise the median of
#        all samples is used.
#     3. Hysteresis deadband (HYST). Changes smaller than HYST points are
#        ignored outright, so ordinary drift never reaches the screen.
#     4. Direction confirmation (CONFIRM). A change is only applied after the
#        computed SOC has pointed the same way for CONFIRM consecutive ticks.
#        A one-tick spike therefore cannot move the display at all, while a real
#        trend still gets through after roughly two ticks.
#
# UNITS
#   voltage_now : microvolts      current_now : microamps (negative = discharging)
#   i * RMO / 1000  converts uA * mOhm into uV.
# =============================================================================

OUT=/tmp/batt
LOG=/tmp/battfix.log

PS=/sys/class/power_supply
BMS=$PS/bms
BAT=$PS/battery
[ -d "$BMS" ] || BMS=$BAT

RMO=95          # internal resistance, mOhm
INTERVAL=6      # idle period between ticks, seconds (sampling adds ~1.5 s)
MAXDROP=2       # max decrease applied in one step, %
MAXRISE=1       # max increase applied in one step, %
ALPHA=3         # new-sample weight out of 10 (3 = ~30 s time constant)
HYST=3          # deadband: ignore changes smaller than this, %
SAMPLES=5       # paired reads per tick
LOWI=100000     # uA; at or below this the IR correction is negligible
CONFIRM=2       # consecutive ticks in the same direction before moving
CREEP=4         # ticks of sub-HYST agreement before a 1-point nudge

rd() { cat "$1" 2>/dev/null | tr -d ' \r\n\t'; }

isnum() {
	case "$1" in
		''|*[!0-9-]*) return 1 ;;
	esac
	return 0
}

# --- gauge seed: keep rtc_ui_soc honest so Android inherits the real number --
#
# Why this matters: when the kernel gauge over-reports (e.g. shows 83% at
# 3.68 V), it also writes that 83 into mtk-gauge/rtc_ui_soc. On the next boot,
# fgr_dod_init() reads rtc_ui_soc back and derives DOD from it, so Android
# starts at ~83% and can only crawl toward reality. The visible symptom is a
# phone that "jumps to 87%" right after leaving recovery.
#
# Mitigation: every tick, if the kernel's battery/capacity is more than
# SEED_THRESH above the honest OCV value, push the honest value into
# rtc_ui_soc. The gauge's own FG interrupt rewrites this register roughly
# every 3 s, so re-writing every INTERVAL=5 s wins the race most of the time.
# It is not perfect - the value the gauge freezes at poweroff may still be a
# kernel one - but it dramatically reduces the window in which a stale 83/100
# can survive into Android.
GAUGE=$PS/mtk-gauge
SEED_NODE=$GAUGE/rtc_ui_soc
SEED_THRESH=8            # points of over-report before we push the honest seed
SEED_CEIL=95             # never seed above this; near full the OCV table is flat
SEED_WRITTEN=0           # count of successful writes this session

# Take SAMPLES paired (V,I) reads and set the globals V, I, VOC.
# VOC is the open-circuit voltage in mV; VOC is left EMPTY if nothing usable was
# read, and the caller must then hold the previous display.
#
# Sets globals on purpose (no subshell, no echo parsing): this recovery's ash is
# slow and every fork costs ~40 ms, which would double the sampling time.
#
# See the ANTI-FLICKER comment at the top for why the pairing matters.
sample_ocv() {
	_n=0
	_a1=
	_a2=
	_a3=
	_a4=
	_a5=
	V=
	I=
	VOC=
	_li=999999999
	_lo=

	while [ "$_n" -lt "$SAMPLES" ]; do
		_n=$((_n + 1))
		_v=$(rd "$BMS/voltage_now")
		isnum "$_v" || _v=$(rd "$BAT/voltage_now")
		if isnum "$_v"; then
			_i=$(rd "$BMS/current_now")
			isnum "$_i" || _i=$(rd "$BAT/current_now")
			isnum "$_i" || _i=0
			_o=$(( (_v - _i * RMO / 1000) / 1000 ))
			_ai=$_i
			[ "$_ai" -lt 0 ] && _ai=$((0 - _ai))
			case "$_n" in
				1) _a1=$_o ;;
				2) _a2=$_o ;;
				3) _a3=$_o ;;
				4) _a4=$_o ;;
				5) _a5=$_o ;;
			esac
			# Remember the calmest sample. At near-zero current the terminal
			# voltage is the OCV, so this value is right even if RMO is off.
			if [ "$_ai" -lt "$_li" ]; then
				_li=$_ai
				_lo=$_o
				V=$_v
				I=$_i
			fi
		fi
		[ "$_n" -lt "$SAMPLES" ] && { sleep 0.3 2>/dev/null || sleep 1; }
	done

	[ -z "$_a1" ] && return 1

	# Low-current sample available -> trust it directly.
	if [ "$_li" -le "$LOWI" ] && [ -n "$_lo" ]; then
		VOC=$_lo
		return 0
	fi

	# Otherwise the median of the collected OCVs. Selection sort into a new
	# list, then take the middle element. Duplicate values are removed one at a
	# time so a repeated reading cannot skew the rank.
	_rest=""
	_cnt=0
	for _x in $_a1 $_a2 $_a3 $_a4 $_a5; do
		[ -n "$_x" ] && { _rest="$_rest $_x"; _cnt=$((_cnt + 1)); }
	done
	_mid=$(( (_cnt + 1) / 2 ))
	_k=0
	VOC=$_a1
	while : ; do
		_min=
		for _x in $_rest; do
			if [ -z "$_min" ] || [ "$_x" -lt "$_min" ]; then _min=$_x; fi
		done
		[ -z "$_min" ] && break
		_k=$((_k + 1))
		if [ "$_k" -eq "$_mid" ]; then
			VOC=$_min
			break
		fi
		_new=""
		_dropped=0
		for _x in $_rest; do
			if [ "$_dropped" -eq 0 ] && [ "$_x" -eq "$_min" ]; then
				_dropped=1
				continue
			fi
			_new="$_new $_x"
		done
		_rest=$_new
	done
	return 0
}

# Embedded OCV -> SOC curve, descending by voltage. Keep in sync with ocv.txt.
# Format: "<mV> <percent>" one pair per line.
#
# Implemented as a shell VARIABLE (not a function with a heredoc) on purpose.
# A function returning the table via a heredoc returns an EMPTY string in this
# recovery's ash, which made every early sample log NO_MATCH and the displayed
# value crawled down 3 %/tick from a bad kernel seed instead of showing the
# real number from the first sample. Verified regression; do not revert.
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

# piecewise-linear lookup; echoes the SOC or the clamped last-table value.
soc_from_ocv() {
	_voc=$1
	_soc=""; _pmv=""; _ppc=""
	_old_ifs=$IFS
	IFS='
'
	for _row in $OCV_TABLE; do
		_mv=${_row% *}
		_pc=${_row#* }
		case "$_mv" in ''|\#*) continue ;; esac
		if [ -z "$_pmv" ]; then
			if [ "$_voc" -ge "$_mv" ]; then _soc=$_pc; break; fi
		else
			if [ "$_voc" -ge "$_mv" ] && [ "$_voc" -le "$_pmv" ]; then
				_soc=$(( _ppc + (_pc - _ppc) * (_voc - _pmv) / (_mv - _pmv) ))
				break
			fi
		fi
		_pmv=$_mv
		_ppc=$_pc
	done
	IFS=$_old_ifs
	[ -z "$_soc" ] && _soc=${_ppc:-0}
	echo "$_soc"
}

# Display filter. Takes the freshly computed SOC as $1, and updates the globals
# DISP, PDIR and PCNT. Kept as a function (not inlined in the loop) so it can be
# exercised by the local test harness without a phone attached.
#
# Two speed regimes:
#   |offset| >= HYST -> needs CONFIRM ticks in the same direction, then applies
#                       the whole offset clamped to MAXRISE / MAXDROP.
#   |offset| <  HYST -> needs CREEP ticks in the same direction, then nudges
#                       exactly one point.
#
# The second regime is not optional. With a pure deadband the display parks up
# to HYST-1 points away from the truth and stays there forever, because once the
# offset is inside the band nothing ever moves it again. Two points is harmless
# at 80 % but at the bottom of the range it means the phone dies at 2 % instead
# of 0 % - the exact class of bug this whole daemon exists to remove.
filter_step() {
	_s=$1
	if [ -z "$DISP" ]; then
		DISP=$_s
		PDIR=0
		PCNT=0
		return 0
	fi
	_d=$(( _s - DISP ))
	_ad=$_d
	[ "$_ad" -lt 0 ] && _ad=$((0 - _ad))

	if [ "$_ad" -eq 0 ]; then
		PDIR=0
		PCNT=0
		return 0
	fi

	_nd=1
	[ "$_d" -lt 0 ] && _nd=-1
	if [ "$_nd" = "$PDIR" ]; then
		PCNT=$((PCNT + 1))
	else
		PDIR=$_nd
		PCNT=1
	fi

	if [ "$_ad" -lt "$HYST" ]; then
		if [ "$PCNT" -ge "$CREEP" ]; then
			DISP=$(( DISP + _nd ))
			PCNT=0
		fi
		return 0
	fi

	if [ "$PCNT" -ge "$CONFIRM" ]; then
		[ "$_d" -gt "$MAXRISE" ] && _d=$MAXRISE
		[ "$_d" -lt $((0 - MAXDROP)) ] && _d=$((0 - MAXDROP))
		DISP=$(( DISP + _d ))
		PCNT=0
	fi
	return 0
}

# Self-test the OCV lookup once at startup.
#
# MUST stay AFTER soc_from_ocv() and OCV_TABLE are defined. An earlier version
# of this block sat right after isnum() near the top of the file, so it called
# soc_from_ocv before the function existed, got an empty string and logged
# "selftest 3672mV -> [EMPTY] FAIL" on every boot while the daemon itself was
# working perfectly. A false alarm in the one line that is supposed to catch
# real regressions is worse than no line at all.
#
# What it catches: the original "starts at 80%, crawls down to 21%" bug was a
# heredoc-in-function problem that made the lookup return "" for every sample.
{
	_st=$(soc_from_ocv 3672)
	if [ "$_st" = "21" ]; then
		echo "selftest 3672mV -> [$_st] OK" >> "$LOG"
	else
		echo "selftest 3672mV -> [${_st:-EMPTY}] FAIL (expected 21)" >> "$LOG"
	fi
}

mkdir -p "$OUT" 2>/dev/null

echo "=== start pid=$$ $(date 2>/dev/null) ===" >> "$LOG"

# Seed once so TWRP never sees a missing file. Use bms when it is sane, because
# that is the node Android trusts; fall back to the kernel's battery node only
# if bms is absent. The first real sample replaces this within a second.
seed=$(rd "$BMS/capacity")
isnum "$seed" || seed=$(rd "$BAT/capacity")
isnum "$seed" || seed=50
[ "$seed" -lt 1 ] && seed=50
echo "$seed" > "$OUT/capacity"
echo "Discharging" > "$OUT/status"

VS=
DISP=
TICK=0
BAD=0
PDIR=0
PCNT=0

while true; do
	TICK=$((TICK + 1))

	sample_ocv
	if [ -z "$VOC" ]; then
		BAD=$((BAD + 1))
		echo "$TICK sample INVALID (bad=$BAD)" >> "$LOG"
		# Keep the last good value on screen instead of guessing.
		sleep "$INTERVAL"
		continue
	fi
	ST=$(rd "$BAT/status")
	[ -n "$ST" ] || ST=$(rd "$BMS/status")

	# sample_ocv already did the IR compensation, per sample, in mV, so the
	# table can be indexed directly. ALPHA just damps tick-to-tick movement.
	if [ -z "$VS" ]; then
		VS=$VOC
	else
		VS=$(( (ALPHA * VOC + (10 - ALPHA) * VS) / 10 ))
	fi

	soc=$(soc_from_ocv "$VS")

	# Never invent a number. If the curve produced nothing, hold the previous
	# display; if there is no previous display either, seed from the kernel.
	if [ -z "$soc" ]; then
		BAD=$((BAD + 1))
		echo "$TICK v=$V voc=$VOC vs=$VS NO_MATCH (bad=$BAD)" >> "$LOG"
		if [ -z "$DISP" ]; then
			DISP=$seed
			echo "$DISP" > "$OUT/capacity"
		fi
		sleep "$INTERVAL"
		continue
	fi
	BAD=0

	[ "$soc" -lt 0 ] && soc=0
	[ "$soc" -gt 100 ] && soc=100

	# --- display filter ---------------------------------------------------
	filter_step "$soc"
	[ "$DISP" -lt 0 ] && DISP=0
	[ "$DISP" -gt 100 ] && DISP=100

	echo "$DISP" > "$OUT/capacity"
	case "$ST" in
		Charging*|Full*) echo "Charging" > "$OUT/status" ;;
		*)               echo "Discharging" > "$OUT/status" ;;
	esac

	# --- push the honest SOC into the gauge seed register -----------------
	# See the long comment near SEED_NODE above. We only act when the kernel
	# is provably wrong (over-reports by > SEED_THRESH) and we are not near the
	# flat top of the curve. Reads back to confirm; the gauge rewrites ~3 s, so
	# a read-back that does not match does NOT mean the write failed - it means
	# the FG interrupt already overwrote it, which is exactly why we loop.
	if [ -n "$SEED_NODE" ] && [ -w "$SEED_NODE" ] && [ "$DISP" -lt "$SEED_CEIL" ]; then
		KCAP=$(rd "$BAT/capacity")
		if isnum "$KCAP"; then
			OFF=$(( KCAP - DISP ))
			if [ "$OFF" -gt "$SEED_THRESH" ]; then
				if echo "$DISP" > "$SEED_NODE" 2>/dev/null; then
					SEED_WRITTEN=$((SEED_WRITTEN + 1))
					RB=$(rd "$SEED_NODE")
					echo "  seed $SEED_NODE <- $DISP (kernel=$KCAP off=$OFF rb=${RB:-?} w=$SEED_WRITTEN)" >> "$LOG"
				else
					echo "  seed write FAILED (perm?)" >> "$LOG"
				fi
			fi
		fi
	fi

	echo "$TICK v=$V i=$I voc=$VOC vs=$VS soc=$soc disp=$DISP pd=$PDIR pc=$PCNT st=$ST" >> "$LOG"
	SZ=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
	[ -n "$SZ" ] && [ "$SZ" -gt 65536 ] && mv -f "$LOG" "$LOG.1"

	sleep "$INTERVAL"
done
