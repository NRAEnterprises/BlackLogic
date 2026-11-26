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
mountpoint -q "$MOUNT_DIR" || mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "$ROOT_PATH" "$MOUNT_DIR" || { echo "Root mount failed."; exit 1; }

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
    mountpoint -q "$MOUNT_DIR/$d" || mount --bind "/$d" "$MOUNT_DIR/$d" || { echo "Bind mount $d failed."; exit 1; }
done

# Interactive system configuration
echo "=== System Configuration ==="

# Hostname
echo "Enter hostname (default: blackarch):"
read -r HOSTNAME_INPUT < /dev/tty
HOSTNAME=${HOSTNAME_INPUT:-blackarch}

# Username
echo "Enter username for the primary user (default: user):"
read -r USERNAME_INPUT < /dev/tty
USERNAME=${USERNAME_INPUT:-user}

# Timezone
echo "Enter timezone (default: UTC, e.g. America/New_York):"
read -r TIMEZONE_INPUT < /dev/tty
TIMEZONE=${TIMEZONE_INPUT:-UTC}

# Display Manager selection
echo "Select display manager:"
echo "  1) GDM (GNOME Display Manager)"
echo "  2) SDDM (KDE Display Manager)"
echo "  3) LightDM (Light Display Manager)"
echo "  4) LXDM (LXDE Display Manager)"
echo "  5) None (no display manager)"
read -r -p "Choice [1-5]: " DM_CHOICE < /dev/tty
case "$DM_CHOICE" in
    1) DM_PACKAGE="gdm" ;;
    2) DM_PACKAGE="sddm" ;;
    3) DM_PACKAGE="lightdm" ;;
    4) DM_PACKAGE="lxdm" ;;
    5) DM_PACKAGE="" ;;
    *) DM_PACKAGE="gdm" ;;
esac

# Desktop Environment selection
echo "Select desktop environment:"
echo "  1) None (minimal install)"
echo "  2) Xfce4"
echo "  3) KDE Plasma"
echo "  4) GNOME"
echo "  5) LXDE"
echo "  6) i3 (tiling)"
echo "  7) Sway (Wayland tiling)"
echo "  8) Hyprland (Wayland tiling)"
read -r -p "Choice [1-8]: " DE_CHOICE < /dev/tty
case "$DE_CHOICE" in
    1) DE_PACKAGE="" ;;
    2) DE_PACKAGE="xfce4 xfce4-goodies" ;;
    3) DE_PACKAGE="plasma plasma-meta" ;;
    4) DE_PACKAGE="gnome gnome-extra" ;;
    5) DE_PACKAGE="lxde" ;;
    6) DE_PACKAGE="i3-wm i3status i3lock" ;;
    7) DE_PACKAGE="sway swaybg swayidle swaylock" ;;
    8) DE_PACKAGE="hyprland" ;;
    *) DE_PACKAGE="" ;;
esac

# SSH setup
echo "Set up SSH server? (y/n, default: y):"
read -r SSH_INPUT < /dev/tty
case "${SSH_INPUT:-y}" in
    [Yy]*|[Yy][Ee][Ss]*) SETUP_SSH="yes" ;;
    *) SETUP_SSH="no" ;;
esac

# Save configuration to state file
echo "HOSTNAME=$HOSTNAME" >> "$STATE_FILE"
echo "USERNAME=$USERNAME" >> "$STATE_FILE"
echo "TIMEZONE=$TIMEZONE" >> "$STATE_FILE"
echo "DM_PACKAGE=$DM_PACKAGE" >> "$STATE_FILE"
echo "DE_PACKAGE=$DE_PACKAGE" >> "$STATE_FILE"
echo "SETUP_SSH=$SETUP_SSH" >> "$STATE_FILE"

