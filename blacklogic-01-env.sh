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

# Aggressively kill all desktop environments and GUI processes
for proc in kded5 soliduiserver udisksd kwin_x11 kwin_wayland plasmashell gnome-shell cinnamon-session xfce4-session mate-session lxsession openbox fluxbox i3 sway hyprland waybar polybar picom compton dunst mako notification-daemon; do
    pkill -9 -f "$proc" 2>/dev/null || true
done

# Stop all display managers
for dm in gdm sddm lightdm lxdm xdm; do
    systemctl stop "$dm" 2>/dev/null || true
    systemctl stop "$dm.service" 2>/dev/null || true
done
systemctl stop display-manager 2>/dev/null || true
systemctl stop udisks2 2>/dev/null || true
systemctl stop bluetooth 2>/dev/null || true
systemctl stop cups 2>/dev/null || true
systemctl stop avahi-daemon 2>/dev/null || true

# Kill all processes on other TTYs aggressively
CURRENT_TTY=$(fgconsole 2>/dev/null || echo "1")
for tty in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$tty" -ne "$CURRENT_TTY" ] && fuser -k -9 /dev/tty${tty} >/dev/null 2>&1 || true
done

# Kill any process holding block devices
for dev in /dev/sd* /dev/nvme* /dev/hd*; do
    [ -b "$dev" ] && fuser -k -9 "$dev" 2>/dev/null || true
done

# Lock the session - prevent new logins
echo "1" > /proc/sys/kernel/sysrq 2>/dev/null || true
# Disable magic sysrq reboot
echo "0" > /proc/sys/kernel/sysrq 2>/dev/null || true

# USB power management - aggressive
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

# Disable screen blanking and power management
setterm -blank 0 2>/dev/null || true
setterm -powersave off 2>/dev/null || true
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Write state
echo "HOST_INIT=$HOST_INIT" > /tmp/blacklogic-state
echo "HOST_DM=$HOST_DM" >> /tmp/blacklogic-state
echo "CURRENT_TTY=$CURRENT_TTY" >> /tmp/blacklogic-state
echo "Stage 1 complete."
exit 0
EOF
bash -n blacklogic-01-env.sh && echo "syntax OK"