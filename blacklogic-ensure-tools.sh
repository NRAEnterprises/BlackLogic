#!/bin/bash
ensure_tools() {
    local missing=""
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0
    echo "Missing tools:$missing - attempting install..."
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm 2>/dev/null || true
        pacman -S --noconfirm --needed $missing 2>/dev/null && return 0
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y $missing 2>/dev/null && return 0
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $missing 2>/dev/null && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $missing 2>/dev/null && return 0
    fi
    for usb in /dev/sd* /dev/sr*; do
        [ -b "$usb" ] || continue
        mkdir -p /tmp/usbtool 2>/dev/null
        mount "$usb" /tmp/usbtool 2>/dev/null || continue
        for pkg in /tmp/usbtool/*; do
            [ -f "$pkg" ] || continue
            case "$pkg" in
                *.pkg.tar.zst|*.pkg.tar.xz) pacman -U --noconfirm "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; } ;;
                *.deb) dpkg -i "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; } ;;
                *.rpm) rpm -i "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; } ;;
            esac
        done
        umount /tmp/usbtool 2>/dev/null || true
    done
    echo "FATAL: Could not install:$missing" >&2
    return 1
}
EOF
bash -n /tmp/scratchpad/ensure_tools.sh 2>/dev/null || true
cp /tmp/scratchpad/ensure_tools.sh /workspace/app/blacklogic-ensure-tools.sh 2>/dev/null || true
# Write directly
cat > /workspace/app/blacklogic-ensure-tools.sh << 'HELPEREOF'
#!/bin/bash
ensure_tools() {
    local missing=""
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0
    echo "Missing tools:$missing - attempting install..."
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm 2>/dev/null || true
        pacman -S --noconfirm --needed $missing 2>/dev/null && return 0
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y $missing 2>/dev/null && return 0
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $missing 2>/dev/null && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $missing 2>/dev/null && return 0
    fi
    for usb in /dev/sd* /dev/sr*; do
        [ -b "$usb" ] || continue
        mkdir -p /tmp/usbtool 2>/dev/null
        mount "$usb" /tmp/usbtool 2>/dev/null || continue
        for pkg in /tmp/usbtool/*; do
            [ -f "$pkg" ] || continue
            case "$pkg" in
                *.pkg.tar.zst|*.pkg.tar.xz) pacman -U --noconfirm "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; } ;;
                *.deb) dpkg -i "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; } ;;
                *.rpm) rpm -i "$pkg" 2>/dev/null && { umount /tmp/usbtool 2>/dev/null; return 0; } ;;
            esac
        done
        umount /tmp/usbtool 2>/dev/null || true
    done
    echo "FATAL: Could not install:$missing" >&2
    return 1
}
HELPEREOF
chmod +x /workspace/app/blacklogic-ensure-tools.sh
bash -n /workspace/app/blacklogic-ensure-tools.sh && echo "syntax OK"