if [ ! -f "$MOUNT_DIR/etc/os-release" ]; then
    log "Initializing pacman..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        echo "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
        pacman-key --init
        pacman-key --populate archlinux
        pacman -Sy --noconfirm archlinux-keyring
        pacman -Syu --noconfirm
    ' || { echo "Base install failed."; exit 1; }

    log "Installing core packages..."
    # Load firmware list
    FIRMWARE_PKGS="linux-firmware"
    if [ -f "$STATE_FILE.firmware" ]; then
        FIRMWARE_PKGS=$(cat "$STATE_FILE.firmware" | tr '\n' ' ')
    fi

    # Build package list
    BASE_PKGS="base base-devel linux linux-lts linux-firmware $FIRMWARE_PKGS"
    BASE_PKGS="$BASE_PKGS lvm2 btrfs-progs grub efibootmgr"
    BASE_PKGS="$BASE_PKGS networkmanager wpa_supplicant iwd dhcpcd"
    BASE_PKGS="$BASE_PKGS vim nano sudo zsh zram-generator"
    BASE_PKGS="$BASE_PKGS git jq curl wget which tree file"
    BASE_PKGS="$BASE_PKGS fastfetch plymouth"
    BASE_PKGS="$BASE_PKGS openssh rsync"

    # Add DM if selected
    [ -n "$DM_PACKAGE" ] && BASE_PKGS="$BASE_PKGS $DM_PACKAGE"

    # Add DE if selected
    [ -n "$DE_PACKAGE" ] && BASE_PKGS="$BASE_PKGS $DE_PACKAGE"

    # Server tools
    BASE_PKGS="$BASE_PKGS nginx apache postgresql redis mongodb"

    # Container/VM tools
    BASE_PKGS="$BASE_PKGS docker podman qemu libvirt virt-manager"

    # Networking/security
    BASE_PKGS="$BASE_PKGS nftables fail2ban reflector chrony"

    # Monitoring
    BASE_PKGS="$BASE_PKGS htop iotop nmon glances netdata"

    # Hardware monitoring
    BASE_PKGS="$BASE_PKGS smartmontools nvme-cli hdparm lm_sensors"

    # Backup
    BASE_PKGS="$BASE_PKGS restic borgbackup"

    # Development
    BASE_PKGS="$BASE_PKGS python python-pip nodejs npm cargo go rust"

    # Build tools
    BASE_PKGS="$BASE_PKGS cmake ninja meson gcc clang make"

    # Editors
    BASE_PKGS="$BASE_PKGS neovim emacs micro"

    # Terminals
    BASE_PKGS="$BASE_PKGS alacritty kitty wezterm"

    # CLI tools
    BASE_PKGS="$BASE_PKGS ripgrep fzf bat fd tree"

    # Filesystem
    BASE_PKGS="$BASE_PKGS btrfs-assistant snapper"

    # Launchers
    BASE_PKGS="$BASE_PKGS rofi dmenu wofi"

    # Desktop utilities
    BASE_PKGS="$BASE_PKGS xdg-utils xdg-user-dirs"

    # Install everything
    arch-chroot "$MOUNT_DIR" /bin/bash -c "
        pacman -S --noconfirm --needed $BASE_PKGS
    " || { echo "Package install failed."; exit 1; }

    log "Configuring system..."
    arch-chroot "$MOUNT_DIR" /bin/bash -c "
        echo '$HOSTNAME' > /etc/hostname
        ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
        hwclock --systohc 2>/dev/null || true
        echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
        locale-gen
        echo 'LANG=en_US.UTF-8' > /etc/locale.conf
        systemctl enable NetworkManager
        systemctl enable sshd
        systemctl enable nftables
        systemctl enable chronyd
        systemctl enable fail2ban
        systemctl enable reflector.timer
        printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' > /etc/systemd/zram-generator.conf
        printf 'activation {\n thin_pool_autoextend_threshold = 70\n thin_pool_autoextend_percent = 20\n}\n' >> /etc/lvm/lvm.conf
        sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
        sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block lvm2 filesystems keyboard)/' /etc/mkinitcpio.conf
        mkinitcpio -P
    " || { echo "Config failed."; exit 1; }

    # Create user
    if [ "$USERNAME" != "root" ]; then
        arch-chroot "$MOUNT_DIR" /bin/bash -c "
            useradd -m -G wheel,audio,video,storage,network -s /usr/bin/zsh $USERNAME
            echo '$USERNAME:blackarch' | chpasswd
            echo '$USERNAME ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
        " || warn "User creation failed."
    fi

    # Enable display manager if selected
    if [ -n "$DM_PACKAGE" ]; then
        arch-chroot "$MOUNT_DIR" /bin/bash -c "
            systemctl enable ${DM_PACKAGE}.service
        " || warn "DM enable failed."
    fi
fi

# Generate fstab
log "Generating fstab..."
udevadm settle 2>/dev/null || true
sleep 1

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PATH" 2>/dev/null || true)
BOOT_UUID=""
EFI_UUID=""
[ -n "$BOOT_PART" ] && [ -b "$BOOT_PART" ] && BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART" 2>/dev/null || true)
[ -n "$EFI_PART" ] && [ -b "$EFI_PART" ] && EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)

[ -n "$ROOT_UUID" ] || { echo "CRITICAL: Root UUID not found"; exit 1; }

cat > "$MOUNT_DIR/etc/fstab" <<FSTAB
# /etc/fstab: static file system information
# Generated by BlackLogic installer

# Root filesystem (Btrfs on LVM thin pool)
UUID=$ROOT_UUID  /  btrfs  rw,relatime,compress=zstd:3,space_cache=v2,subvol=@  0  0
FSTAB

