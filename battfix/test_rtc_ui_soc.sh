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
# WHY 0 IS THE INTERESTING VALUE
#   fgr_dod_init() in the recovery/Android battery path does:
#       rtc_ui_soc = UNIT_TRANS_100 * get_rtc_ui_soc();
#       if (rtc_ui_soc == 0 || con0_soc == 0)
#               rtc_ui_soc = OCV_to_SOC_c(init_swocv);   <- honest resync
#       else
#               ui_d0_soc = rtc_ui_soc;                  <- trusts the stale value
#   So a seed of 0 forces the OCV branch on the NEXT boot, which is the same
#   resync a full charge produces - without waiting for a full charge.
#
# SAFETY
#   Read mode changes nothing. Write mode changes what the next boot will
#   display, which is exactly the point, but it does not touch the coulomb
#   counter and it does not write to the battery hardware.
#
#   The running algorithm rewrites this register on every FG interrupt, so a
#   written value can be clobbered within seconds. The script reads back
#   immediately to show whether that happened. Reboot straight after writing.
#
# USAGE
#   sh test_rtc_ui_soc.sh                 read-only report + honest SOC
#   sh test_rtc_ui_soc.sh write 0         force the OCV resync on next boot
#   sh test_rtc_ui_soc.sh write 20        seed the next boot with 20%
#
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
for n in $NODES; do
	SEED=$(rd "$n")
	isnum "$SEED" || SEED=-1
	echo
	echo "--- $n ---"
	echo "  seed     $SEED %"
	if [ -n "$HONEST" ] && [ "$SEED" -ge 0 ]; then
		OFF=$(( SEED - HONEST ))
		echo "  offset   $OFF (seed minus honest)"
		if [ "$OFF" -ge 15 ]; then
			echo "  -> the seed is what poisons the next boot."
			echo "     'write 0' then reboot forces the OCV resync."
		elif [ "$OFF" -le -15 ]; then
			echo "  -> the seed under-reports; the next boot will start too low."
		else
			echo "  -> seed and reality agree, nothing to fix right now."
		fi
	fi
done

# --- 5. optional write ------------------------------------------------------
if [ "$1" = "write" ]; then
	VAL=$2
	if ! isnum "$VAL" || [ "$VAL" -lt 0 ] || [ "$VAL" -gt 100 ]; then
		echo
		echo "REFUSED: value must be 0..100 (got '$VAL')."
		exit 1
	fi
	echo
	echo "--- writing $VAL ---"
	for n in $NODES; do
		if echo "$VAL" > "$n" 2>/dev/null; then
			echo "  $n <- $VAL"
			sleep 1
			echo "    read back: $(rd "$n")"
			echo "    (if this is not $VAL, the running algorithm overwrote it"
			echo "     already - reboot immediately after writing)"
		else
			echo "  $n write FAILED (read-only?)"
		fi
	done
	echo
	echo "Next boot will use this seed. If you wrote 0, the battery code takes"
	echo "the OCV branch instead, which is the same resync a full charge gives."
fi

echo
echo "=============================================================="
