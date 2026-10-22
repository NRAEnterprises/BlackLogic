#!/bin/bash
set -Eeuo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
MOUNT_DIR="/mnt/blackarch"
STATE_FILE="/tmp/blacklogic-state"

force_umount() {
    local target="$1"
    [ -n "$target" ] || return 0
    if mountpoint -q "$target"; then
        umount -l -f "$target" 2>/dev/null || true
        sleep 1
    fi
    if [ -d "$target" ]; then
        umount -R "$target" 2>/dev/null || true
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must run as root." >&2
        exit 1
    fi
}

require_root

echo "=== Stage 3: OS Installation ==="
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

vgscan >/dev/null 2>&1 || true
vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
sleep 1

ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
[ -n "${ROOT_LV:-}" ] || { echo "No root LV found in $VG_NAME."; exit 1; }
ROOT_PATH="/dev/$VG_NAME/$ROOT_LV"
[ -b "$ROOT_PATH" ] || { echo "$ROOT_PATH is not a valid block device."; exit 1; }

ROOT_PV=$(pvs --noheadings -o pv_name -S "vg_name=$VG_NAME" 2>/dev/null | head -n1 | tr -d ' ' || true)
DISK=""
if [ -n "${ROOT_PV:-}" ]; then
    DISK=$(lsblk -no PKNAME "$ROOT_PV" 2>/dev/null | head -n1 || true)
fi
[ -n "${DISK:-}" ] && DISK="${DISK#/dev/}"
if [ -z "${DISK:-}" ]; then
    DISK=$(echo "$ROOT_PV" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//' || true)
    DISK="${DISK#/dev/}"
fi

EFI=""
BOOT=""
if [ -n "${DISK:-}" ] && [ -b "/dev/$DISK" ]; then
    EFI=$(lsblk -l -n -o NAME,FSTYPE "/dev/$DISK" 2>/dev/null | awk '$2=="vfat"{print "/dev/"$1}' | head -n1 || true)
    BOOT=$(lsblk -l -n -o NAME,FSTYPE "/dev/$DISK" 2>/dev/null | awk '$2=="btrfs"{print "/dev/"$1}' | head -n1 || true)
fi

echo "Root: $ROOT_PATH | Boot: ${BOOT:-none} | EFI: ${EFI:-none}"

force_umount "$MOUNT_DIR/boot"
force_umount "$MOUNT_DIR/boot/efi"
mkdir -p "$MOUNT_DIR"
if ! mountpoint -q "$MOUNT_DIR"; then
    mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$ROOT_PATH" "$MOUNT_DIR" 2>/dev/null || \
    mount "$ROOT_PATH" "$MOUNT_DIR" 2>/dev/null || { echo "Failed to mount root LV at $MOUNT_DIR."; exit 1; }
fi

if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    echo "Bootstrapping Arch..."
    wget -q -O /tmp/bootstrap.tar.zst https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst || { echo "Download failed."; exit 1; }
    tar -I zstd -xpf /tmp/bootstrap.tar.zst -C "$MOUNT_DIR" --strip-components=1 || { echo "Extract failed."; exit 1; }
    cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true
fi

if [ -n "$BOOT" ]; then
    force_umount "$MOUNT_DIR/boot"
    mkdir -p "$MOUNT_DIR/boot"
    mountpoint -q "$MOUNT_DIR/boot" || mount "$BOOT" "$MOUNT_DIR/boot" || { echo "Boot mount failed."; exit 1; }
fi
if [ -n "$EFI" ]; then
    force_umount "$MOUNT_DIR/boot/efi"
    mkdir -p "$MOUNT_DIR/boot/efi"
    mountpoint -q "$MOUNT_DIR/boot/efi" || mount "$EFI" "$MOUNT_DIR/boot/efi" || { echo "EFI mount failed."; exit 1; }
    mountpoint -q "$MOUNT_DIR/boot/efi" || { echo "CRITICAL: EFI not mounted."; exit 1; }
    echo "EFI verified mounted."
fi

for d in dev proc sys run; do
    if ! mountpoint -q "$MOUNT_DIR/$d"; then
        mount --bind "/$d" "$MOUNT_DIR/$d" 2>/dev/null || true
    fi
done

if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    echo "Initializing pacman..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        echo "Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch" > /etc/pacman.d/mirrorlist
        pacman-key --init
        pacman-key --populate archlinux
        pacman -Sy --noconfirm archlinux-keyring
        pacman -Sy --noconfirm
        pacman -S --noconfirm base base-devel linux linux-firmware lvm2 btrfs-progs grub efibootmgr networkmanager vim sudo zram-generator zsh fastfetch
    ' || { echo "Base install failed."; exit 1; }

    echo "Configuring system..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        echo "blackarch" > /etc/hostname
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
        hwclock --systohc 2>/dev/null || true
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen
        echo "LANG=en_US.UTF-8" > /etc/locale.conf
        systemctl enable NetworkManager
        systemctl enable --now lvm2-monitor.service 2>/dev/null || true
        systemctl enable --now dmeventd.service 2>/dev/null || true
        grep -q "monitoring = 1" /etc/lvm/lvm.conf || printf "activation {\n monitoring = 1\n thin_pool_autoextend_threshold = 70\n thin_pool_autoextend_percent = 20\n}\n" >> /etc/lvm/lvm.conf
        sed -i "s/block filesystems/block lvm2 filesystems/" /etc/mkinitcpio.conf
        mkinitcpio -P
    ' || { echo "Config failed."; exit 1; }
fi

echo "Re-verifying mounts..."
if [ -n "$BOOT" ]; then
    force_umount "$MOUNT_DIR/boot"
    mountpoint -q "$MOUNT_DIR/boot" || mount "$BOOT" "$MOUNT_DIR/boot" || { echo "Boot lost."; exit 1; }
fi
if [ -n "$EFI" ]; then
    force_umount "$MOUNT_DIR/boot/efi"
    mountpoint -q "$MOUNT_DIR/boot/efi" || mount "$EFI" "$MOUNT_DIR/boot/efi" || { echo "EFI lost."; exit 1; }
fi
echo "Mounts verified."

echo "Installing GRUB..."
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    pacman -Sy --noconfirm grub efibootmgr || exit 1
    pacman -Q grub >/dev/null 2>&1 || { echo "CRITICAL: grub package not installed."; exit 1; }
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck || exit 1
    grub-mkconfig -o /boot/grub/grub.cfg || exit 1
    [ -f /boot/grub/grub.cfg ] || { echo "CRITICAL: grub.cfg missing after generation."; exit 1; }
    echo "root:blackarch" | chpasswd
' || { echo "GRUB install failed."; exit 1; }

if [ ! -f "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" ]; then
    echo "CRITICAL: grubx64.efi missing on EFI partition."
    ls -laR "$MOUNT_DIR/boot/efi/" 2>/dev/null || true
    exit 1
fi
echo "grubx64.efi verified."

echo "Creating BOOTX64.EFI fallback..."
mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
cp "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
[ -f "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" ] || { echo "CRITICAL: BOOTX64.EFI copy failed."; exit 1; }
echo "BOOTX64.EFI verified."

sync
sync

echo "Install complete."
exit 0
