#!/bin/bash
set -uo pipefail
MOUNT_DIR="/mnt/blackarch"; VG_NAME="black_pool"; POOL_NAME="black_pool"
SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
ensure_tools lvs mount umount arch-chroot modprobe swapon mkswap 2>/dev/null || true
log() { echo "[$(date +%H:%M:%S)] $*"; }
echo "=== Stage 4: Aftermath ==="

# --- Section 1: ZRAM setup ---
echo "Configuring ZRAM..."
modprobe zram 2>/dev/null || { echo "WARNING: Failed to load zram module"; }
sleep 0.5
if [ -e /dev/zram0 ] && ! swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ZRAM_SIZE=$(( (TOTAL_RAM_KB * 1024) / 2 ))
    echo "$ZRAM_SIZE" > /sys/block/zram0/disksize 2>/dev/null || { echo "WARNING: Failed to set zram disksize"; }
    sleep 0.5
    mkswap /dev/zram0 >/dev/null 2>&1 || { echo "WARNING: Failed to mkswap zram0"; }
    swapon -p 100 /dev/zram0 2>/dev/null || { echo "WARNING: Failed to swapon zram0"; }
fi
sleep 0.5

# --- Section 2: Mount root if needed ---
if ! mountpoint -q "$MOUNT_DIR"; then
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
    [ -z "$ROOT_LV" ] && { echo "No root LV."; exit 1; }
    mkdir -p "$MOUNT_DIR"
    if ! mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "/dev/$VG_NAME/$ROOT_LV" "$MOUNT_DIR"; then
        if ! mount "/dev/$VG_NAME/$ROOT_LV" "$MOUNT_DIR"; then
            echo "Failed to mount root LV"
            exit 1
        fi
    fi
fi
[ ! -f "$MOUNT_DIR/etc/os-release" ] && { echo "OS missing."; umount -R "$MOUNT_DIR" 2>/dev/null; exit 1; }

# --- Section 3: Post-install script ---
if [ -f /usr/local/bin/black_aftermath.sh ]; then
    cp /usr/local/bin/black_aftermath.sh "$MOUNT_DIR/root/black_aftermath.sh"
    if ! arch-chroot "$MOUNT_DIR" /bin/bash -c "bash /root/black_aftermath.sh"; then
        echo "WARNING: Aftermath script had errors."
    fi
fi

# --- Section 4: Cleanup and reboot ---
# Release keep-awake inhibitor
if [ -f /tmp/blacklogic-keepawake.pid ]; then
    pid=$(cat /tmp/blacklogic-keepawake.pid 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f /tmp/blacklogic-keepawake.pid
fi
pkill -f "systemd-inhibit.*BlackLogic" 2>/dev/null || true

log "Unmounting and rebooting..."
if ! umount -R "$MOUNT_DIR" 2>/dev/null; then
    echo "WARNING: Some mounts could not be unmounted cleanly"
    # Try lazy unmount
    umount -R -l "$MOUNT_DIR" 2>/dev/null || true
fi
sleep 2
reboot
exit 0