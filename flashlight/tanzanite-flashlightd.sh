#!/system/bin/sh
# Bridge OrangeFox's brightness-file UI to the MT6789 flashlight switch.
# The driver exposes mt6789_flash (0=off, 1=on), not an LED brightness node.
# Its store handler treats a standalone newline as "on", so write no newline.

NODE=/sys/devices/platform/flashlights_mt6789/mt6789_flash
CONTROL_DIR=/tmp/flashlight
BRIGHTNESS="$CONTROL_DIR/brightness"
MAX_BRIGHTNESS="$CONTROL_DIR/max_brightness"

mkdir -p "$CONTROL_DIR"
printf '1\n' > "$MAX_BRIGHTNESS"
printf '0\n' > "$BRIGHTNESS"

# Make sure the torch starts off when recovery starts.
if [ -e "$NODE" ]; then
	printf '%s' '0' > "$NODE" 2>/dev/null
fi

last=''
while :; do
	value=$(cat "$BRIGHTNESS" 2>/dev/null)
	case "$value" in
		0|1) ;;
		*) value=0; printf '0\n' > "$BRIGHTNESS" ;;
	esac

	if [ "$value" != "$last" ] && [ -e "$NODE" ]; then
		if printf '%s' "$value" > "$NODE" 2>/dev/null; then
			last="$value"
		fi
	fi
	sleep 0.2
done
