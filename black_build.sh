#!/bin/bash
set -Eeuo pipefail

# --- Variables ---
DRIVE1="/dev/sdb"
DRIVE2="/dev/sdc"
MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="15.00PiB"
CHUNK_SIZE="1G"

cleanup() {
    local exit_code=$?
    echo "ERROR: Command failed. Exiting." >&2
    umount -R "$MOUNT_DIR" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    exit $exit_code
}
trap cleanup ERR

echo "=== 1. Wiping and Partitioning Drives ==="
wipefs -a "$DRIVE1"
wipefs -a "$DRIVE2"

# Drive 1: EFI, Boot, Swap, Surgery VG, Main VG (PV)
parted -s "$DRIVE1" mklabel gpt
parted -s "$DRIVE1" mkpart primary fat32 1MiB 513MiB
parted -s "$DRIVE1" set 1 esp on
parted -s "$DRIVE1" mkpart primary btrfs 513MiB 1537MiB
parted -s "$DRIVE1" mkpart primary linux-swap 1537MiB 9729MiB
parted -s "$DRIVE1" mkpart primary 9729MiB 13825MiB # Surgery (4GB)
parted -s "$DRIVE1" mkpart primary 13825MiB 100%   # Main PV

# Drive 2: Entirely dedicated to the Main PV, named black_ext1
parted -s "$DRIVE2" mklabel gpt
parted -s "$DRIVE2" mkpart black_ext1 1MiB 100%

sleep 2
partprobe "$DRIVE1"
partprobe "$DRIVE2"
udevadm settle

echo "=== 2. Formatting Filesystems ==="
mkfs.fat -F32 "${DRIVE1}1"
mkfs.btrfs -f "${DRIVE1}2"
mkswap "${DRIVE1}3"
mkfs.btrfs -f "${DRIVE1}4"

echo "=== 3. Setting up LVM ==="
pvcreate -f "${DRIVE1}4" "${DRIVE1}5" "${DRIVE2}1"
vgcreate surgery_vg "${DRIVE1}4"
vgcreate black_vg "${DRIVE1}5" "${DRIVE2}1"

lvcreate -l 100%FREE -n surgery_root surgery_vg
mkfs.btrfs -f /dev/surgery_vg/surgery_root

# Main Pool (10% of VG, max chunk size)
lvcreate --type thin-pool -l 10%VG -c "$CHUNK_SIZE" -n black_pool black_vg
lvcreate -V "$NEW_SIZE" --thinpool black_pool -n root black_vg

echo "=== 4. Formatting and Mounting BlackArch Root ==="
mkfs.btrfs -f /dev/black_vg/root
mount /dev/black_vg/root "$MOUNT_DIR"
btrfs subvolume create "${MOUNT_DIR}/@"
umount "$MOUNT_DIR"

mount -o compress=zstd:3,subvol=@,noatime,discard=async,space_cache=v2 /dev/black_vg/root "$MOUNT_DIR"
mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/boot/efi"
mount "${DRIVE1}2" "${MOUNT_DIR}/boot"
mount "${DRIVE1}1" "${MOUNT_DIR}/boot/efi"
swapon "${DRIVE1}3"

echo "=== 5. Installing Base System (Pacstrap) ==="
sed -i '/\[community\]/,/Include =/ s/^/#/' /etc/pacman.conf

pacstrap -K "$MOUNT_DIR" base base-devel linux linux-firmware lvm2 btrfs-progs grub efibootmgr networkmanager vim sudo

echo "=== 6. Configuring the System (Chroot) ==="
genfstab -U "$MOUNT_DIR" >> "${MOUNT_DIR}/etc/fstab"

cat << CHROOT_EOF | arch-chroot "$MOUNT_DIR"
echo "blackarch" > /etc/hostname

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

systemctl enable NetworkManager

cat << LVM_EOF >> /etc/lvm/lvm.conf
activation {
    thin_pool_autoextend_threshold = 70
    thin_pool_autoextend_percent = 20
}
LVM_EOF

sed -i 's/block filesystems/block lvm2 filesystems/' /etc/mkinitcpio.conf
mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlackArch --removable --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "root:blackarch" | chpasswd

curl -O https://blackarch.org/strap.sh
chmod +x strap.sh
./strap.sh
CHROOT_EOF

echo "=== 7. Unmounting and Finishing ==="
umount -R "$MOUNT_DIR"
swapoff -a

echo "SUCCESS: The system is fully built. You can now reboot."
