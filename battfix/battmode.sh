#!/system/bin/sh
# =============================================================================
# battmode.sh - inspect the MTK gauge's UI-SOC control mode  (tanzanite)
# =============================================================================
#
# WHY
#   mt6358_battery.ko has two very different personalities:
#
#     Android boot : a userspace daemon (fuelgauged / health HAL) owns the UI
#                    SOC and pushes it into the kernel over netlink
#                    (FG_DAEMON_CMD_SET_KERNEL_UISOC). The kernel obeys.
#                    -> the number you see is the honest one.
#
#     recovery boot: there is no daemon, so the kernel logs
#                    "[battery_init]: enable Kernel mode Gauge" and computes
#                    UI SOC itself, seeded from the RTC spare register
#                    (mtk-gauge/rtc_ui_soc). If that seed is stale (83 on a
#                    21 % battery) recovery shows 83 and there is no daemon to
#                    correct it.
#
#   The driver exposes a knob for exactly this: `uisoc_update_type`
#   (dev_attr_uisoc_update_type in the .ko). Changing it makes the kernel pick
#   a different UI-SOC update policy, one of which is OCV/voltage driven
#   (fgr_set_soc_by_vc_mode). If that works in recovery we no longer have to
#   fight the gauge every 5 seconds - it would just be honest on its own.
#
# USAGE
#   sh battmode.sh              report only, writes NOTHING  (default)
#   sh battmode.sh set <n>      write <n> to uisoc_update_type and report
#   sh battmode.sh restore      put the original value back
#
#   Everything is logged to /data/local/tmp/battmode.log
#
# NOTE  /tmp in this recovery is not tmpfs and truncates names to 8.3, which is
#       why the log lives in /data/local/tmp.
# =============================================================================

PS=/sys/class/power_supply
G=$PS/mtk-gauge
BAT=$PS/battery
BMS=$PS/bms
LOG=/data/local/tmp/battmode.log
SAVE=/data/local/tmp/battmode.orig

rd() { cat "$1" 2>/dev/null | tr -d ' \r\n\t'; }
log() { echo "$*"; echo "$*" >> "$LOG" 2>/dev/null; }

mkdir -p /data/local/tmp 2>/dev/null

log "=============================================================="
log " battmode - $(date 2>/dev/null)"
log "=============================================================="

if [ ! -d "$G" ]; then
	log "RESULT: $G does not exist. Is the gauge module loaded?"
	exit 1
fi

