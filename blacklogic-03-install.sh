#!/bin/bash
set -uo pipefail
SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools mkfs.fat mkfs.btrfs parted btrfs arch-chroot wget tar zstd mount umount 2>/dev/null || true

VG_NAME="black_pool"
POOL_NAME="black_pool"
POOL_VOL_NAME="blacklogic"
MOUNT_DIR="/mnt/blackarch"
LOG_FILE="/var/log/blacklogic.log"
STATE_FILE="/tmp/blacklogic-state"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }
fail() { echo "[$(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

vgscan >/dev/null 2>&1 || true
vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
sleep 1

ROOT_PATH="/dev/$VG_NAME/$POOL_VOL_NAME"
[ -b "$ROOT_PATH" ] || { echo "Root LV not found: $ROOT_PATH"; exit 1; }

EFI_PART="${EFI_PART:-}"
BOOT_PART="${BOOT_PART:-}"

if [ -z "$EFI_PART" ]; then
    EFI_PART=$(blkid -t LABEL="black_EFI" -o device 2>/dev/null | head -n1)
    [ -z "$EFI_PART" ] && EFI_PART=$(blkid -t LABEL="BLACK-EFI" -o device 2>/dev/null | head -n1)
fi
if [ -z "$BOOT_PART" ]; then
    BOOT_PART=$(blkid -t LABEL="black_boot" -o device 2>/dev/null | head -n1)
fi

log "Root: $ROOT_PATH | Boot: ${BOOT_PART:-none} | EFI: ${EFI_PART:-none}"

mkdir -p "$MOUNT_DIR"
mountpoint -q "$MOUNT_DIR" || mount "$ROOT_PATH" "$MOUNT_DIR" || mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$ROOT_PATH" "$MOUNT_DIR" || { echo "Root mount failed."; exit 1; }

if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    log "Bootstrapping Arch base..."
    wget -q -O /tmp/bootstrap.tar.zst https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst || { echo "Download failed."; exit 1; }
    tar -I zstd -xpf /tmp/bootstrap.tar.zst -C "$MOUNT_DIR" --strip-components=1 || { echo "Extract failed."; exit 1; }
    cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true
    # Add BlackArch repository
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        curl -s https://blackarch.org/strap.sh -o /tmp/strap.sh 2>/dev/null || wget -q -O /tmp/strap.sh https://blackarch.org/strap.sh
        chmod +x /tmp/strap.sh
        /tmp/strap.sh || echo "BlackArch strap skipped (keyring unavailable)"
    ' 2>/dev/null || true
fi

if [ -n "$BOOT_PART" ] && [ -b "$BOOT_PART" ]; then
    mkdir -p "$MOUNT_DIR/boot"
    mountpoint -q "$MOUNT_DIR/boot" || mount "$BOOT_PART" "$MOUNT_DIR/boot" || { echo "Boot mount failed."; exit 1; }
fi
if [ -n "$EFI_PART" ] && [ -b "$EFI_PART" ]; then
    mkdir -p "$MOUNT_DIR/boot/efi"
    mountpoint -q "$MOUNT_DIR/boot/efi" || mount "$EFI_PART" "$MOUNT_DIR/boot/efi" || { echo "EFI mount failed."; exit 1; }
    mountpoint -q "$MOUNT_DIR/boot/efi" || { echo "CRITICAL: EFI not mounted."; exit 1; }
    log "EFI verified mounted: $EFI_PART"
fi

for d in dev proc sys run; do
    mountpoint -q "$MOUNT_DIR/$d" || mount --bind "/$d" "$MOUNT_DIR/$d" 2>/dev/null || true
done

if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    log "Initializing pacman..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        echo "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
        pacman-key --init
        pacman-key --populate archlinux
        pacman-key --init && pacman-key --populate archlinux
    pacman -Sy --noconfirm archlinux-keyring
        pacman -Syu --noconfirm
        pacman -S --noconfirm base base-devel linux linux-firmware lvm2 btrfs-progs grub efibootmgr networkmanager sddm vim sudo zram-generator zsh fastfetch plymouth
    ' || { echo "Base install failed."; exit 1; }

    log "Configuring system..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        echo "blackarch" > /etc/hostname
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
        hwclock --systohc 2>/dev/null || true
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen
        echo "LANG=en_US.UTF-8" > /etc/locale.conf
        systemctl enable NetworkManager
        systemctl enable sddm
        printf "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n" > /etc/systemd/zram-generator.conf
        printf "activation {\n thin_pool_autoextend_threshold = 70\n thin_pool_autoextend_percent = 20\n}\n" >> /etc/lvm/lvm.conf
        sed -i "s/^MODULES=.*/MODULES=(btrfs)/" /etc/mkinitcpio.conf
        sed -i "s/^HOOKS=.*/HOOKS=(base udev autodetect modconf block lvm2 filesystems keyboard fsck)/" /etc/mkinitcpio.conf
        mkinitcpio -P
    ' || { echo "Config failed."; exit 1; }
fi

mountpoint -q "$MOUNT_DIR/boot" || mount "$BOOT_PART" "$MOUNT_DIR/boot" || { echo "Boot lost."; exit 1; }
mountpoint -q "$MOUNT_DIR/boot/efi" || mount "$EFI_PART" "$MOUNT_DIR/boot/efi" || { echo "EFI lost."; exit 1; }
# Deduplicate [core]/[extra] sections left by previous runs or BlackArch strap
awk '
/^\[core\]$/ || /^\[extra\]$/ {
    if (seen[$0]++) { skip=1; next }
    skip=0; print; next
}
skip && /^Include = \/etc\/pacman.d\/mirrorlist$/ { next }
{ skip=0; print }
' "$MOUNT_DIR/etc/pacman.conf" > "$MOUNT_DIR/etc/pacman.conf.clean" && mv "$MOUNT_DIR/etc/pacman.conf.clean" "$MOUNT_DIR/etc/pacman.conf"
printf 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch\nServer = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch\nServer = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > "$MOUNT_DIR/etc/pacman.d/mirrorlist"
# Generate /etc/fstab
if [ ! -f "$MOUNT_DIR/etc/fstab" ] || ! grep -q "$ROOT_PATH" "$MOUNT_DIR/etc/fstab" 2>/dev/null; then
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PATH" 2>/dev/null || true)
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART" 2>/dev/null || true)
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)
    {
        [ -n "$ROOT_UUID" ] && echo "UUID=$ROOT_UUID / btrfs subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 0 0"
        [ -n "$BOOT_UUID" ] && echo "UUID=$BOOT_UUID /boot ext4 defaults 0 2"
        [ -n "$EFI_UUID" ] && echo "UUID=$EFI_UUID /boot/efi vfat defaults 0 2"
    } > "$MOUNT_DIR/etc/fstab"
