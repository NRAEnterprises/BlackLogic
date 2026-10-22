#!/bin/bash
set -Eeuo pipefail

VG_NAME="black_vg"

echo "=== FIXER: Drives ==="
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root." >&2
    exit 1
fi

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
    BLACK_DRIVES=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep '^black_drive' || true)
    VALID_BLACK_DRIVES=""
    for lv in $BLACK_DRIVES; do
        [ -b "/dev/$VG_NAME/$lv" ] && VALID_BLACK_DRIVES+="${lv} "
    done
    if [ -z "${VALID_BLACK_DRIVES:-}" ]; then
        echo "No valid black_drive LVs remain; removing damaged VG metadata."
        vgchange -an "$VG_NAME" 2>/dev/null || true
        vgremove -f "$VG_NAME" 2>/dev/null || true
    else
        echo "Valid black_drive LVs remain: $VALID_BLACK_DRIVES"
    fi
fi

rm -f /run/lvm/lock/*.lock /etc/lvm/cache/.cache 2>/dev/null || true
echo "Drive fixer complete."
exit 0