# ---------------------------------------------------------------- inventory ---
log ""
log "--- isi $G ---"
for _n in "$G"/*; do
	[ -e "$_n" ] || continue
	_b=$(basename "$_n")
	_p=$(ls -l "$_n" 2>/dev/null | cut -d' ' -f1)
	_v=$(rd "$_n" 2>/dev/null | cut -c1-60)
	log "  $_b  [$_p]  = ${_v:-<kosong>}"
done

# ------------------------------------------------------- the three readings ---
log ""
log "--- angka baterai saat ini ---"
KV=$(rd "$BAT/voltage_now")
# Current source: prefer bms, exactly like battfixd.sh.
#
# Measured 2026-10-28 on this device: battery/current_now and bms/current_now
# have OPPOSITE SIGNS. battery/ was -447600 while bms/ was +449000 with
# status=Charging, so battery/current_now is sign-inverted on this kernel.
# Picking the wrong one flips the IR compensation and moves the honest SOC by
# ~6 points, which is enough to look like a bug. bms/ is the one that agrees
# with the charging status, so bms/ wins.
KI_BAT=$(rd "$BAT/current_now")
KI_BMS=$(rd "$BMS/current_now")
KI=$KI_BMS
[ -n "$KI" ] || KI=$KI_BAT
KC=$(rd "$BAT/capacity")
BC=$(rd "$BMS/capacity")
log "  battery/voltage_now = ${KV:-?} uV  ($(( ${KV:-0} / 1000 )) mV)"
log "  battery/current_now = ${KI_BAT:-?} uA"
log "  bms/current_now     = ${KI_BMS:-?} uA"
case "${KI_BAT}${KI_BMS}" in
-*[!-]*) log "  (tanda battery/ dan bms/ BERLAWANAN - pakai bms/)" ;;
esac
log "  dipakai             = ${KI:-?} uA"
log "  battery/capacity    = ${KC:-?} %   <- yang dibaca TWRP"
log "  bms/capacity        = ${BC:-?} %   <- yang dibaca Android"

# honest SOC from OCV, same table + RMO as battfixd.sh
RMO=95
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

soc_from_ocv() {
	_voc=$1; _soc=""; _pmv=""; _ppc=""
	_old_ifs=$IFS; IFS='
'
	for _row in $OCV_TABLE; do
		_mv=${_row% *}; _pc=${_row#* }
		case "$_mv" in ''|\#*) continue ;; esac
		if [ -z "$_pmv" ]; then
			if [ "$_voc" -ge "$_mv" ]; then _soc=$_pc; break; fi
		else
			if [ "$_voc" -ge "$_mv" ] && [ "$_voc" -le "$_pmv" ]; then
				_soc=$(( _ppc + (_pc - _ppc) * (_voc - _pmv) / (_mv - _pmv) )); break
			fi
		fi
		_pmv=$_mv; _ppc=$_pc
	done
	IFS=$_old_ifs
	[ -z "$_soc" ] && _soc=${_ppc:-0}
	echo "$_soc"
}

isnum() { case "$1" in ''|*[!0-9-]*) return 1 ;; esac; return 0; }

HONEST=""
if isnum "$KV"; then
	isnum "$KI" || KI=0
	VOC=$(( (KV - KI * RMO / 1000) / 1000 ))
	HONEST=$(soc_from_ocv "$VOC")
	log "  OCV (IR-comp)       = ${VOC} mV  ->  honest ${HONEST} %"
	[ -n "$KC" ] && log "  selisih kernel      = $(( KC - HONEST )) poin"
fi

# ------------------------------------------------- the stored-OCV suspect ----
# fgr_dod_init() falls back to `init_swocv` whenever rtc_ui_soc is 0 or
# invalid - the "rtcui=0 case" line in dmesg. That value does NOT come from the
# DT default: fg_custom_init_from_dts prints ~38160 on this unit, which is
# correct. It comes from ptim_battery_voltage_get, and the two match exactly
# once you multiply by ten:
#
#     ptim_battery_voltage_get = 4467   ->   init_swocv = 44670
#
# 4467 mV is ABOVE a fully charged cell, so the gauge boots believing 100 %
# while the real cell sits at 3.83 V. That is the disease. The display daemon
# only hides the symptom, because it cannot touch the coulomb counter itself.
#
# The value also ratchets upward on this unit: 4060 -> 4161 -> 4301 -> 4467
# across successive boots. It is stored FG/RTC state, so the only lever in
# sysfs is to throw that state away (resetfg).
PT=$(rd "$G/ptim_battery_voltage_get")
if isnum "$PT"; then
	log ""
	log "--- OCV tersimpan (tersangka utama) ---"
	log "  ptim_battery_voltage_get = $PT mV"
	log "  init_swocv di dmesg      = ptim x 10"
	if [ "$PT" -gt 4400 ]; then
		log "  STATUS : DI ATAS 4.4 V -> gauge boot dengan SOC 100 %"
		log "  Artinya battery/capacity = 100 itu bukan salah baca sesaat,"
		log "  tapi memang nilai awal yang dipakai driver setiap boot."
		log "  Perbaikan: sh battmode.sh resetfg   (buang data FG tersimpan)"
	elif [ "$PT" -gt 4250 ]; then
		log "  STATUS : mendekati penuh, wajar kalau sel memang penuh"
	else
		log "  STATUS : masuk akal, tidak perlu reset"
	fi
fi

# ------------------------------------------------- what the gauge decided ----
# mt6358_battery.ko logs its decision path. The interesting one is
#
#   [%s]rtcui=0 case,init_swocv=%d,OCV_to_SOC_c=%d ui:[%d %d] con0_soc=[%d %d]
#
# which fires when the RTC seed is 0/invalid and the driver falls back to
# OCV -> honest. If instead you see it trusting a non-zero rtc_ui_soc, that is
# the stale-seed case and explains an over-report.
#
# The driver also exposes `log_level` (log_level_set / log_level_get in the .ko).
# Bumping it makes these lines appear when they are normally pr_debug'd away.
log ""
log "--- apa kata driver gauge (dmesg) ---"
if command -v dmesg >/dev/null 2>&1; then
	dmesg 2>/dev/null | grep -iE "gauge|rtcui|swocv|uisoc|fg_daemon|dod_init" | tail -25 | while read -r _l; do
		log "  $_l"
	done
	if ! dmesg 2>/dev/null | grep -qiE "gauge|rtcui|uisoc"; then
		log "  (tidak ada baris gauge di dmesg - kemungkinan di-pr_debug)"
		log "  coba naikkan log_level kalau node-nya ada (lihat daftar di atas)"
	fi
else
	log "  dmesg tidak tersedia di shell ini"
fi

# ------------------------------------------------------------ the knob itself ---
UT=$G/uisoc_update_type
log ""
log "--- uisoc_update_type ---"
if [ -e "$UT" ]; then
	CUR=$(rd "$UT")
	log "  path    : $UT"
	log "  perms   : $(ls -l "$UT" 2>/dev/null | cut -d' ' -f1)"
	log "  value   : ${CUR:-<kosong>}"
	[ -e "$SAVE" ] || echo "$CUR" > "$SAVE" 2>/dev/null
	log "  original disimpan di $SAVE"
else
	log "  TIDAK ADA node uisoc_update_type di $G"
	log "  (driver ini mungkin tidak mengeksposnya ke sysfs)"
	CUR=""
fi

# ------------------------------------------------------------------ modes -----
MODE=${1:-report}

case "$MODE" in
set)
	NEW=$2
	if ! isnum "$NEW"; then
		log "REFUSED: butuh angka, dapat '$NEW'"
		exit 1
	fi
	if [ ! -e "$UT" ]; then
		log "REFUSED: $UT tidak ada"
		exit 1
	fi
	log ""
	log "--- menulis $NEW ke uisoc_update_type ---"
	if echo "$NEW" > "$UT" 2>/dev/null; then
		sleep 2
		log "  read back : $(rd "$UT")"
		log "  battery/capacity sekarang : $(rd "$BAT/capacity")"
		log "  bms/capacity sekarang     : $(rd "$BMS/capacity")"
		log "  rtc_ui_soc sekarang       : $(rd "$G/rtc_ui_soc")"
		log ""
		log "Kalau battery/capacity langsung mendekati honest ($HONEST),"
		log "mode ini yang benar dan battfixd tidak perlu melawan gauge lagi."
	else
		log "  write FAILED (read-only atau nilai ditolak driver)"
	fi
	;;
restore)
	if [ -e "$SAVE" ] && [ -e "$UT" ]; then
		O=$(rd "$SAVE")
		log ""
		log "--- mengembalikan uisoc_update_type ke '$O' ---"
		echo "$O" > "$UT" 2>/dev/null
		log "  read back : $(rd "$UT")"
	else
		log "tidak ada nilai asli tersimpan di $SAVE"
	fi
	;;
resetfg)
	# EKSPERIMEN. Menulis 1 ke reset_fg_rtc_set meminta driver membuang data FG
	# yang tersimpan di RTC (rtc_ui_soc, car, OCV terakhir). Kalau nilai OCV
	# tersimpan itu yang basi, boot berikutnya akan membaca tegangan asli dan
	# angka kernel jadi jujur - termasuk di Android.
	#
	# Ini TIDAK sama dengan bms/uisoc (yang terbukti merusak: charge_counter
	# jadi 0 dan capacity jatuh ke 1%). Node ini memang disediakan untuk reset,
	# tapi tetap: pastikan baterai terisi dulu, dan siap-siap kalau angka
	# melompat sekali setelah reboot (itu normal, dia sedang re-init).
	R=$G/reset_fg_rtc_set
	log ""
	log "--- reset_fg_rtc_set ---"
	if [ ! -e "$R" ]; then
		log "  node $R tidak ada, tidak ada yang dilakukan"
	else
		log "  perms   : $(ls -l "$R" 2>/dev/null | cut -d' ' -f1)"
		log "  sebelum : rtc_ui_soc=$(rd "$G/rtc_ui_soc") info_con0_soc=$(rd "$G/info_con0_soc") ptim=$(rd "$G/ptim_battery_voltage_get")"
		log ""
		log "  PENTING: biarkan charger tercolok selama reset dan reboot."
		log "  Kalau angka sempat aneh setelah reset, tegangan tetap ditahan"
		log "  charger sehingga HP tidak mati karena cutoff 3.1 V."
		log ""
		if echo 1 > "$R" 2>/dev/null; then
			sleep 2
			log "  sesudah : rtc_ui_soc=$(rd "$G/rtc_ui_soc") info_con0_soc=$(rd "$G/info_con0_soc") ptim=$(rd "$G/ptim_battery_voltage_get")"
			log "  battery/capacity=$(rd "$BAT/capacity")  bms/capacity=$(rd "$BMS/capacity")"
			log ""
			log "  Sekarang reboot ke recovery dan jalankan probe ini lagi."
			log "  Berhasil kalau di dmesg: init_swocv mendekati tegangan asli"
			log "  (sekitar 38160 untuk 3.8 V), BUKAN 44000-an."
			log "  Kalau init_swocv masih 44000-an, berarti ratchet-nya kembali:"
			log "  kirim hasil ini, langkah berikutnya ncar_reset_set / soff_reset_set."
		else
			log "  write FAILED"
		fi
	fi
	;;
*)
	log ""
	log "Mode report: tidak ada yang ditulis."
	log "Coba:  sh battmode.sh set 0   lalu   sh battmode.sh set 1"
	log "Lihat mana yang bikin battery/capacity mendekati honest."
	log "Eksperimen lain: sh battmode.sh resetfg   (buang data FG tersimpan)"
	;;
esac

# ---------------------------------------------------------------- catatan ----
# Dua node lain yang mungkin muncul di daftar atas dan relevan:
#
#   reset_aging_factor   menulis 1 di sini memaksa gauge pakai tabel
#                        g_FG_PSEUDO100 dasar (yang lebih jujur) dan
#                        membuang faktor penuaan. Ini MENGHAPUS data SOH.
#
#   reset_battery_cycle  menulis 1 di sini mengembalikan cycle count ke 0.
#                        Perangkat ini sudah 1377 siklus, jadi gauge memakai
#                        tabel g_FG_PSEUDO100_ov_800_cycle yang menurunkan
#                        plafon "100%" ke 90-93. Setelah reset, tabel dasar
#                        yang dipakai (97-98).
#
# Keduanya TIDAK diotomasi di sini karena mengubah data kesehatan baterai
# secara permanen. Kalau mau dicoba, lakukan manual dan sadar risikonya:
#   echo 1 > $G/reset_aging_factor
#   echo 1 > $G/reset_battery_cycle
#
# Yang TIDAK berbahaya dan sangat berguna: naikkan log_level supaya driver
# mencetak jalur keputusannya ke dmesg.
#   echo 3 > $G/log_level     (kalau node ini ada)

log ""
log "log lengkap: $LOG"
exit 0