fi

log "Installing GRUB..."
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    grep -q '^\[core\]' /etc/pacman.conf || printf "\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf
    pacman-key --init && pacman-key --populate archlinux
    pacman -Sy --noconfirm
    pacman -S --noconfirm grub efibootmgr || exit 1
    pacman -S --noconfirm --needed plymouth sddm || exit 1
    [ -f /usr/lib/systemd/system/sddm.service ] || { echo "CRITICAL: sddm service missing."; exit 1; }
    pacman -Q grub >/dev/null 2>&1 || { echo "CRITICAL: grub package not installed."; exit 1; }
    # Ensure kernel + initramfs present
    pacman -S --noconfirm --needed linux linux-firmware lvm2 btrfs-progs mkinitcpio || exit 1
    sed -i "s/block filesystems/block lvm2 filesystems/" /etc/mkinitcpio.conf
    mkinitcpio -P || exit 1
    [ -f /boot/vmlinuz-linux ] || { echo "CRITICAL: kernel missing."; exit 1; }
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck || exit 1
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.lvm.vg=black_pool\"|" /etc/default/grub
    grep -q "^GRUB_CMDLINE_LINUX=" /etc/default/grub || echo "GRUB_CMDLINE_LINUX=\"rd.lvm.vg=black_pool\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg || exit 1
    # Put BlackArch first in UEFI boot order
    BA=$(efibootmgr 2>/dev/null | grep -i blackarch | head -1 | grep -o "Boot[0-9A-Fa-f]*" | head -1 | sed "s/Boot//")
    ORDER=$(efibootmgr 2>/dev/null | sed -n "s/BootOrder: //p" | tr "," "\n" | grep -v "^$BA$" | paste -sd, -)
    if [ -n "$BA" ]; then efibootmgr -o "$BA${ORDER:+,$ORDER}" 2>/dev/null || true; fi
    echo "root:blackarch" | chpasswd
' || { echo "GRUB install failed."; exit 1; }

if [ ! -f "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" ] && [ ! -f "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "CRITICAL: grubx64.efi missing on EFI partition."
    exit 1
fi
log "grubx64.efi verified."

if [ -f "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" ]; then
    mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
    cp "$MOUNT_DIR/boot/efi/EFI/BlackArch/grubx64.efi" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
    [ -f "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" ] || { echo "CRITICAL: BOOTX64.EFI copy failed."; exit 1; }
    log "BOOTX64.EFI verified."
fi

if [ -f /usr/local/bin/blacklogic-pool-agent.sh ]; then
    cp /usr/local/bin/blacklogic-pool-agent.sh "$MOUNT_DIR/usr/local/bin/blacklogic-pool-agent.sh" 2>/dev/null || true
    cp /usr/local/bin/blacklogic-ensure-tools.sh "$MOUNT_DIR/usr/local/bin/blacklogic-ensure-tools.sh" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/blacklogic-pool-agent.sh" 2>/dev/null || true
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        cat > /etc/systemd/system/blacklogic-pool-agent.service <<EOF
[Unit]
Description=BlackLogic Thin Pool Agent
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/blacklogic-pool-agent.sh
EOF
        cat > /etc/systemd/system/blacklogic-pool-agent.timer <<EOF
[Unit]
Description=Run BlackLogic Pool Agent hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl enable blacklogic-pool-agent.timer 2>/dev/null || true
    '
fi

log "Install complete."
exit 0
