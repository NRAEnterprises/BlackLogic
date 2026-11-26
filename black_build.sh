#!/bin/bash
set -Eeuo pipefail

# BlackLogic Standalone Builder
# Use this script if you already have drives partitioned and just want to set them up
# It will discover existing partitions and set up the LVM/Btrfs structure

SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools parted wipefs pvcreate vgcreate vgextend lvcreate lvextend mkfs.fat mkfs.btrfs partprobe blkid lsblk lvs vgs pvs mount umount findmnt 2>/dev/null || true

MOUNT_DIR="/mnt/blackarch"
NEW_SIZE="${SURGERY_SIZE:-64GiB}"
CHUNK_SIZE="1G"
STATE_FILE="/tmp/blacklogic-state"
LOG_FILE="/var/log/blacklogic-build.log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }
fail() { echo "[$(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }

cleanup() {
    local exit_code=$?
    echo "ERROR: Command failed with exit code $exit_code" >&2
    umount -R "$MOUNT_DIR" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    exit $exit_code
}
trap cleanup ERR

# Discover existing partitions
echo "=== Discovering existing partitions ==="

declare -a EFI_PARTS=()
declare -a BOOT_PARTS=()
declare -a PV_PARTS=()
declare -a SWAP_PARTS=()

while IFS= read -r line; do
    [ -z "$line" ] && continue
    DEV=$(echo "$line" | awk '{print $1}')
    LABEL=$(echo "$line" | awk '{print $2}')
    FSTYPE=$(echo "$line" | awk '{print $3}')

    case "$LABEL" in
        BLACK-EFI|black_EFI) EFI_PARTS+=("$DEV") ;;
        black_boot) BOOT_PARTS+=("$DEV") ;;
        black_swap) SWAP_PARTS+=("$DEV") ;;
        *) 
            if [ "$FSTYPE" = "LVM2_member" ] || [ "$FSTYPE" = "linux" ]; then
                PV_PARTS+=("$DEV")
            fi
            ;;
    esac
done < <(blkid -o export 2>/dev/null | awk -F= '/DEVNAME=/{dev=$2} /LABEL=/{label=$2} /TYPE=/{type=$2} /^$/{if(dev) print dev,label,type; dev="";label="";type=""}')

echo "Found EFI partitions: ${EFI_PARTS[*]:-none}"
echo "Found BOOT partitions: ${BOOT_PARTS[*]:-none}"
echo "Found PV partitions: ${PV_PARTS[*]:-none}"
echo "Found SWAP partitions: ${SWAP_PARTS[*]:-none}"

# Use first EFI and BOOT if found
EFI_PART="${EFI_PARTS[0]:-}"
BOOT_PART="${BOOT_PARTS[0]:-}"

if [ -z "$EFI_PART" ] || [ -z "$BOOT_PART" ]; then
    echo "ERROR: Could not find EFI or BOOT partition"
    echo "Please create partitions with labels: black_EFI and black_boot"
    exit 1
fi

# Discover PVs already in use
declare -a USED_PVS=()
while IFS= read -r PV; do
    [ -z "$PV" ] && continue
    PV_VG=$(pvs --noheadings -o vg_name "$PV" 2>/dev/null | tr -d ' ')
    USED_PVS+=("$PV")
done < <(pvs --noheadings -o pv_name 2>/dev/null)

echo "Found PVs already in use: ${USED_PVS[*]:-none}"

# Build list of available PV partitions
declare -a AVAILABLE_PVS=()
for PV in "${PV_PARTS[@]}"; do
    USED=0
    for UP in "${USED_PVS[@]}"; do
        [ "$PV" = "$UP" ] && USED=1 && break
    done
    [ "$USED" -eq 0 ] && AVAILABLE_PVS+=("$PV")
done

if [ "${#AVAILABLE_PVS[@]}" -eq 0 ]; then
    echo "No available PV partitions found."
    echo "Please create LVM partitions with type=linux (LVM)"
    exit 1
fi

echo "Available PV partitions: ${AVAILABLE_PVS[*]}"

# Activate LVM
echo "=== Activating LVM ==="
vgscan --mknodes >/dev/null 2>&1 || true
vgchange -ay >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
sleep 1

