#!/bin/bash
set -Eeuo pipefail

# BlackLogic Surgery/Repair Script
# Use this script for recovery and repair operations on an existing BlackLogic installation
# It can resize the root LV, rebuild initramfs, fix GRUB, and more

SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools vgscan vgchange lvs lvcreate lvextend lvremove mkfs.btrfs mount umount btrfs arch-chroot grub-install grub-mkconfig efibootmgr 2>/dev/null || true

# --- Variables ---
VG_NAME="black_pool"
POOL_VOL_NAME="blacklogic"
MAIN_ROOT="/dev/$VG_NAME/$POOL_VOL_NAME"
MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="${SURGERY_SIZE:-64GiB}"
STATE_FILE="/tmp/blacklogic-state"
LOG_FILE="/var/log/blacklogic-surgery.log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }
fail() { echo "[$(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }

# --- Load state ---
[ -f "$STATE_FILE" ] && source "$STATE_FILE"

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
EFI_PART="${EFI_PART:-}"
BOOT_PART="${BOOT_PART:-}"

if [ -z "$EFI_PART" ]; then
    EFI_PART=$(blkid -t LABEL="BLACK-EFI" -o device 2>/dev/null | head -n1)
    [ -z "$EFI_PART" ] && EFI_PART=$(blkid -t LABEL="black_EFI" -o device 2>/dev/null | head -n1)
fi
if [ -z "$BOOT_PART" ]; then
    BOOT_PART=$(blkid -t LABEL="black_boot" -o device 2>/dev/null | head -n1)
fi

if [ -z "$EFI_PART" ] || [ -z "$BOOT_PART" ]; then
    echo "ERROR: EFI or BOOT partition not found" >&2
    echo "Use blkid to find partitions and set EFI_PART and BOOT_PART environment variables" >&2
    exit 1
fi

echo "2. Preparing directories and unmounting leftovers..."
mkdir -p "$MOUNT_DIR"
umount -R "$MOUNT_DIR" 2>/dev/null || true

echo "3. Checking root filesystem..."
mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$MAIN_ROOT" "$MOUNT_DIR" || { echo "Failed to mount root"; exit 1; }

echo "4. Performing resize operation (if requested)..."
if [ -n "${SURGERY_RESIZE:-}" ]; then
    echo "Resizing filesystem to $NEW_SIZE..."
    BTRFS_BIN=$(command -v btrfs)
    "$BTRFS_BIN" filesystem resize "$NEW_SIZE" "$MOUNT_DIR" || { echo "Btrfs resize failed"; exit 1; }
    umount "$MOUNT_DIR" 2>/dev/null || true
    LVREDUCE_BIN=$(command -v lvreduce)
    "$LVREDUCE_BIN" -L "$NEW_SIZE" "$MAIN_ROOT" || { echo "lvreduce failed"; exit 1; }
    mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$MAIN_ROOT" "$MOUNT_DIR" || { echo "Failed to remount root"; exit 1; }
fi

echo "5. Remounting main root to fix boot files..."
mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/dev" "${MOUNT_DIR}/proc" "${MOUNT_DIR}/sys"

mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$MAIN_ROOT" "$MOUNT_DIR" || { echo "Failed to remount root"; exit 1; }
mount "$BOOT_PART" "${MOUNT_DIR}/boot" || { echo "Failed to mount boot"; exit 1; }
mount "$EFI_PART" "${MOUNT_DIR}/boot/efi" || { echo "Failed to mount EFI"; exit 1; }
mount --bind /dev "${MOUNT_DIR}/dev" || { echo "Failed to bind dev"; exit 1; }
mount --bind /proc "${MOUNT_DIR}/proc" || { echo "Failed to bind proc"; exit 1; }
mount --bind /sys "${MOUNT_DIR}/sys" || { echo "Failed to bind sys"; exit 1; }

echo "6. Rebuilding Initramfs and GRUB..."
arch-chroot "$MOUNT_DIR" /bin/bash -c "
    set -e
    mkinitcpio -P
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
" || { echo "Chroot commands failed"; exit 1; }

echo "7. Unmounting everything cleanly..."
umount -R "$MOUNT_DIR" 2>/dev/null || true

echo "SUCCESS: The operation completed and the system is ready to reboot."
exit 0