if [ -n "$BOOT_UUID" ]; then
    echo "UUID=$BOOT_UUID  /boot  btrfs  rw,relatime  0  2" >> "$MOUNT_DIR/etc/fstab"
fi
if [ -n "$EFI_UUID" ]; then
    echo "UUID=$EFI_UUID  /boot/efi  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0  1" >> "$MOUNT_DIR/etc/fstab"
fi

log "fstab generated:"
cat "$MOUNT_DIR/etc/fstab" | tee -a "$LOG_FILE"

# Deduplicate pacman.conf
awk '
/^\[core\]$/ || /^\[extra\]$/ {
    if (seen[$0]++) { skip=1; next }
    skip=0; print; next
}
skip && /^Include = \/etc\/pacman.d\/mirrorlist$/ { next }
{ skip=0; print }
' "$MOUNT_DIR/etc/pacman.conf" > "$MOUNT_DIR/etc/pacman.conf.clean" && mv "$MOUNT_DIR/etc/pacman.conf.clean" "$MOUNT_DIR/etc/pacman.conf"

if grep -q "mirror.rackspace.com" "$MOUNT_DIR/etc/pacman.d/mirrorlist" 2>/dev/null; then :; else
    printf 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch\nServer = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch\nServer = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > "$MOUNT_DIR/etc/pacman.d/mirrorlist"
fi

log "Installing GRUB..."
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    if [ ! -s /etc/pacman.d/mirrorlist ] || ! grep -q "mirror.rackspace.com" /etc/pacman.d/mirrorlist; then
        printf "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch\nServer = https://mirrors.edge.kernel.org/archlinux/\$repo/os/\$arch\nServer = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch\n" > /etc/pacman.d/mirrorlist
    fi
    grep -q "^\\[core\\]" /etc/pacman.conf || printf "\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf
    pacman -Sy --noconfirm
    pacman -S --noconfirm grub efibootmgr || exit 1
    [ -r /boot/vmlinuz-linux ] || { echo "Kernel not readable, reinstalling..."; pacman -S --noconfirm --overwrite \* linux linux-firmware || exit 1; }
    [ -r /boot/vmlinuz-linux ] || { echo "CRITICAL: kernel missing or unreadable."; exit 1; }
    sed -i "s/^MODULES=.*/MODULES=(btrfs)/" /etc/mkinitcpio.conf
    sed -i "s/^HOOKS=.*/HOOKS=(base udev autodetect modconf block lvm2 filesystems keyboard)/" /etc/mkinitcpio.conf
    mkinitcpio -P || exit 1
    [ -f /usr/lib/systemd/system/${DM_PACKAGE:-gdm}.service ] || { echo "CRITICAL: DM service missing."; exit 1; }
    pacman -Q grub >/dev/null 2>&1 || { echo "CRITICAL: grub package not installed."; exit 1; }
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck || exit 1
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.lvm.vg=black_pool rd.lvm.lv=black_pool/black_pool rd.lvm.lv=black_pool/blacklogic\"|" /etc/default/grub
    grep -q "^GRUB_CMDLINE_LINUX=" /etc/default/grub || echo "GRUB_CMDLINE_LINUX=\"rd.lvm.vg=black_pool rd.lvm.lv=black_pool/black_pool rd.lvm.lv=black_pool/blacklogic\"" >> /etc/default/grub
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

# Setup snapper for Btrfs snapshots
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    if command -v snapper >/dev/null 2>&1; then
        snapper create-config /
        systemctl enable snapper-timeline.timer 2>/dev/null || true
        systemctl enable snapper-cleanup.timer 2>/dev/null || true
    fi
' || true

# Setup reflector
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    if command -v reflector >/dev/null 2>&1; then
        cat > /etc/xdg/reflector/reflector.conf <<EOF
--save /etc/pacman.d/mirrorlist
--protocol https
--latest 20
--sort rate
EOF
        systemctl enable reflector.timer 2>/dev/null || true
    fi
' || true

# Setup fail2ban
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    if command -v fail2ban-server >/dev/null 2>&1; then
        systemctl enable fail2ban 2>/dev/null || true
    fi
' || true

# Setup chrony
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    if command -v chronyd >/dev/null 2>&1; then
        systemctl enable chronyd 2>/dev/null || true
    fi
' || true

# Setup nftables
arch-chroot "$MOUNT_DIR" /bin/bash -c '
    if command -v nft >/dev/null 2>&1; then
        systemctl enable nftables 2>/dev/null || true
    fi
' || true

# SSH setup if selected
if [ "$SETUP_SSH" = "yes" ]; then
    arch-chroot "$MOUNT_DIR" /bin/bash -c '
        ssh-keygen -A
        systemctl enable sshd
    ' || warn "SSH setup failed."
fi

log "Install complete."
exit 0