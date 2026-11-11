#!/bin/bash
# Shared dependency installer for BlackLogic
# Usage: ensure_tools <cmd1> <cmd2> ...
# Primary fallback: network install via pacman/apt/dnf/yum
# Secondary fallback: USB device search for installable packages
# Only fails if all methods are exhausted

ensure_tools() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    echo "Missing tools: ${missing[*]} - attempting install..."

    # Primary: network install
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm 2>/dev/null || true
        pacman -S --noconfirm --needed "${missing[@]}" 2>/dev/null && return 0
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y "${missing[@]}" 2>/dev/null && return 0
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing[@]}" 2>/dev/null && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing[@]}" 2>/dev/null && return 0
    fi

    # Secondary: USB device search
    for usb in /dev/sd* /dev/sr*; do
        [ -b "$usb" ] || continue
        mkdir -p /tmp/usbtool 2>/dev/null
        mount "$usb" /tmp/usbtool 2>/dev/null || continue
        for pkg in /tmp/usbtool/*; do
            [ -f "$pkg" ] || continue
            case "$pkg" in
                *.pkg.tar.zst|*.pkg.tar.xz)
                    pacman -U --noconfirm "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; }
                    ;;
                *.deb)
                    dpkg -i "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; }
                    ;;
                *.rpm)
                    rpm -i "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; }
                    ;;
            esac
        done
        umount /tmp/usbtool 2>/dev/null || true
    done

    echo "FATAL: Could not install: ${missing[*]}" >&2
    return 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "FATAL: This script must run as root. Use: sudo bash $0" >&2
        exit 1
    fi
}