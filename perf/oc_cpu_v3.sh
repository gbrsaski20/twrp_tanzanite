#!/system/bin/sh
# =============================================================================
# oc_cpu_v3.sh - Deep probe untuk /proc/clkdbg dan clock manipulation
#
# Kernel HayaseYuuka-v4.1 memiliki /proc/clkdbg (dibuat oleh clk_dbg_mt6789).
# Ini MTK clock debug yang bisa:
#   - dump clock tree
#   - maybe set rate langsung
#
# Kita cek apa yang bisa dilakukan.
# =============================================================================

echo "=============================================================="
echo "CPU OC probe v3 - /proc/clkdbg exploration"
echo "=============================================================="
echo "kernel : $(uname -r 2>/dev/null)"
echo

echo "=== 1. /proc/clkdbg basic ==="
if [ -e /proc/clkdbg ]; then
    ls -la /proc/clkdbg 2>&1 | sed 's/^/  /'
    echo "  --- content (first 200 bytes) ---"
    head -c 200 /proc/clkdbg 2>&1 | sed 's/^/  /'
    echo
    echo "  --- full length ---"
    wc -c /proc/clkdbg 2>&1 | sed 's/^/  /'
else
    echo "  /proc/clkdbg ABSENT"
fi

echo
echo "=== 2. Try reading clkdbg for CPU-related clocks ==="
# Common MTK clock names for CPU
for clk in "cpupll" "armpll" "ccipll" "mfgpll" "mainpll" "univpll" "msdcpll" "mmpll" "cpu_clk" "cluster0" "cluster1"; do
    if [ -e /proc/clkdbg ]; then
        result=$(grep -i "$clk" /proc/clkdbg 2>/dev/null | head -3)
        if [ -n "$result" ]; then
            echo "  Found '$clk':"
            echo "$result" | sed 's/^/    /'
        fi
    fi
done

echo
echo "=== 3. Try writing to clkdbg (TEST MODE - read help first) ==="
if [ -e /proc/clkdbg ]; then
    echo "  Attempting to write 'help' or '?' to clkdbg..."
    echo "help" > /proc/clkdbg 2>&1
    sleep 1
    echo "  After write, first 300 bytes:"
    head -c 300 /proc/clkdbg 2>&1 | sed 's/^/    /'
    echo
fi

echo
echo "=== 4. Check /sys/kernel/debug/clk ==="
ls /sys/kernel/debug/clk/ 2>/dev/null | head -20 | sed 's/^/  /'
echo "  ---"
if [ -d /sys/kernel/debug/clk ]; then
    # Look for CPU clocks
    find /sys/kernel/debug/clk -name "*cpu*" 2>/dev/null | head -10 | sed 's/^/  /'
    find /sys/kernel/debug/clk -name "*pll*" 2>/dev/null | head -10 | sed 's/^/  /'
fi

echo
echo "=== 5. Try to find CPU PLL sysfs ==="
# Look for the CPU clock provider in sysfs
for f in /sys/kernel/debug/clk/cpupll* /sys/kernel/debug/clk/armpll* /sys/kernel/debug/clk/cluster*; do
    [ -e "$f" ] && echo "  Found: $f"
    [ -d "$f" ] && echo "    rate: $(cat $f/clk_rate 2>/dev/null)"
done

echo
echo "=== 6. Check if /sys/devices/system/cpu/cpu6/cpufreq has OPP override ==="
# Some kernels allow opp_table override in debugfs
echo "  cpu6 cpufreq dir:"
ls /sys/devices/system/cpu/cpu6/cpufreq/ 2>/dev/null | sed 's/^/    /'
echo "  cpu7 cpufreq dir:"
ls /sys/devices/system/cpu/cpu7/cpufreq/ 2>/dev/null | sed 's/^/    /'

