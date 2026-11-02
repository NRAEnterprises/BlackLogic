#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools ping systemctl dhclient dhcpcd reflector 2>/dev/null || true

[ -f /tmp/blacklogic-state ] && . /tmp/blacklogic-state

echo "=== FIXER: Network ==="
if ping -c1 -W3 archlinux.org &>/dev/null; then
    echo "Network up."
    exit 0
fi

case "$HOST_INIT" in
    systemd)
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 3
        ping -c1 -W3 archlinux.org &>/dev/null || systemctl restart dhcpcd 2>/dev/null || true
        ;;
    *)
        dhclient 2>/dev/null || dhcpcd 2>/dev/null || true
        ;;
esac

if ping -c1 -W3 archlinux.org &>/dev/null; then
    echo "Network restored."
else
    echo "Network still down."
fi

if command -v reflector >/dev/null 2>&1; then
    reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || true
fi

exit 0
