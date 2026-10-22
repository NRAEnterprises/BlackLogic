#!/bin/bash
set -uo pipefail
MOUNT_DIR="/mnt/blackarch"; VG_NAME="black_vg"; POOL_NAME="black_pool"
echo "=== Stage 4: Aftermath ==="
if ! mountpoint -q "$MOUNT_DIR"; then
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
    [ -z "$ROOT_LV" ] && { echo "No root LV."; exit 1; }
    mkdir -p "$MOUNT_DIR"
    mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "/dev/$VG_NAME/$ROOT_LV" "$MOUNT_DIR" 2>/dev/null || mount "/dev/$VG_NAME/$ROOT_LV" "$MOUNT_DIR" || exit 1
fi
[ ! -f "$MOUNT_DIR/etc/os-release" ] && { echo "OS missing."; umount -R "$MOUNT_DIR" 2>/dev/null; exit 1; }
if [ -f /usr/local/bin/black_aftermath.sh ]; then
    cp /usr/local/bin/black_aftermath.sh "$MOUNT_DIR/root/black_aftermath.sh"
    arch-chroot "$MOUNT_DIR" /bin/bash -c "bash /root/black_aftermath.sh" || echo "WARNING: Aftermath script had errors."
fi
echo "Unmounting and rebooting..."
umount -R "$MOUNT_DIR" 2>/dev/null || true
sleep 5
reboot
exit 0
