#!/bin/bash
set -uo pipefail
echo "=== Stage 1: Environment Setup ==="
HOST_INIT="unknown"; HOST_DM=""
[ -d /run/systemd/system ] && HOST_INIT="systemd"
if [ "$HOST_INIT" = "systemd" ]; then
    HOST_DM=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -oE '(gdm|sddm|lightdm|lxdm|xdm)\.service' | head -n1 || true)
    [ -z "$HOST_DM" ] && HOST_DM=$(systemctl get-default 2>/dev/null | grep -E '(gdm|sddm|lightdm)' || true)
fi
echo "Init: $HOST_INIT | DM: ${HOST_DM:-none}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
ensure_tools systemctl modprobe swapon mkswap 2>/dev/null || true

# USB power management
for i in /sys/bus/usb/devices/*/power/control; do
    [ -f "$i" ] && echo on > "$i" 2>/dev/null || true
done
for i in /sys/bus/usb/devices/*/power/autosuspend; do
    [ -f "$i" ] && echo -1 > "$i" 2>/dev/null || true
done
echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true

# ZRAM setup
modprobe zram 2>/dev/null || true
if [ -e /dev/zram0 ] && ! swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ZRAM_SIZE=$(( (TOTAL_RAM_KB * 1024) / 2 ))
    echo "$ZRAM_SIZE" > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1 || true
    swapon -p 100 /dev/zram0 2>/dev/null || true
fi

# Disable screen blanking
setterm -blank 0 2>/dev/null || true
setterm -powersave off 2>/dev/null || true
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Keep-awake lock
if [ -f "$SCRIPT_DIR/blacklogic-keep-awake.sh" ]; then
    bash "$SCRIPT_DIR/blacklogic-keep-awake.sh" 2>/dev/null || true
else
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
    systemctl stop sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
fi

# Write state
echo "HOST_INIT=$HOST_INIT" > /tmp/blacklogic-state
echo "HOST_DM=$HOST_DM" >> /tmp/blacklogic-state
echo "Stage 1 complete."
exit 0
