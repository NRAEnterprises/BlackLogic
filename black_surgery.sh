#!/bin/bash
set -Eeuo pipefail

# --- Variables ---
VG_NAME="black_pool"
POOL_VOL_NAME="blacklogic"
MAIN_ROOT="/dev/$VG_NAME/$POOL_VOL_NAME"
MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="${SURGERY_SIZE:-64GiB}"

# --- Trap Handler ---
cleanup_and_fallback() {
    local exit_code=$?
    echo "=====================================================" >&2
    echo "ERROR: Command failed with exit code $exit_code" >&2
    echo "Initiating automatic fallback/cleanup..." >&2
    echo "=====================================================" >&2

    # Unmount in reverse order
    for mp in "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/boot" "${MOUNT_DIR}/dev" "${MOUNT_DIR}/proc" "${MOUNT_DIR}/sys" "${MOUNT_DIR}"; do
        if mountpoint -q "$mp"; then
            umount -l "$mp" 2>/dev/null || true
        fi
    done

    echo "Cleanup finished. System state may need manual inspection." >&2
    exit $exit_code
}
trap cleanup_and_fallback ERR

# --- Execution Body ---

echo "1. Activating LVM..."
vgscan --mknodes >/dev/null 2>&1 || true
vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
sleep 1

# Find EFI and BOOT partitions
EFI_PART=$(blkid -t LABEL="BLACK-EFI" -o device 2>/dev/null | head -n1)
[ -z "$EFI_PART" ] && EFI_PART=$(blkid -t LABEL="black_EFI" -o device 2>/dev/null | head -n1)
BOOT_PART=$(blkid -t LABEL="black_boot" -o device 2>/dev/null | head -n1)

if [ -z "$EFI_PART" ] || [ -z "$BOOT_PART" ]; then
    echo "ERROR: EFI or BOOT partition not found" >&2
    exit 1
fi

echo "2. Preparing directories and unmounting leftovers..."
mkdir -p "$MOUNT_DIR"
umount -R "$MOUNT_DIR" 2>/dev/null || true

echo "3. Performing shrink operation..."
# Mount the main root to resize the filesystem
mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$MAIN_ROOT" "$MOUNT_DIR" || { echo "Failed to mount root"; exit 1; }

BTRFS_BIN=$(command -v btrfs)
"$BTRFS_BIN" filesystem resize "$NEW_SIZE" "$MOUNT_DIR" || { echo "Btrfs resize failed"; exit 1; }

umount "$MOUNT_DIR" 2>/dev/null || true

# Now shrink the logical volume
LVREDUCE_BIN=$(command -v lvreduce)
"$LVREDUCE_BIN" -L "$NEW_SIZE" "$MAIN_ROOT" || { echo "lvreduce failed"; exit 1; }

echo "4. Remounting main root to fix boot files..."
mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/dev" "${MOUNT_DIR}/proc" "${MOUNT_DIR}/sys"

mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$MAIN_ROOT" "$MOUNT_DIR" || { echo "Failed to remount root"; exit 1; }
mount "$BOOT_PART" "${MOUNT_DIR}/boot" || { echo "Failed to mount boot"; exit 1; }
mount "$EFI_PART" "${MOUNT_DIR}/boot/efi" || { echo "Failed to mount EFI"; exit 1; }
mount --bind /dev "${MOUNT_DIR}/dev" || { echo "Failed to bind dev"; exit 1; }
mount --bind /proc "${MOUNT_DIR}/proc" || { echo "Failed to bind proc"; exit 1; }
mount --bind /sys "${MOUNT_DIR}/sys" || { echo "Failed to bind sys"; exit 1; }

echo "5. Rebuilding Initramfs and GRUB..."
# Run commands directly in chroot
arch-chroot "$MOUNT_DIR" /bin/bash -c "
    set -e
    mkinitcpio -P
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
" || { echo "Chroot commands failed"; exit 1; }

echo "6. Unmounting everything cleanly..."
umount -R "$MOUNT_DIR" 2>/dev/null || true

echo "SUCCESS: The operation completed and the system is ready to reboot."
exit 0