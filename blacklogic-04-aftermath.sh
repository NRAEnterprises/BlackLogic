#!/bin/bash
set -uo pipefail
MOUNT_DIR="/mnt/blackarch"; VG_NAME="black_vg"; POOL_NAME="black_pool"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
ensure_tools lvs mount umount arch-chroot modprobe swapon mkswap 2>/dev/null || true
log() { echo "[$(date +%H:%M:%S)] $*"; }
echo "=== Stage 4: Aftermath ==="

# --- Section 1: ZRAM setup (moved from env stage for breathing room) ---
echo "Configuring ZRAM..."
modprobe zram 2>/dev/null || true
sleep 0.5
if [ -e /dev/zram0 ] && ! swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ZRAM_SIZE=$(( (TOTAL_RAM_KB * 1024) / 2 ))
    echo "$ZRAM_SIZE" > /sys/block/zram0/disksize 2>/dev/null || true
    sleep 0.5
    mkswap /dev/zram0 >/dev/null 2>&1 || true
    swapon -p 100 /dev/zram0 2>/dev/null || true
fi
sleep 0.5

# --- Section 2: Mount root if needed ---
if ! mountpoint -q "$MOUNT_DIR"; then
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
    [ -z "$ROOT_LV" ] && { echo "No root LV."; exit 1; }
    mkdir -p "$MOUNT_DIR"
    mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "/dev/$VG_NAME/$ROOT_LV" "$MOUNT_DIR" 2>/dev/null || mount "/dev/$VG_NAME/$ROOT_LV" "$MOUNT_DIR" || exit 1
fi
[ ! -f "$MOUNT_DIR/etc/os-release" ] && { echo "OS missing."; umount -R "$MOUNT_DIR" 2>/dev/null; exit 1; }

# --- Section 3: Post-install script ---
if [ -f /usr/local/bin/black_aftermath.sh ]; then
    cp /usr/local/bin/black_aftermath.sh "$MOUNT_DIR/root/black_aftermath.sh"
    arch-chroot "$MOUNT_DIR" /bin/bash -c "bash /root/black_aftermath.sh" || echo "WARNING: Aftermath script had errors."
fi

# --- Section 4: Cleanup and reboot ---
log "Unmounting and rebooting..."
umount -R "$MOUNT_DIR" 2>/dev/null || true
sleep 5
reboot
exit 0
