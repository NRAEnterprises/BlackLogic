#!/bin/bash
set -uo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
MOUNT_DIR="/mnt/blackarch"
STATE_FILE="/tmp/blacklogic-state"

echo "=== Stage 3: OS Installation ==="
[ -f "$STATE_FILE" ] && source "$STATE_FILE"

# 1. Activate LVM
vgscan >/dev/null 2>&1 || true
vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
sleep 1

# 2. Find root LV
ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
[ -z "$ROOT_LV" ] && { echo "No root LV."; exit 1; }
ROOT_PATH="/dev/$VG_NAME/$ROOT_LV"
[ -b "$ROOT_PATH" ] || { echo "$ROOT_PATH not a block device."; exit 1; }

# 3. Trace boot/EFI
ROOT_PV=$(pvs --noheadings -o pv_name -S "vg_name=$VG_NAME" 2>/dev/null | head -n1 | tr -d ' ' || true)
DISK=$(lsblk -no PKNAME "$ROOT_PV" 2>/dev/null | head -n1 || true)
[ -z "$DISK" ] && DISK=$(echo "$ROOT_PV" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
EFI=$(lsblk -l -n -o NAME,FSTYPE "/dev/$DISK" 2>/dev/null | awk '$2=="vfat"{print "/dev/"$1}' | head -n1)
BOOT=$(lsblk -l -n -o NAME,FSTYPE "/dev/$DISK" 2>/dev/null | awk '$2=="btrfs"{print "/dev/"$1}' | head -n1)
echo "Root: $ROOT_PATH | Boot: ${BOOT:-none} | EFI: ${EFI:-none}"

# 4. Mount root
mkdir -p "$MOUNT_DIR"
mountpoint -q "$MOUNT_DIR" || mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$ROOT_PATH" "$MOUNT_DIR" 2>/dev/null || mount "$ROOT_PATH" "$MOUNT_DIR" 2>/dev/null || { echo "Root mount failed."; exit 1; }

# 5. Bootstrap if OS missing
if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    echo "Bootstrapping Arch..."
    wget -q -O /tmp/bootstrap.tar.zst https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst || { echo "Download failed."; exit 1; }
    tar -I zstd -xpf /tmp/bootstrap.tar.zst -C "$MOUNT_DIR" --strip-components=1 || { echo "Extract failed."; exit 1; }
    cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true
fi

# 6. Mount boot/EFI on the HOST, then bind
if [ -n "$BOOT" ]; then
    mkdir -p "$MOUNT_DIR/boot"
    mountpoint -q "$MOUNT_DIR/boot" || mount "$BOOT" "$MOUNT_DIR/boot" || { echo "Boot mount failed."; exit 1; }
fi
if [ -n "$EFI" ]; then
    mkdir -p "$MOUNT_DIR/boot/efi"
    mountpoint -q "$MOUNT_DIR/boot/efi" || mount "$EFI" "$MOUNT_DIR/boot/efi" || { echo "EFI mount failed."; exit 1; }
    mountpoint -q "$MOUNT_DIR/boot/efi" || { echo "CRITICAL: EFI not mounted."; exit 1; }
    echo "EFI verified mounted."
fi

# 7. Bind system dirs
for d in dev proc sys run; do
    mountpoint -q "$MOUNT_DIR/$d" || mount --bind "/$d" "$MOUNT_DIR/$d" 2>/dev/null || true
done

# 8. Run installation if OS missing
if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    echo "Initializing pacman..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        echo "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
        pacman-key --init
        pacman-key --populate archlinux
        pacman -Sy --noconfirm archlinux-keyring
        pacman -Syu --noconfirm
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
        printf "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n" > /etc/systemd/zram-generator.conf
        printf "activation {\n thin_pool_autoextend_threshold = 70\n thin_pool_autoextend_percent = 20\n}\n" >> /etc/lvm/lvm.conf
        sed -i "s/block filesystems/block lvm2 filesystems/" /etc/mkinitcpio.conf
        mkinitcpio -P
    ' || { echo "Config failed."; exit 1; }
fi

# 9. Re-verify mounts before GRUB
echo "Re-verifying mounts..."
mountpoint -q "$MOUNT_DIR/boot" || mount "$BOOT" "$MOUNT_DIR/boot" || { echo "Boot lost."; exit 1; }
mountpoint -q "$MOUNT_DIR/boot/efi" || mount "$EFI" "$MOUNT_DIR/boot/efi" || { echo "EFI lost."; exit 1; }
echo "Mounts verified."

# 10. Install GRUB with pacman -Q verification
echo "Installing GRUB..."
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    pacman -S --noconfirm grub efibootmgr || exit 1
    pacman -Q grub >/dev/null 2>&1 || { echo "CRITICAL: grub package not installed."; exit 1; }
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck || exit 1
    grub-mkconfig -o /boot/grub/grub.cfg || exit 1
    echo "root:blackarch" | chpasswd
' || { echo "GRUB install failed."; exit 1; }

# 11. Verify grubx64.efi exists on host
if [ ! -f "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" ]; then
    echo "CRITICAL: grubx64.efi missing on EFI partition."
    ls -laR "$MOUNT_DIR/boot/efi/" 2>/dev/null
    exit 1
fi
echo "grubx64.efi verified."

# 12. Create BOOTX64.EFI fallback with verification
echo "Creating BOOTX64.EFI fallback..."
if [ -f "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" ]; then
    mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
    cp "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
    [ -f "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" ] || { echo "CRITICAL: BOOTX64.EFI copy failed."; exit 1; }
    echo "BOOTX64.EFI verified."
fi

echo "Install complete."
exit 0
