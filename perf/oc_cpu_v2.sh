#!/system/bin/sh
# =============================================================================
# oc_cpu_v2.sh - CPU overclock for kernels with /proc/cpudvfs (lite version)
#
# Kernel HayaseYuuka-v4.1 memuat module cpudvfs (CONFIG_MEDIATEK_CPUFREQ_DEBUG_LITE)
# yang membuat /proc/cpudvfs/cpufreq_debug. Node ini RW dan bisa:
#   echo "<cpu> <min_kHz> <max_kHz>" > /proc/cpudvfs/cpufreq_debug
#
# TAPI handler-nya pakai dev_pm_opp_find_freq_floor(), jadi nilai di-floor ke
# OPP terdekat yang ada di tabel. Tidak bisa naik di atas OPP tertinggi.
#
# STRATEGI BARU:
#   1. Cek node yang ada
#   2. Cek OPP table di sysfs (/sys/devices/system/cpu/cpufreq/policy*/)
#   3. Coba naikkan cpuinfo_max_freq lewat /proc/cpudvfs/cpufreq_debug
#   4. Kalau tidak bisa lewat OPP, coba /sys/kernel/debug/mtk_cpufreq
#   5. Coba PM_QOS atau governor performance untuk pin di max
#
# GPU OC tetap pakai /proc/gpufreqv2/fix_custom_freq_volt yang SUDAH TERBUKTI
# =============================================================================

PDIR=/proc/cpudvfs
CPU=/sys/devices/system/cpu/cpufreq

rd() { cat "$1" 2>/dev/null; }

echo "=============================================================="
echo "CPU OC probe v2 - HayaseYuuka-v4.1 / cpudvfs lite"
echo "=============================================================="
echo "kernel : $(uname -r 2>/dev/null)"
echo

echo "=== 1. /proc/cpudvfs ==="
if [ -d "$PDIR" ]; then
    ls -la "$PDIR/"
    echo
    echo "cpufreq_debug content:"
    rd "$PDIR/cpufreq_debug" | sed 's/^/  /'
else
    echo "  /proc/cpudvfs ABSENT"
fi

echo
echo "=== 2. /proc/cpumaxfreq ==="
if [ -e /proc/cpumaxfreq ]; then
    echo "  $(cat /proc/cpumaxfreq)"
else
    echo "  /proc/cpumaxfreq ABSENT"
fi

echo
echo "=== 3. CPU policies ==="
i=0
for p in $CPU/policy*; do
    [ -d "$p" ] || continue
    cpus=$(rd "$p/related_cpus")
    cur=$(rd "$p/scaling_cur_freq")
    min=$(rd "$p/cpuinfo_min_freq")
    max=$(rd "$p/cpuinfo_max_freq")
    smin=$(rd "$p/scaling_min_freq")
    smax=$(rd "$p/scaling_max_freq")
    gov=$(rd "$p/scaling_governor")
    avafreq=$(rd "$p/scaling_available_frequencies")
    echo "  policy$i: cpus=$cpus"
    echo "    cpuinfo: min=$min max=$max"
    echo "    scaling: min=$smin max=$smax gov=$gov cur=$cur"
    [ -n "$avafreq" ] && echo "    avail: $avafreq"
    # List OPP table
    echo "    OPP table:"
    ls "$p/" 2>/dev/null | grep -i opp | sed 's/^/      /'
    i=$(( i + 1 ))
done

echo
echo "=== 4. OPP tables from sysfs ==="
for d in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -d "$d" ] || continue
    cpu=$(echo "$d" | sed 's|.*/cpu\(.*\)/cpufreq|\1|')
    # Check for opp tables
    oppdir="/sys/devices/system/cpu/cpu$cpu/cpufreq"
    if [ -d "$oppdir" ]; then
        max=$(rd "$oppdir/cpuinfo_max_freq")
        echo "  cpu$cpu: max=$max"
    fi
done

echo
echo "=== 5. Try /proc/cpudvfs/cpufreq_debug write ==="
if [ -e "$PDIR/cpufreq_debug" ]; then
    # Read current state first
    echo "  Before:"
    rd "$PDIR/cpufreq_debug" | sed 's/^/    /'
    
    # Try writing max freq for CPU 7 (A76 big cluster, per CPU_MAXFREQ_INDEX)
    # Format: "<cpu> <min_kHz> <max_kHz>"
    echo "  Writing cpu=7 min=400000 max=2200000 (stock max for A76)..."
    echo "7 400000 2200000" > "$PDIR/cpufreq_debug" 2>&1
    sleep 1
    echo "  After write:"
    rd "$PDIR/cpufreq_debug" | sed 's/^/    /'
    
    # Try writing above stock - this tests whether floor() caps it
    echo "  Writing cpu=7 min=400000 max=2500000 (OC attempt)..."
    echo "7 400000 2500000" > "$PDIR/cpufreq_debug" 2>&1
    sleep 1
    echo "  After OC attempt:"
    rd "$PDIR/cpufreq_debug" | sed 's/^/    /'
    echo "  policy7 max after:"
    rd "$CPU/policy7/cpuinfo_max_freq" | sed 's/^/    /'
fi

echo
echo "=== 6. Check /proc/cpuhvfs again ==="
ls -la /proc/cpuhvfs/ 2>&1 | sed 's/^/  /'

echo
echo "=== 7. Check debugfs for MTK cpufreq ==="
ls /sys/kernel/debug/mtk_cpufreq* 2>/dev/null | sed 's/^/  /'
ls /sys/kernel/debug/cpufreq* 2>/dev/null | sed 's/^/  /'
ls /sys/kernel/debug/ 2>/dev/null | grep -i -E 'cpu|dvfs|freq|opp' | sed 's/^/  /'

echo
echo "=== 8. Check PM QOS ==="
ls /sys/kernel/debug/pm_qos/ 2>/dev/null | sed 's/^/  /'
rd /sys/kernel/debug/pm_qos/cpu_dma_latency 2>/dev/null | sed 's/^/  /'

echo
echo "=== 9. GPU status (already confirmed working) ==="
echo "GPU node: $(cat /proc/gpufreqv2/gpufreq_status 2>/dev/null | head -5 | tr '\n' ' ')"
echo "GPU fix: $(cat /proc/gpufreqv2/fix_custom_freq_volt 2>/dev/null)"

echo
echo "=== 10. Check for hidden proc nodes ==="
ls /proc/ 2>/dev/null | grep -i -E 'cpu|freq|dvfs|clk|volt|opp' | sed 's/^/  /'

echo
echo "=== 11. Try scaling_max_freq directly ==="
# Sometimes scaling_max_freq is writable even if cpuinfo_max_freq isn't
for p in $CPU/policy*; do
    [ -d "$p" ] || continue
    echo "  $(basename $p):"
    echo "    scaling_max_freq perms: $(ls -la $p/scaling_max_freq 2>/dev/null | awk '{print $1}')"
    echo "    cpuinfo_max_freq perms: $(ls -la $p/cpuinfo_max_freq 2>/dev/null | awk '{print $1}')"
    echo "    scaling_available_governors: $(rd $p/scaling_available_governors)"
done
