#!/bin/bash
# =============================================================================
# test_smooth.sh - local test harness for battfixd.sh
#
# Runs the real sample_ocv() and filter_step() out of battfixd.sh against
# synthetic sysfs data, so the smoothing logic can be validated on a PC without
# flashing anything and without a phone attached.
#
#     bash battfix/test_smooth.sh
#
# Exit code 0 means every assertion passed.
#
# WHY THIS EXISTS
#   The display used to jump 2 points on its own. That was not voltage noise but
#   current noise: current_now was observed swinging 51 mA -> 349 mA inside one
#   session. At RMO = 95 mOhm that is 28 mV of IR correction, and around 20 %
#   the curve moves ~8.3 mV per 1 % of SOC, so 28 mV is 3.4 points of pure
#   noise. These tests pin down the filters that remove it.
#
# TWO GOTCHAS WHEN EDITING THIS FILE
#
#   1. rd() is called inside $( ), so any shell variable it increments dies
#      with the subshell. The read counters therefore live in files. With
#      variables, every one of the five reads returns the first line and the
#      "outlier rejection" test passes for the wrong reason.
#   2. Expectations are truncated, not ideal. The IR term is I * 95 / 1000 uV
#      with shell integer division, and soc_from_ocv() interpolates with
#      integer division too, so 3629 mV is 16 % here and not 15 %.
# =============================================================================

SRC="$(dirname "$0")/battfixd.sh"
T="${TMPDIR:-/tmp}/battfix_test_$$"
mkdir -p "$T"

BMS=$T
BAT=$T
VSEQ=$T/vseq
ISEQ=$T/iseq
CNTV=$T/cntv
CNTI=$T/cnti

# Must mirror the constants in battfixd.sh.
RMO=95
SAMPLES=5
LOWI=100000
MAXDROP=2
MAXRISE=1
ALPHA=3
HYST=3
CONFIRM=2
CREEP=4

rd() {
	case "$1" in
		*/voltage_now)
			_n=$(cat "$CNTV" 2>/dev/null); _n=$(( ${_n:-0} + 1 ))
			echo "$_n" > "$CNTV"
			_l=$(sed -n "${_n}p" "$VSEQ")
			[ -n "$_l" ] || _l=$(tail -1 "$VSEQ")
			echo "$_l" ;;
		*/current_now)
			_n=$(cat "$CNTI" 2>/dev/null); _n=$(( ${_n:-0} + 1 ))
			echo "$_n" > "$CNTI"
			_l=$(sed -n "${_n}p" "$ISEQ")
			[ -n "$_l" ] || _l=$(tail -1 "$ISEQ")
			echo "$_l" ;;
		*) cat "$1" 2>/dev/null | tr -d ' \r\n\t' ;;
	esac
}
isnum() { case "$1" in ''|*[!0-9-]*) return 1 ;; esac; return 0; }

# Pull the shipped functions out of the daemon so we test the real code, not a
# copy of it that can drift.
eval "$(sed -n '/^sample_ocv() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^filter_step() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^soc_from_ocv() {/,/^}/p' "$SRC")"
eval "OCV_TABLE='$(sed -n "/^OCV_TABLE='/,/^3350 0'/p" "$SRC" | sed "1s/^OCV_TABLE='//")"

fail=0
chk() {
	if [ "$2" = "$3" ]; then
		printf '  OK   %-40s %s\n' "$1" "$2"
	else
		printf '  FAIL %-40s got=%s want=%s\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

vseq() { printf '%s\n' "$@" > "$VSEQ"; echo 0 > "$CNTV"; }
iseq() { printf '%s\n' "$@" > "$ISEQ"; echo 0 > "$CNTI"; }

echo "== sample_ocv: IR compensation =="
vseq 3672000 3672000 3672000 3672000 3672000
iseq 20000 20000 20000 20000 20000
sample_ocv; chk "at rest, 20 mA" "$VOC" "3670"
iseq 449000 449000 449000 449000 449000
sample_ocv; chk "charging 449 mA" "$VOC" "3629"
iseq -449000 -449000 -449000 -449000 -449000
sample_ocv; chk "discharging -449 mA" "$VOC" "3714"

echo "== sample_ocv: outlier rejection (median of 5) =="
vseq 3672000 3672000 3672000 3672000 3672000
iseq 449000 449000 449000 449000 1500000
sample_ocv; chk "one 1.5 A spike is outvoted" "$VOC" "3629"

echo "== sample_ocv: low-current sample preferred =="
# A 30 mA sample carries almost no IR error, so it wins over four 449 mA
# samples even though its OCV sits at the other end of the spread.
vseq 3672000 3672000 3672000 3672000 3672000
iseq 449000 449000 30000 449000 449000
sample_ocv; chk "30 mA sample wins" "$VOC" "3669"

echo "== sample_ocv: no data must fail cleanly =="
vseq "" "" "" "" ""
iseq 0 0 0 0 0
sample_ocv; chk "empty reads -> return 1" "$?" "1"
chk "empty reads -> VOC empty" "$VOC" ""

echo "== soc_from_ocv =="
chk "3672 mV" "$(soc_from_ocv 3672)" "21"
chk "3629 mV" "$(soc_from_ocv 3629)" "16"
chk "3714 mV" "$(soc_from_ocv 3714)" "26"
chk "4400 mV clamps at 100" "$(soc_from_ocv 4400)" "100"
chk "3300 mV clamps at 0" "$(soc_from_ocv 3300)" "0"

echo "== filter_step: 2-point noise must NOT reach the screen =="
DISP=21; PDIR=0; PCNT=0
for s in 23 21 23 21 23 21 23 21 23 21; do filter_step "$s"; done
chk "ten alternating ticks around 21" "$DISP" "21"

echo "== filter_step: a real sustained trend does get through =="
DISP=21; PDIR=0; PCNT=0
for s in 18 18 18; do filter_step "$s"; done
chk "18 for three ticks (drop 3)" "$DISP" "19"
for s in 18 18 18 18; do filter_step "$s"; done
chk "creep finishes the job to 18" "$DISP" "18"

echo "== filter_step: one-tick dip is ignored, then recovers =="
DISP=21; PDIR=0; PCNT=0
filter_step 17
chk "single 17 after 21" "$DISP" "21"
filter_step 21
chk "back to 21" "$DISP" "21"

echo "== filter_step: rise is limited to MAXRISE per step =="
DISP=21; PDIR=0; PCNT=0
for s in 30 30 30; do filter_step "$s"; done
chk "30 after 21 -> +1 only" "$DISP" "22"
for s in 30 30 30 30 30 30; do filter_step "$s"; done
chk "keeps climbing, still capped" "$DISP" "25"

echo "== filter_step: must not park 2 points off at the bottom =="
# The failure this guards against: DISP=2 while the truth is 0 means the phone
# dies at 2 %, which is the original complaint in a milder form. A pure
# deadband parks there forever; CREEP is what walks it down.
DISP=2; PDIR=0; PCNT=0
for i in 1 2 3 4 5 6 7 8; do filter_step 0; done
chk "walks 2 -> 0 while sitting at 0" "$DISP" "0"

rm -rf "$T" 2>/dev/null
echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "$fail FAILED"; fi
exit "$fail"
