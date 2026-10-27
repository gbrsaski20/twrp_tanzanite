#!/system/bin/sh
# =============================================================================
# test_rtc_ui_soc.sh - find, read, and (optionally) reset the RTC UI SOC seed
#
# WHY THIS MATTERS
#   This is the first interface we have found that reaches the root of the
#   problem directly. From real source (alltechdev/android_kernel_xelex_mt6789,
#   drivers/power/supply/mt6358-gauge.c, lineage-23.2):
#
#       static struct mtk_gauge_sysfs_field_info mt6358_sysfs_field_tbl[] = {
#               ...
#               GAUGE_SYSFS_FIELD_RW(rtc_ui_soc, rtc_ui_soc_set, rtc_ui_soc_get,
#                       GAUGE_PROP_RTC_UI_SOC),
#
#   and the device is registered as:
#       gauge->psy_desc.name = "mtk-gauge";
#       mt6358_sysfs_create_group(gauge);
#
#   so the node is /sys/class/power_supply/mtk-gauge/rtc_ui_soc - read AND
#   write, unlike battery/uisoc which is write-only.
#
#   The accessors:
#       get: *val = get_rtc_spare_fg_value(gauge) & 0x7f;      <- 0..100, percent
#       set: new = (old & 0x80) + val; set_rtc_spare_fg_value(new);
#
#   bit 0x80 is the "valid" flag and is preserved, so writing 0 leaves
#   spare3 = 0x80 and the getter returns 0.
#
# WHY 0 IS **NOT** THE VALUE TO WRITE (measured, not theory)
#   The `if (rtc_ui_soc == 0)` branch looks like a clean reset, but on real
#   hardware it is a trap: at the moment fgr_dod_init() runs, the gauge has not
#   necessarily produced a valid OCV yet, so OCV_to_SOC_c(init_swocv) can
#   evaluate to 0 and the phone boots showing 1% on a full battery. Observed
#   exactly that on this device: seed 99 -> write 0 -> next boot 1%.
#   Write the REAL soc instead (`restore`), which leaves no room for the OCV
#   path to guess.
#
# SAFETY
#   Read mode changes nothing. Write mode changes what the next boot will
#   display, which is exactly the point, but it does not touch the coulomb
#   counter and it does not write to the battery hardware.
#
#   The running algorithm rewrites this register on every FG interrupt, so a
#   written value can be clobbered within seconds. Append `reboot` so the write
#   and the reboot happen in one shot.
#
# USAGE
#   sh test_rtc_ui_soc.sh                      read-only report + honest SOC
#   sh test_rtc_ui_soc.sh auto reboot          repair ONLY if the offset is bad,
#                                              then reboot (the everyday command)
#   sh test_rtc_ui_soc.sh restore reboot       seed the next boot with the real
#                                              SOC, then reboot immediately
#   sh test_rtc_ui_soc.sh write 100 reboot     seed an explicit value
#   sh test_rtc_ui_soc.sh write 0 --force      the OCV branch (see warning above)
#
#   THRESH=10 overrides the `auto` threshold.
#   Runs in both Android (needs root) and recovery.
# =============================================================================

PS=${PS_DIR:-/sys/class/power_supply}
BAT=$PS/battery
BMS=$PS/bms
SAMPLES=3
RMO=95

# Keep in sync with battcheck.sh / battfixd.sh / ocv.txt.
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

echo "=============================================================="
echo " RTC UI SOC seed - find / read / reset"
echo "=============================================================="

