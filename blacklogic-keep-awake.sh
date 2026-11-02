#!/bin/bash
set -uo pipefail
# Keep-awake lock: prevents sleep, suspend, hibernate, screen blanking, and auto-dim
# during long-running BlackLogic operations. Does NOT restart logind or kill sessions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
ensure_tools systemctl setterm xset 2>/dev/null || true

# Disable all sleep/suspend/hibernate targets (mask + stop)
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    systemctl mask "$target" 2>/dev/null || true
    systemctl stop "$target" 2>/dev/null || true
done

# Disable lid switch handling via logind.conf (no restart - apply on next boot)
for key in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
    if grep -q "^#*$key=" /etc/systemd/logind.conf 2>/dev/null; then
        sed -i "s/^#*$key=.*/$key=ignore/" /etc/systemd/logind.conf 2>/dev/null || true
    else
        echo "$key=ignore" >> /etc/systemd/logind.conf 2>/dev/null || true
    fi
done

# Disable screen blanking and DPMS
setterm -blank 0 2>/dev/null || true
setterm -powersave off 2>/dev/null || true
setterm -powerdown 0 2>/dev/null || true
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset dpms 0 0 0 2>/dev/null || true

# Disable GNOME/KDE/Cinnamon screen blanking
gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null || true

# KDE
kwriteconfig5 --file kscreenlockerrc --group Daemon --key Autolock false 2>/dev/null || true
kwriteconfig5 --file powermanagementprofilesrc --group AC --group DPMSControl --key idleTime 0 2>/dev/null || true

# Xfce
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 2>/dev/null || true
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 0 2>/dev/null || true
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 0 2>/dev/null || true

# Create an inhibition lock using systemd-inhibit if available (run in background)
if command -v systemd-inhibit >/dev/null 2>&1; then
    # Kill any existing keep-awake inhibitor
    if [ -f /tmp/blacklogic-keepawake.pid ]; then
        kill "$(cat /tmp/blacklogic-keepawake.pid)" 2>/dev/null || true
        rm -f /tmp/blacklogic-keepawake.pid
    fi
    # Start new inhibitor (sleep 999999999 keeps the lock held)
    systemd-inhibit --what=sleep:shutdown:idle:handle-lid-switch --who="BlackLogic" --why="Long-running installation process" --mode=block sleep 999999999 >/dev/null 2>&1 &
    echo $! > /tmp/blacklogic-keepawake.pid
fi

# Also use xautolock disable if available
command -v xautolock >/dev/null 2>&1 && xautolock -disable 2>/dev/null || true

echo "Keep-awake lock activated. System will not sleep or dim."
exit 0
