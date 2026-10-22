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
modprobe zram 2>/dev/null || true
if [ -e /dev/zram0 ] && ! swapon --show | grep -q "/dev/zram0"; then
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ZRAM_SIZE=$(( (TOTAL_RAM_KB * 1024) / 2 ))
    echo "$ZRAM_SIZE" > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1 || true
    swapon -p 100 /dev/zram0 2>/dev/null || true
fi
CURRENT_TTY=$(fgconsole 2>/dev/null || echo "1")
for tty in 1 2 3 4 5 6; do
    [ "$tty" -ne "$CURRENT_TTY" ] && fuser -k /dev/tty${tty} >/dev/null 2>&1 || true
done
pkill -f kded5 2>/dev/null || true
pkill -f soliduiserver 2>/dev/null || true
pkill -f udisksd 2>/dev/null || true
systemctl stop udisks2 2>/dev/null || true
echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
for i in /sys/bus/usb/devices/*/power/control; do echo on > "$i" 2>/dev/null || true; done
echo "HOST_INIT=$HOST_INIT" > /tmp/blacklogic-state
echo "HOST_DM=$HOST_DM" >> /tmp/blacklogic-state
echo "CURRENT_TTY=$CURRENT_TTY" >> /tmp/blacklogic-state
echo "Stage 1 complete."
exit 0
