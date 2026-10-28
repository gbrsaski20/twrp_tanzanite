#!/system/bin/sh
# =============================================================================
# uninstall.sh - there is nothing to undo on disk.
#
# The overclock only ever existed in the running kernel's registers. Removing
# the module means the next boot simply never writes them, so the stock table
# applies. If you want stock clocks WITHOUT rebooting, run:
#
#     sh /data/local/tmp/oc_cpu.sh restore
#     sh /data/local/tmp/oc_gpu.sh reset
# =============================================================================

echo "tanzanite_oc removed - next boot uses stock clocks"