# Create black_pool VG
VG_NAME="black_pool"
if vgs "$VG_NAME" &>/dev/null; then
    echo "VG $VG_NAME already exists."
else
    echo "Creating VG $VG_NAME..."
    vgcreate "$VG_NAME" "${AVAILABLE_PVS[@]}" || fail "vgcreate failed"
fi

# Create thin pool
POOL_NAME="black_pool"
if ! lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
    echo "Creating thin pool..."
    lvcreate --type thin-pool -l 50%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" || fail "lvcreate thin-pool failed"
fi

# Create root LV
POOL_VOL_NAME="blacklogic"
if ! lvs "$VG_NAME/$POOL_VOL_NAME" &>/dev/null; then
    echo "Creating root LV..."
    lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n "$POOL_VOL_NAME" "$VG_NAME" || fail "lvcreate root LV failed"
    lvchange -ay "$VG_NAME/$POOL_VOL_NAME" 2>/dev/null || true
    mkfs.btrfs -f "/dev/$VG_NAME/$POOL_VOL_NAME" || fail "mkfs.btrfs failed"
fi

# Create surgery VG
SURGERY_VG="black_surgery"
if ! vgs "$SURGERY_VG" &>/dev/null; then
    # Look for surgery partitions
    declare -a SURGERY_PARTS=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        DEV=$(echo "$line" | awk '{print $1}')
        LABEL=$(echo "$line" | awk '{print $2}')
        [ "$LABEL" = "black_surgery" ] && SURGERY_PARTS+=("$DEV")
    done < <(blkid -o export 2>/dev/null | awk -F= '/DEVNAME=/{dev=$2} /LABEL=/{label=$2} /^$/{if(dev) print dev,label; dev="";label=""}')

    if [ "${#SURGERY_PARTS[@]}" -gt 0 ]; then
        echo "Creating surgery VG..."
        pvcreate -ff -y "${SURGERY_PARTS[@]}" 2>/dev/null || true
        vgcreate "$SURGERY_VG" "${SURGERY_PARTS[@]}" 2>/dev/null || true
        lvcreate -L 4G -n blacksurgery "$SURGERY_VG" 2>/dev/null || true
        mkfs.btrfs -f "/dev/$SURGERY_VG/blacksurgery" >/dev/null 2>&1 || true
    fi
fi

# Mount and setup
echo "=== Mounting and configuring ==="
mkdir -p "$MOUNT_DIR"
mount -o subvol=@,compress=zstd:3,noatime,discard=async,space_cache=v2 "/dev/$VG_NAME/$POOL_VOL_NAME" "$MOUNT_DIR" || { echo "Failed to mount root"; exit 1; }

mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/boot/efi"
mount "$BOOT_PART" "${MOUNT_DIR}/boot" || { echo "Failed to mount boot"; exit 1; }
mount "$EFI_PART" "${MOUNT_DIR}/boot/efi" || { echo "Failed to mount EFI"; exit 1; }

# Generate fstab
ROOT_UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/$POOL_VOL_NAME" 2>/dev/null || true)
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART" 2>/dev/null || true)
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)

cat > "${MOUNT_DIR}/etc/fstab" <<FSTAB
# /etc/fstab: static file system information
# Generated by BlackLogic Standalone Builder

# Root filesystem (Btrfs on LVM thin pool)
UUID=$ROOT_UUID  /  btrfs  rw,relatime,compress=zstd:3,space_cache=v2,subvol=@  0  0
FSTAB

[ -n "$BOOT_UUID" ] && echo "UUID=$BOOT_UUID  /boot  btrfs  rw,relatime  0  2" >> "${MOUNT_DIR}/etc/fstab"
[ -n "$EFI_UUID" ] && echo "UUID=$EFI_UUID  /boot/efi  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0  1" >> "${MOUNT_DIR}/etc/fstab"

# Bind mounts
for d in dev proc sys run; do
    mkdir -p "${MOUNT_DIR}/$d"
    mount --bind "/$d" "${MOUNT_DIR}/$d"
done

echo "=== Running install script ==="
"$SCRIPT_DIR/blacklogic-03-install.sh"

echo "=== Unmounting ==="
umount -R "$MOUNT_DIR" 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo "SUCCESS: BlackLogic build complete."
exit 0