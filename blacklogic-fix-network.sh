#!/bin/bash
set -uo pipefail
[ -f /tmp/blacklogic-state ] && source /tmp/blacklogic-state
echo "=== FIXER: Network ==="
ping -c1 -W3 archlinux.org &>/dev/null && { echo "Network up."; exit 0; }
case "$HOST_INIT" in
    systemd) systemctl restart NetworkManager 2>/dev/null || true; sleep 3
             ping -c1 -W3 archlinux.org &>/dev/null || systemctl restart dhcpcd 2>/dev/null || true ;;
    *) dhclient 2>/dev/null || dhcpcd 2>/dev/null || true ;;
esac
ping -c1 -W3 archlinux.org &>/dev/null && echo "Network restored." || echo "Network still down."
command -v reflector >/dev/null && reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || true
exit 0
