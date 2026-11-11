#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools wipefs parted fuser blockdev pvcreate vgcreate vgextend lvcreate lvs vgs pvs pvremove dmsetup partprobe mdadm zpool dmraid 2>/dev/null || true

VG_NAME="black_pool"
echo "=== FIXER: Drives ==="

# Kill any processes holding block devices
for dev in /dev/sd* /dev/nvme* /dev/hd*; do
    [ -b "$dev" ] && fuser -k -9 "$dev" 2>/dev/null || true
done
sleep 1

# Deactivate and remove ALL relevant VGs
for vg in "$VG_NAME" black_surgery surgery_vg; do
    if vgs "$vg" &>/dev/null; then
        vgchange -an "$vg" 2>/dev/null || true
        sleep 1
        vgremove -f "$vg" 2>/dev/null || true
        for dm in $(dmsetup ls 2>/dev/null | grep -i "$vg" | cut -f1); do
            [ -n "$dm" ] && dmsetup remove "$dm" 2>/dev/null || true
        done
    fi
done
sleep 1

# Clear foreign signatures on all non-live drives
LIVE_PART=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
LIVE_DRIVE=""
if [ -n "${LIVE_PART:-}" ]; then
    LIVE_DRIVE=$(lsblk -no PKNAME "$LIVE_PART" 2>/dev/null | head -n1 || true)
    [ -n "${LIVE_DRIVE:-}" ] || LIVE_DRIVE=$(basename "$LIVE_PART" 2>/dev/null | sed 's/[0-9]*$//' || true)
fi

for dev in /dev/sd* /dev/nvme* /dev/hd*; do
    [ -b "$dev" ] || continue
    DEV_NAME=$(basename "$dev")
    [[ "$DEV_NAME" == "$LIVE_DRIVE" ]] && continue
    lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q "/" && continue
    echo "Clearing signatures on $dev..."

    # Unmount any stale mounts
    for mp in $(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null); do
        [ -n "$mp" ] && [ "$mp" != "/" ] && umount -l "$mp" 2>/dev/null || true
    done
    swapoff "$dev" 2>/dev/null || true
    for p in $(lsblk -n -o NAME "$dev" 2>/dev/null); do
        [ -n "$p" ] && swapoff "/dev/$p" 2>/dev/null || true
    done

    fuser -k -9 "$dev" 2>/dev/null || true
    for p in $(lsblk -n -o NAME "$dev" 2>/dev/null); do
        fuser -k -9 "/dev/$p" 2>/dev/null || true
    done

    for p in $(lsblk -n -o NAME "$dev" 2>/dev/null); do
        [ -n "$p" ] && dmsetup remove "/dev/$p" 2>/dev/null || true
    done
    pvremove -ff -y "$dev" 2>/dev/null || true
    for p in $(lsblk -n -o NAME "$dev" 2>/dev/null); do
        [ -n "$p" ] && pvremove -ff -y "/dev/$p" 2>/dev/null || true
    done
    mdadm --zero-superblock "$dev" 2>/dev/null || true
    zpool labelclear -f "$dev" 2>/dev/null || true
    dmraid -r -E "$dev" 2>/dev/null || true
    wipefs -a "$dev" 2>/dev/null || true
    dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync 2>/dev/null || true
    dd if=/dev/zero of="$dev" bs=1M seek=$(($(blockdev --getsz "$dev" 2>/dev/null || echo 0) / 2048 - 10)) count=10 conv=fsync 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    blockdev --rereadpt "$dev" 2>/dev/null || true
done

# Clean LVM cache
rm -f /run/lvm/lock/*.lock /etc/lvm/cache/.cache 2>/dev/null || true
udevadm settle 2>/dev/null || true

echo "Drive fixer complete. Ready for re-format."
exit 0