#!/bin/bash
set -uo pipefail
VG_NAME="black_vg"; POOL_NAME="black_pool"; MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="15.00PiB"; CHUNK_SIZE="1G"
echo "=== FIXER: Mount ==="
umount -R "$MOUNT_DIR" 2>/dev/null || true
vgscan --mknodes >/dev/null 2>&1 || true
vgchange -ay --activationmode partial "$VG_NAME" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
vgs "$VG_NAME" &>/dev/null || { echo "VG missing."; exit 1; }
ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
if [ -z "$ROOT_LV" ] || [ ! -b "/dev/$VG_NAME/$ROOT_LV" ]; then
    echo "Rebuilding pool..."
    lvs "$VG_NAME/$POOL_NAME" &>/dev/null || lvcreate --type thin-pool -l 90%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" || exit 1
    lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n root "$VG_NAME" || exit 1
    mkfs.btrfs -f "/dev/$VG_NAME/root" || exit 1
    mkdir -p "$MOUNT_DIR"
    mount "/dev/$VG_NAME/root" "$MOUNT_DIR" || exit 1
    btrfs subvolume create "$MOUNT_DIR/@" || true
    umount "$MOUNT_DIR" || true
    ROOT_LV="root"
fi
[ -b "/dev/$VG_NAME/$ROOT_LV" ] || { echo "Root device still invalid."; exit 1; }
echo "Mount fixer complete: /dev/$VG_NAME/$ROOT_LV"
exit 0
