#!/bin/bash
set -Eeuo pipefail

# --- Activate LVM ---
vgchange -ay

# --- Variables ---
MAIN_ROOT="/dev/black_vg/root"
EFI_PART="/dev/sdb1"
BOOT_PART="/dev/sdb2"
MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="500G"

# --- Trap Handler ---
cleanup_and_fallback() {
    local exit_code=$?
    echo "=====================================================" >&2
    echo "ERROR: Command failed with exit code $exit_code" >&2
    echo "Initiating automatic fallback/cleanup..." >&2
    echo "=====================================================" >&2

    if mountpoint -q "${MOUNT_DIR}/boot/efi"; then umount "${MOUNT_DIR}/boot/efi" || true; fi
    if mountpoint -q "${MOUNT_DIR}/boot"; then umount "${MOUNT_DIR}/boot" || true; fi
    if mountpoint -q "${MOUNT_DIR}/dev"; then umount "${MOUNT_DIR}/dev" || true; fi
    if mountpoint -q "${MOUNT_DIR}/proc"; then umount "${MOUNT_DIR}/proc" || true; fi
    if mountpoint -q "${MOUNT_DIR}/sys"; then umount "${MOUNT_DIR}/sys" || true; fi
    if mountpoint -q "${MOUNT_DIR}"; then umount "${MOUNT_DIR}" || true; fi

    echo "Cleanup finished. System state may need manual inspection." >&2
    exit $exit_code
}
trap cleanup_and_fallback ERR

# --- Execution Body ---

echo "1. Ensuring Btrfs tools are installed in Kali..."
apt update -qq && apt install -y btrfs-progs > /dev/null

echo "2. Preparing directories and unmounting leftovers..."
mkdir -p "$MOUNT_DIR"
umount -R "$MOUNT_DIR" 2>/dev/null || true

echo "3. Performing the shrink operation directly from Kali..."
# Mount the main root just to resize the filesystem
mount "$MAIN_ROOT" "$MOUNT_DIR"

# Find the exact path to btrfs and run it
BTRFS_BIN=$(command -v btrfs)
"$BTRFS_BIN" filesystem resize "$NEW_SIZE" "$MOUNT_DIR"

umount "$MOUNT_DIR"

# Now shrink the logical volume
LVREDUCE_BIN=$(command -v lvreduce)
"$LVREDUCE_BIN" -L "$NEW_SIZE" "$MAIN_ROOT"

echo "4. Remounting main root to fix boot files..."
mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/dev" "${MOUNT_DIR}/proc" "${MOUNT_DIR}/sys"

mount -o compress=zstd:3,subvol=@,noatime,discard=async,space_cache=v2 "$MAIN_ROOT" "$MOUNT_DIR"
mount "$BOOT_PART" "${MOUNT_DIR}/boot"
mount "$EFI_PART" "${MOUNT_DIR}/boot/efi"
mount --bind /dev "${MOUNT_DIR}/dev"
mount --bind /proc "${MOUNT_DIR}/proc"
mount --bind /sys "${MOUNT_DIR}/sys"

echo "5. Rebuilding Initramfs and GRUB..."
cat /usr/local/bin/black_surgery.sh | chroot "$MOUNT_DIR" /bin/bash -c '
    cat > /usr/local/bin/black_surgery.sh
    chmod +x /usr/local/bin/black_surgery.sh
    mkinitcpio -P
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
'

echo "6. Unmounting everything cleanly..."
umount -R "$MOUNT_DIR"

echo "SUCCESS: The operation completed and the system is ready to reboot."
