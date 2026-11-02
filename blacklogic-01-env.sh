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
ensure_tools systemctl 2>/dev/null || true

# --- Section 1: USB Power Management ---
# Give breathing room between operations
echo "Configuring USB power management..."
for i in /sys/bus/usb/devices/*/power/control; do
    [ -f "$i" ] && echo on > "$i" 2>/dev/null || true
done
sleep 0.5
for i in /sys/bus/usb/devices/*/power/autosuspend; do
    [ -f "$i" ] && echo -1 > "$i" 2>/dev/null || true
done
echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
sleep 0.5

# --- Section 2: Keep-awake lock ---
echo "Activating keep-awake lock..."
if [ -f "$SCRIPT_DIR/blacklogic-keep-awake.sh" ]; then
    bash "$SCRIPT_DIR/blacklogic-keep-awake.sh" 2>/dev/null || true
else
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
    systemctl stop sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
fi
sleep 0.5

# --- Section 3: Screen blanking disable ---
echo "Disabling screen blanking..."
setterm -blank 0 2>/dev/null || true
setterm -powersave off 2>/dev/null || true
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
sleep 0.5

# --- Section 4: Write state ---
echo "Writing state..."
echo "HOST_INIT=$HOST_INIT" > /tmp/blacklogic-state
echo "HOST_DM=$HOST_DM" >> /tmp/blacklogic-state
echo "Stage 1 complete."
exit 0
