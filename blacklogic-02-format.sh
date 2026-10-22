#!/bin/bash
set -uo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
POOL_VOL_NAME="root"
STATE_FILE="/tmp/blacklogic-state"
INITIAL_POOL_GIB="64"
POOL_RESERVE_GIB="16"
EFI_SIZE_MIB="512"
BOOT_SIZE_MIB="1024"

log() { echo "[$(date +%H:%M:%S)] $*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}
for c in parted wipefs pvcreate vgcreate vgextend lvcreate lvextend mkfs.fat mkfs.btrfs partprobe blkid lsblk jq blockdev udevadm; do require_cmd "$c"; done

[ -f "$STATE_FILE" ] && source "$STATE_FILE"
export LIVE_DRIVE

LIVE_PART=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
LIVE_DRIVE=""
if [ -n "$LIVE_PART" ]; then
    LIVE_DRIVE=$(lsblk -no PKNAME "$LIVE_PART" 2>/dev/null | head -n1 || true)
    [ -z "$LIVE_DRIVE" ] && LIVE_DRIVE=$(basename "$LIVE_PART" | sed 's/[0-9]*$//' || true)
    [[ "$LIVE_DRIVE" == *p ]] && LIVE_DRIVE="${LIVE_DRIVE%p}"
fi
LIVE_DEV="/dev/$LIVE_DRIVE"
log "Live drive: ${LIVE_DEV:-none} (protected)"

pv_in_vg() {
    local dev="$1" pv vg
    while read -r pv vg; do
        [ "$vg" = "$VG_NAME" ] && [[ "$pv" == "$dev"* ]] && return 0
    done < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null)
    return 1
}

