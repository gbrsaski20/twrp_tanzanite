#!/sbin/sh
# ============================================================================
# cek_boot.sh - baca jejak init gauge dari boot yang SEKARANG jalan
#
# Tujuan: membedakan tiga kemungkinan penyebab bug 100% setelah reboot dari
# OrangeFox. Semuanya terlihat dari SATU baris dmesg:
#
#   [fgr_dod_init]rtcui=<A>,init_swocv=<B>,OCV_to_SOC_c=<C>
#
#   A = nilai UI SOC yang diwariskan dari sesi sebelumnya (register RTC).
#       A = 0        -> sesi sebelumnya TIDAK menyimpan apa pun (reboot
#                       melewati handler simpan). Inilah yang paling mungkin.
#       A = 100      -> yang tersimpan justru angka salah (100), bukan 39/40.
#       A = 39/40    -> tersimpan benar tapi ditimpa setelahnya.
#
#   B = OCV yang dipakai kalau A tidak valid. B = ptim x 10. ptim itu kode ADC
#       dengan skala salah (rasio 0.859), jadi B selalu ~4400-4470 mV walau sel
#       aslinya 3.8 V. Ini yang menghasilkan SOC 100%.
#
# Jalankan di Android (lewat adb) ATAU di recovery, keduanya sama.
# ============================================================================

LOG=/data/local/tmp/cek_boot.log
: > "$LOG"

w() { echo "$@" | tee -a "$LOG"; }

w "=============================================================="
w " JEJAK INIT GAUGE - boot yang sedang berjalan"
w " $(date 2>/dev/null)"
w "=============================================================="
w ""

# --- 1. angka yang tampil sekarang -----------------------------------------
w "--- angka sekarang ---"
for f in bms/capacity battery/capacity bms/voltage_now bms/current_now; do
	v=$(cat "/sys/class/power_supply/$f" 2>/dev/null | tr -d ' \r\n\t')
	w "  $f = ${v:-<kosong>}"
done
w ""

# --- 2. baris init gauge ----------------------------------------------------
w "--- [fgr_dod_init] : INI YANG PENTING ---"
dmesg 2>/dev/null | grep -i "fgr_dod_init" | tee -a "$LOG"
if ! dmesg 2>/dev/null | grep -qi "fgr_dod_init"; then
	w "  <tidak ada di dmesg - buffer sudah terputar, atau dmesg dibatasi>"
fi
w ""

# --- 3. konteks lain --------------------------------------------------------
w "--- jejak pendukung ---"
dmesg 2>/dev/null | grep -iE "fg_check_lk_swocv|fg_custom_init_from_dts|boot_zcv_get|Kernel mode Gauge|gauge_coulomb_before_reset|gauge_coulomb_after_reset|cycle count" | tee -a "$LOG"
w ""

# --- 4. kesimpulan otomatis -------------------------------------------------
w "--- kesimpulan ---"
LINE=$(dmesg 2>/dev/null | grep -i "fgr_dod_init" | head -1)
if [ -n "$LINE" ]; then
	RTCUI=$(echo "$LINE" | sed -n 's/.*rtcui=\([0-9-]*\).*/\1/p')
	SWOCV=$(echo "$LINE" | sed -n 's/.*init_swocv=\([0-9-]*\).*/\1/p')
	if [ -n "$RTCUI" ]; then
		if [ "$RTCUI" = "0" ]; then
			w "  rtcui = 0  -> sesi sebelumnya TIDAK menyimpan nilai ke RTC."
			w "              Ini yang terjadi kalau reboot melewati handler simpan,"
			w "              dan driver jatuh ke init_swocv = ptim (skala salah)."
		elif [ "$RTCUI" -ge 90 ] 2>/dev/null; then
			w "  rtcui = $RTCUI -> yang tersimpan justru angka salah, bukan angka jujur."
		else
			w "  rtcui = $RTCUI -> nilai jujur berhasil diwariskan."
		fi
	fi
	[ -n "$SWOCV" ] && w "  init_swocv = $SWOCV (0.1 mV) = $((SWOCV / 10)) mV"
	w "  Tegangan sel sekarang: $(cat /sys/class/power_supply/bms/voltage_now 2>/dev/null) uV"
	w ""
	w "  Kalau init_swocv jauh di atas tegangan sel, itulah sumber SOC 100%."
else
	w "  dmesg tidak memuat baris fgr_dod_init, tidak bisa menyimpulkan."
	w "  Coba jalankan di recovery (di sana dmesg selalu bisa dibaca)."
fi
w ""
w "log: $LOG"
