#!/bin/bash
set -uo pipefail
VG_NAME="black_vg"
echo "=== FIXER: Drives ==="
pkill -f lvm 2>/dev/null || true
pkill -f dmsetup 2>/dev/null || true
sleep 1
vgchange -an "$VG_NAME" 2>/dev/null || true
sleep 1
dmsetup remove_all 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2
vgreduce --removemissing --force "$VG_NAME" 2>/dev/null || true
for dev in /dev/sd? /dev/nvme?n?; do
    [ ! -b "$dev" ] && continue
    if ! wipefs -n "$dev" &>/dev/null; then
        fuser -k "$dev" 2>/dev/null || true
        blockdev --flushbufs "$dev" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi
done
if vgs "$VG_NAME" &>/dev/null; then
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "black_pool" | grep -v "\[" | head -n1 | tr -d ' ' || true)
    if [ -z "$ROOT_LV" ] || [ ! -b "/dev/$VG_NAME/$ROOT_LV" ]; then
        vgchange -an "$VG_NAME" 2>/dev/null || true
        vgremove -f "$VG_NAME" 2>/dev/null || true
    fi
fi
rm -f /run/lvm/lock/*.lock /etc/lvm/cache/.cache 2>/dev/null || true
echo "Drive fixer complete."
exit 0