# --- 1. find every node that exposes it -------------------------------------
echo "--- power_supply devices ---"
for d in "$PS"/*; do
	[ -d "$d" ] || continue
	name=$(basename "$d")
	if [ -e "$d/rtc_ui_soc" ]; then
		echo "  $name  <- rtc_ui_soc FOUND"
	else
		echo "  $name"
	fi
done

NODES=""
for d in "$PS"/*; do
	[ -e "$d/rtc_ui_soc" ] && NODES="$NODES $d/rtc_ui_soc"
done

echo
if [ -z "$NODES" ]; then
	echo "RESULT: no rtc_ui_soc node on this build."
	echo "  The attribute table is not registered here, so this route is closed"
	echo "  and we fall back to battery/uisoc. Send the device list above."
	exit 1
fi

# --- 2. read them -----------------------------------------------------------
echo "--- current values ---"
for n in $NODES; do
	printf '  %s\n' "$n"
	printf '    perms  %s\n' "$(ls -l "$n" 2>/dev/null | cut -d' ' -f1)"
	printf '    value  %s\n' "$(rd "$n")"
done

# --- 3. honest SOC from compensated OCV -------------------------------------
V=$(med "$BMS/voltage_now" "$BAT/voltage_now")
I=$(med "$BMS/current_now" "$BAT/current_now")
REPORTED=$(rd "$BAT/capacity")
isnum "$I" || I=0

echo
echo "--- honest SOC ---"
if ! isnum "$V"; then
	echo "  voltage unreadable, cannot compute"
	HONEST=""
else
	voc=$(( (V - I * RMO / 1000) / 1000 ))
	soc=""
	pmv=""
	ppc=""
	old_ifs=$IFS
	IFS='
'
	for row in $OCV_TABLE; do
		mv=${row% *}
		pc=${row#* }
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
	done
	IFS=$old_ifs
	[ -z "$soc" ] && soc=${ppc:-0}
	HONEST=$soc
	echo "  voltage  $V uV   current $I uA"
	echo "  ocv      $voc mV"
	echo "  honest   $HONEST %"
	echo "  android  $REPORTED %"
fi

# --- 4. verdict -------------------------------------------------------------
MAXABS=0
for n in $NODES; do
	SEED=$(rd "$n")
	isnum "$SEED" || SEED=-1
	echo
	echo "--- $n ---"
	echo "  seed     $SEED %"
	if [ -n "$HONEST" ] && [ "$SEED" -ge 0 ]; then
		OFF=$(( SEED - HONEST ))
		ABS=$OFF
		[ "$ABS" -lt 0 ] && ABS=$(( 0 - ABS ))
		[ "$ABS" -gt "$MAXABS" ] && MAXABS=$ABS
		echo "  offset   $OFF (seed minus honest)"
		if [ "$OFF" -ge 15 ]; then
			echo "  -> the seed is what poisons the next boot."
			echo "     'restore reboot' writes the real SOC back."
		elif [ "$OFF" -le -15 ]; then
			echo "  -> the seed under-reports; the next boot will start too low."
		else
			echo "  -> seed and reality agree, nothing to fix right now."
		fi
	fi
done

# --- 5. optional write ------------------------------------------------------
# MODES
#   write <n> [reboot]    set the seed to n percent
#   restore   [reboot]    set the seed to the honest SOC computed above
#   auto      [reboot]    only act when the offset exceeds THRESH (default 10)
#
#   `reboot` closes the timing window: the running algorithm rewrites this
#   register on every FG interrupt, so a value written and left sitting can be
#   gone within seconds. Write-and-reboot in one shot is the only reliable way.
#
#   `write 0` now needs --force, because it is NOT the safe reset it looks like.
#   Measured on real hardware: seed 0 made the next boot take the OCV branch
#   while the gauge had not produced a valid OCV yet, so OCV_to_SOC_c() got 0
#   and the phone booted showing 1% with a full battery. Use `restore` instead.
# ---------------------------------------------------------------------------
MODE=$1
VAL=
DO_REBOOT=0
FORCE=0
THRESH=${THRESH:-10}
for a in "$@"; do
	case "$a" in
		reboot) DO_REBOOT=1 ;;
		--force) FORCE=1 ;;
	esac
done

case "$MODE" in
	write)   VAL=$2 ;;
	restore) VAL=$HONEST ;;
	auto)
		if [ -z "$HONEST" ]; then
			echo
			echo "auto: honest SOC could not be computed, refusing to act."
			exit 1
		fi
		if [ "$MAXABS" -le "$THRESH" ]; then
			echo
			echo "auto: worst offset is $MAXABS, within the $THRESH threshold."
			echo "      healthy, nothing written."
			exit 0
		fi
		echo
		echo "auto: worst offset is $MAXABS, above the $THRESH threshold."
		VAL=$HONEST
		;;
	"")      VAL= ;;
	*)
		echo
		echo "usage: sh $0 [write <0..100> | restore | auto] [reboot] [--force]"
		exit 1
		;;
esac

if [ -n "$MODE" ]; then
	if [ -z "$VAL" ] || ! isnum "$VAL" || [ "$VAL" -lt 0 ] || [ "$VAL" -gt 100 ]; then
		echo
		echo "REFUSED: value must be 0..100 (got '$VAL')."
		[ "$MODE" = "restore" ] && echo "          (honest SOC could not be computed)"
		exit 1
	fi

	if [ "$VAL" -eq 0 ] && [ "$FORCE" -ne 1 ]; then
		echo
		echo "REFUSED: 0 is not a safe reset."
		echo "  Measured on this device: writing 0 made the next boot take the"
		echo "  OCV branch before the gauge had a valid OCV, so it computed 0%"
		echo "  and the phone booted showing 1% on a full battery."
		echo "  Use 'restore' to write the real SOC instead."
		echo "  If you really want 0, add --force."
		exit 1
	fi

	echo
	echo "--- writing $VAL ---"
	for n in $NODES; do
		if echo "$VAL" > "$n" 2>/dev/null; then
			echo "  $n <- $VAL"
			echo "    read back: $(rd "$n")"
		else
			echo "  $n write FAILED (read-only?)"
		fi
	done

	if [ "$DO_REBOOT" -eq 1 ]; then
		echo
		echo "rebooting now, so the algorithm cannot overwrite it"
		sync
		reboot
	else
		echo
		echo "The next boot will use this seed. Do NOT leave it sitting here:"
		echo "the running algorithm rewrites it on the next FG interrupt."
		echo "Reboot now, or re-run with 'reboot' on the end."
	fi
fi

echo
echo "=============================================================="
