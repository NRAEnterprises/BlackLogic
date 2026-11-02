#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools wipefs parted fuser blockdev pvcreate vgcreate vgextend lvcreate lvs vgs pvs 2>/dev/null || true

VG_NAME="black_vg"
echo "=== FIXER: Drives ==="

# Kill any processes holding block devices
for dev in /dev/sd* /dev/nvme* /dev/hd*; do
    [ -b "$dev" ] && fuser -k -9 "$dev" 2>/dev/null || true
done
sleep 1

# Deactivate VG if active
if vgs "$VG_NAME" &>/dev/null; then
    vgchange -an "$VG_NAME" 2>/dev/null || true
    sleep 1
fi

# Remove VG metadata if no valid root LV remains
if vgs "$VG_NAME" &>/dev/null; then
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "black_pool" | grep -v "\[" | head -n1 | tr -d ' ' || true)
    if [ -z "$ROOT_LV" ] || [ ! -b "/dev/$VG_NAME/$ROOT_LV" ]; then
        echo "No valid root LV. Purging VG metadata."
        vgremove -f "$VG_NAME" 2>/dev/null || true
    fi
fi

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
    mdadm --zero-superblock "$dev" 2>/dev/null || true
    wipefs -a "$dev" 2>/dev/null || true
    dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync 2>/dev/null || true
done

# Clean LVM cache
rm -f /run/lvm/lock/*.lock /etc/lvm/cache/.cache 2>/dev/null || true
udevadm settle 2>/dev/null || true

echo "Drive fixer complete. Ready for re-format."
exit 0
