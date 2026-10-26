#!/bin/sh
# Local harness for battfixd.sh: fakes the power_supply sysfs, feeds a jittery
# voltage sequence, and prints the resulting log so the anti-flicker behaviour
# can be checked without a device.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# Keep the sandbox inside the repo: mktemp on this platform returns a Windows
# path, and a backslashed path cannot be substituted into the shell script.
TMP="$HERE/_test_tmp"
rm -rf "$TMP"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/sys/class/power_supply/bms" "$TMP/sys/class/power_supply/battery" "$TMP/etc" "$TMP/batt"
cp "$HERE/ocv.txt" "$TMP/etc/battfix_ocv.txt"
echo 81 > "$TMP/sys/class/power_supply/battery/capacity"
echo "Discharging" > "$TMP/sys/class/power_supply/battery/status"

# Rewrite paths and speed up the loop for the test.
sed -e "s#/sys/class/power_supply#$TMP/sys/class/power_supply#g" \
    -e "s#/tmp/#$TMP/#g" \
    -e "s#/system/etc/#$TMP/etc/#g" \
    -e "s#^INTERVAL=5#INTERVAL=0#" \
    -e "s#sleep 0.3 2>/dev/null || sleep 1#sleep 0.01 2>/dev/null || true#" \
    "$HERE/battfixd.sh" > "$TMP/run.sh"

BMS="$TMP/sys/class/power_supply/bms"

# Jitter around 3.677 V, +-10 mV, the range the real device showed.
JITTER="3677000 3685000 3669000 3677000 3682000 3672000 3668000 3680000 3674000 3676000"

(
  i=0
  while [ "$i" -lt 400 ]; do
    for v in $JITTER; do
      echo "$v" > "$BMS/voltage_now"
      echo "-50000" > "$BMS/current_now"
      sleep 0.02
    done
    i=$((i + 1))
  done
) &
WRITER=$!

sh "$TMP/run.sh" &
DAEMON=$!
sleep 30
kill "$DAEMON" 2>/dev/null
kill "$WRITER" 2>/dev/null
wait 2>/dev/null

echo "=== log (tick v i voc vs soc disp) ==="
cat "$TMP/battfix.log"
echo
echo "=== distinct displayed values ==="
awk '{for(i=1;i<=NF;i++) if($i ~ /^disp=/){sub("disp=","",$i); print $i}}' "$TMP/battfix.log" | sort -u | tr '\n' ' '
echo
echo "=== how many ticks changed the display ==="
awk '{for(i=1;i<=NF;i++) if($i ~ /^disp=/){sub("disp=","",$i); print $i}}' "$TMP/battfix.log" \
  | awk 'NR>1 && $1!=p {c++} {p=$1} END{print (c+0)" changes out of "NR" ticks"}'