make_uuid() {
    local hex seed="$1"
    hex=$(printf '%s' "$seed" | sha256sum | cut -c1-32)
    printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

target_disks() {
    lsblk -J -b -o NAME,TYPE,SIZE 2>/dev/null | jq -r --arg live "$LIVE_DRIVE" '
        .blockdevices[]?
        | select(.type=="disk")
        | select(.name != $live)
        | select(.name|startswith("zram")|not)
        | select(.name|startswith("loop")|not)
        | .name
    ' 2>/dev/null
}

first_target() {
    local d dev size
    for d in $(target_disks); do
        dev="/dev/$d"
        lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q "/" && continue
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [ "$size" -lt 1073741824 ] && continue
        pv_in_vg "$dev" && continue
        echo "$dev"
        return 0
    done
    return 1
}

echo "=== Stage 2: Drive Formatting ==="

PRIMARY_DEV=$(first_target) || { echo "No target drive available."; exit 1; }
log "Primary drive: $PRIMARY_DEV"

[[ "$PRIMARY_DEV" == *nvme* ]] && PS="p" || PS=""

if vgs "$VG_NAME" &>/dev/null && lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
    vgchange -ay "$VG_NAME" 2>/dev/null || true
    lvextend -l +100%FREE "$VG_NAME/$POOL_NAME" 2>/dev/null || true
    log "Existing pool verified: $VG_NAME/$POOL_NAME"
    exit 0
fi

wipefs -a "$PRIMARY_DEV" 2>/dev/null || true
parted -s "$PRIMARY_DEV" mklabel gpt || { echo "Failed to create GPT on $PRIMARY_DEV"; exit 1; }

EFI_END=$(awk -v s=1 -v e="$EFI_SIZE_MIB" 'BEGIN{printf "%dMiB", s+e}')
BOOT_START="$EFI_END"
BOOT_END=$(awk -v s="$BOOT_START" -v e="$BOOT_SIZE_MIB" 'BEGIN{printf "%dMiB", s+e}')
POOL_START="$BOOT_END"
POOL_END=$(awk -v s="$POOL_START" -v g="$INITIAL_POOL_GIB" 'BEGIN{printf "%dMiB", s+g*1024}')

parted -s "$PRIMARY_DEV" mkpart primary fat32 "1MiB" "$EFI_END" || { echo "EFI partition failed"; exit 1; }
parted -s "$PRIMARY_DEV" set 1 esp on || true
parted -s "$PRIMARY_DEV" mkpart primary btrfs "$BOOT_START" "$BOOT_END" || { echo "Boot partition failed"; exit 1; }
parted -s "$PRIMARY_DEV" mkpart primary "$POOL_START" "$POOL_END" || { echo "Pool partition failed"; exit 1; }

partprobe "$PRIMARY_DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

EFI_PART="${PRIMARY_DEV}${PS}1"
BOOT_PART="${PRIMARY_DEV}${PS}2"
POOL_PART="${PRIMARY_DEV}${PS}3"

for i in $(seq 1 30); do [ -b "$POOL_PART" ] && break; sleep 1; done
[ -b "$POOL_PART" ] || { echo "Pool partition node missing: $POOL_PART"; exit 1; }

mkfs.fat -F32 -n "BLACK-EFI" "$EFI_PART" || { echo "EFI mkfs failed"; exit 1; }
mkfs.btrfs -L black-boot -f "$BOOT_PART" >/dev/null 2>&1 || { echo "Boot mkfs failed"; exit 1; }

SEED=$(lsblk -no SERIAL "$(basename "$PRIMARY_DEV")" 2>/dev/null | head -n1 | tr -d ' ')
[ -z "$SEED" ] && SEED="$PRIMARY_DEV"
PV_UUID=$(make_uuid "${SEED}-${POOL_PART}")
pvcreate --uuid "$PV_UUID" -y "$POOL_PART" || { echo "pvcreate failed"; exit 1; }

if vgs "$VG_NAME" &>/dev/null; then
    vgextend "$VG_NAME" "$POOL_PART" || { echo "vgextend failed"; exit 1; }
else
    vgcreate "$VG_NAME" "$POOL_PART" || { echo "vgcreate failed"; exit 1; }
fi

if ! lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
    VG_FREE=$(vgs --noheadings -o vg_free "$VG_NAME" 2>/dev/null | tr -dc '0-9.' | head -c 8)
    POOL_SIZE=$(awk -v f="$VG_FREE" -v r="$POOL_RESERVE_GIB" 'BEGIN{printf "%.0f", (f>r? f-r : f/2)}')
    [ -z "$POOL_SIZE" ] || [ "$POOL_SIZE" -lt 8 ] && POOL_SIZE=8
    lvcreate --type thin-pool -L "${POOL_SIZE}G" -c 1G -n "$POOL_NAME" "$VG_NAME" || { echo "Thin pool create failed"; exit 1; }
else
    log "Thin pool already exists."
fi

if ! lvs "$VG_NAME/$POOL_VOL_NAME" &>/dev/null; then
    lvcreate -V 200G --thinpool "$POOL_NAME" -n "$POOL_VOL_NAME" "$VG_NAME" || { echo "Root LV create failed"; exit 1; }
    mkfs.btrfs -f "/dev/$VG_NAME/$POOL_VOL_NAME" >/dev/null 2>&1 || { echo "Root mkfs failed"; exit 1; }
else
    log "Root LV already exists."
fi

cat > "$STATE_FILE" <<EOF
LIVE_DRIVE=$LIVE_DRIVE
PRIMARY_DEV=$PRIMARY_DEV
EFI_PART=$EFI_PART
BOOT_PART=$BOOT_PART
POOL_PART=$POOL_PART
VG_NAME=$VG_NAME
POOL_NAME=$POOL_NAME
POOL_VOL_NAME=$POOL_VOL_NAME
EOF

log "Format complete. Pool physical: ~$((INITIAL_POOL_GIB - POOL_RESERVE_GIB))GiB on $PRIMARY_DEV."
log "Remaining drive space left unpartitioned for agent-driven expansion."
exit 0
EOF
echo "written"; md5sum blacklogic-02-format.sh