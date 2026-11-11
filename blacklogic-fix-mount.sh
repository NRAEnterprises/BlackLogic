#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools vgscan vgchange lvs lvcreate mkfs.btrfs mount umount btrfs 2>/dev/null || true

VG_NAME="black_pool"
POOL_NAME="black_pool"
MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="64GiB"
CHUNK_SIZE="1G"

echo "=== FIXER: Mount ==="
if mountpoint -q "$MOUNT_DIR"; then
    umount -R "$MOUNT_DIR" 2>/dev/null || true
fi

vgscan --mknodes >/dev/null 2>&1 || true
vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
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
    lvcreate --type thin-pool -l 90%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" || { echo "Failed to create thin pool"; exit 1; }
fi

# Activate the thin pool
lvchange -ay "$VG_NAME/$POOL_NAME" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n root "$VG_NAME" || { echo "Failed to create root LV"; exit 1; }
lvchange -ay "$VG_NAME/root" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

mkfs.btrfs -f "/dev/$VG_NAME/root" || { echo "Failed to format root LV"; exit 1; }
mkdir -p "$MOUNT_DIR"
mount "/dev/$VG_NAME/root" "$MOUNT_DIR" || { echo "Failed to mount root LV"; exit 1; }
btrfs subvolume create "$MOUNT_DIR/@" 2>/dev/null || true
umount "$MOUNT_DIR" 2>/dev/null || true
ROOT_LV="root"

[ -b "/dev/$VG_NAME/$ROOT_LV" ] || { echo "Root device still invalid."; exit 1; }
echo "Mount fixer complete: /dev/$VG_NAME/$ROOT_LV"
exit 0