echo
echo "=== 7. Check regulator nodes for CPU ==="
# CPU voltage regulators might be writable
ls /sys/class/regulator/ 2>/dev/null | sed 's/^/  /'
echo "  --- Looking for vproc/vsram regulators ---"
for d in /sys/class/regulator/regulator*; do
    [ -d "$d" ] || continue
    name=$(cat "$d/name" 2>/dev/null)
    case "$name" in
        *proc*|*vsram*|*cpu*|*dvfs*)
            echo "    $name:"
            echo "      voltage: $(cat $d/microvolts 2>/dev/null)"
            echo "      min: $(cat $d/min_microvolts 2>/dev/null)  max: $(cat $d/max_microvolts 2>/dev/null)"
            echo "      perms: $(ls -la $d/microvolts 2>/dev/null | awk '{print $1}')"
            ;;
    esac
done

echo
echo "=== 8. Check /proc/scp_dvfs ==="
if [ -e /proc/scp_dvfs ]; then
    ls -la /proc/scp_dvfs 2>&1 | sed 's/^/  /'
    cat /proc/scp_dvfs 2>/dev/null | head -20 | sed 's/^/  /'
else
    echo "  /proc/scp_dvfs ABSENT"
fi

echo
echo "=== 9. Check /proc/cpu_loading ==="
if [ -e /proc/cpu_loading ]; then
    cat /proc/cpu_loading 2>/dev/null | sed 's/^/  /'
else
    echo "  /proc/cpu_loading ABSENT"
fi

echo
echo "=== 10. Check for devfreq nodes ==="
ls /sys/class/devfreq/ 2>/dev/null | sed 's/^/  /'
for d in /sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in
        *cpu*|*dvfs*)
            echo "    $name:"
            echo "      cur: $(cat $d/cur_freq 2>/dev/null)"
            echo "      max: $(cat $d/max_freq 2>/dev/null)"
            echo "      available: $(cat $d/available_frequencies 2>/dev/null)"
            ;;
    esac
done

echo
echo "=== 11. Check /sys/kernel/debug/mtk_dvfsrc ==="
ls /sys/kernel/debug/mtk_dvfsrc* 2>/dev/null | sed 's/^/  /'
ls /sys/kernel/debug/ 2>/dev/null | grep -i -E 'dvfs|mtk|cpu|opp|freq' | sed 's/^/  /'

echo
echo "=== 12. Try writing scaling_max_freq directly (safe test) ==="
echo "  Current policy1 (A76) max: $(cat /sys/devices/system/cpu/cpufreq/policy1/cpuinfo_max_freq 2>/dev/null)"
echo "  Trying to write 2200000 to scaling_max_freq..."
echo "2200000" > /sys/devices/system/cpu/cpufreq/policy1/scaling_max_freq 2>&1
sleep 1
echo "  After write: $(cat /sys/devices/system/cpu/cpufreq/policy1/scaling_max_freq 2>/dev/null)"
echo "  cpuinfo_max_freq (should be unchanged): $(cat /sys/devices/system/cpu/cpufreq/policy1/cpuinfo_max_freq 2>/dev/null)"

echo
echo "=== 13. Try governor=performance pin (safe, no OC, just max freq) ==="
echo "  Current gov policy1: $(cat /sys/devices/system/cpu/cpufreq/policy1/scaling_governor 2>/dev/null)"
echo "performance" > /sys/devices/system/cpu/cpufreq/policy1/scaling_governor 2>&1
sleep 1
echo "  After: gov=$(cat /sys/devices/system/cpu/cpufreq/policy1/scaling_governor 2>/dev/null) cur=$(cat /sys/devices/system/cpu/cpufreq/policy1/scaling_cur_freq 2>/dev/null)"
echo "  Restoring schedutil..."
echo "schedutil" > /sys/devices/system/cpu/cpufreq/policy1/scaling_governor 2>&1

echo
echo "=== 14. Check if /proc/cpudvfs/cpufreq_debug can write different CPU ==="
echo "  Writing cpu=7 min=725000 max=2200000 to cpufreq_debug..."
echo "7 725000 2200000" > /proc/cpudvfs/cpufreq_debug 2>&1
sleep 1
echo "  cpufreq_debug content: $(cat /proc/cpudvfs/cpufreq_debug 2>/dev/null)"
echo "  NOTE: this always shows cpu0, so we test policy6/7 separately"
echo "  policy6 max: $(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq 2>/dev/null)"
echo "  policy7 max: $(cat /sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq 2>/dev/null)"
