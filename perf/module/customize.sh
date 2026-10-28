#!/system/bin/sh
# =============================================================================
# customize.sh - runs once when the zip is installed by KernelSU / Magisk.
# Nothing is copied anywhere; this only sets permissions and prints the warning.
# =============================================================================

SKIPUNZIP=0

ui_print "- Tanzanite CPU+GPU overclock"
ui_print "- kernel: $(uname -r)"
ui_print ""

if [ ! -e /proc/cpuhvfs/phyclk ]; then
	ui_print "! /proc/cpuhvfs/phyclk is NOT present on this kernel."
	ui_print "! CPU overclock will do nothing. GPU part may still work."
	ui_print "! Run oc_probe.sh first and send the result."
	ui_print ""
fi

ui_print "- Clocks are applied at boot, never written to any partition."
ui_print "- If the phone freezes 3 boots in a row, the module disables itself."
ui_print "- Log: /data/adb/modules/tanzanite_oc/oc.log"
ui_print ""

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/oc_cpu.sh" 0 0 0755
set_perm "$MODPATH/oc_gpu.sh" 0 0 0755
