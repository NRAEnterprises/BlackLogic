#!/bin/bash
set -Eeuo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="15.00PiB"
CHUNK_SIZE="1G"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root." >&2
    exit 1
fi

echo "=== FIXER: Mount ==="
if mountpoint -q "$MOUNT_DIR"; then
    umount -R "$MOUNT_DIR" 2>/dev/null || true
fi

vgscan --mknodes >/dev/null 2>&1 || true
vgchange -ay --activationmode partial "$VG_NAME" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
vgs "$VG_NAME" &>/dev/null || { echo "VG missing."; exit 1; }

ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
if [ -n "${ROOT_LV:-}" ] && [ -b "/dev/$VG_NAME/$ROOT_LV" ]; then
    ROOT_FS=$(blkid -o value -s TYPE "/dev/$VG_NAME/$ROOT_LV" 2>/dev/null || true)
    if [ "$ROOT_FS" = "btrfs" ]; then
        echo "Existing Btrfs root LV is valid. Leaving it alone."
        exit 0
    fi
    echo "Root LV exists but is not Btrfs; refusing to overwrite a healthy root."
    exit 0
fi

if ! lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
    lvcreate --type thin-pool -l 90%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" || exit 1
fi

lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n root "$VG_NAME" || exit 1
mkfs.btrfs -f "/dev/$VG_NAME/root" || exit 1
mkdir -p "$MOUNT_DIR"
mount "/dev/$VG_NAME/root" "$MOUNT_DIR" || exit 1
btrfs subvolume create "$MOUNT_DIR/@" || true
umount "$MOUNT_DIR" || true
ROOT_LV="root"

[ -b "/dev/$VG_NAME/$ROOT_LV" ] || { echo "Root device still invalid."; exit 1; }
echo "Mount fixer complete: /dev/$VG_NAME/$ROOT_LV"
exit 0
