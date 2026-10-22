#!/bin/bash
set -Eeuo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
NEW_SIZE="4.00GiB"
CHUNK_SIZE="1G"
STATE_FILE="/tmp/blacklogic-state"
PROGRESS_FILE="/tmp/blacklogic-progress"

mkdir -p /tmp
: > "$PROGRESS_FILE"

record_drive_done() {
    local d="$1"
    [ -n "$d" ] || return 0
    grep -qxF "$d" "$PROGRESS_FILE" 2>/dev/null || echo "$d" >> "$PROGRESS_FILE"
    sort -u "$PROGRESS_FILE" -o "$PROGRESS_FILE"
}

is_drive_done() {
    local d="$1"
    grep -qxF "$d" "$PROGRESS_FILE" 2>/dev/null
}

echo "=== Stage 2: Drive Formatting ==="
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

LIVE_PART=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
LIVE_DRIVE=""
if [ -n "${LIVE_PART:-}" ]; then
    LIVE_DRIVE=$(lsblk -no PKNAME "$LIVE_PART" 2>/dev/null | head -n1 || true)
    [ -n "${LIVE_DRIVE:-}" ] || LIVE_DRIVE=$(basename "$LIVE_PART" 2>/dev/null | sed 's/[0-9]*$//' || true)
fi
if [ -n "${LIVE_DRIVE:-}" ]; then
    echo "Live OS: /dev/$LIVE_DRIVE (BLINDED)"
else
    echo "Live OS: unknown"
fi

if vgs "$VG_NAME" &>/dev/null; then
    vgchange -ay "$VG_NAME" &>/dev/null || true
    sleep 1
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)

    if [ -n "${ROOT_LV:-}" ] && [ -b "/dev/$VG_NAME/$ROOT_LV" ]; then
        echo "Existing pool found: /dev/$VG_NAME/$ROOT_LV"
        echo "Scanning for unclaimed drives..."
        NEED_FORMAT=0
        while IFS= read -r DEV_NAME; do
            [ -z "$DEV_NAME" ] && continue
            [[ "$DEV_NAME" == "$LIVE_DRIVE" ]] && continue
            DEV="/dev/$DEV_NAME"
            lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null | grep -q "/" && continue

            IN_VG=0
            while IFS= read -r PV; do
                [ -z "$PV" ] && continue
                if [[ "$PV" == "$DEV"* ]]; then
                    PV_VG=$(pvs --noheadings -o vg_name "$PV" 2>/dev/null | tr -d ' ' || true)
                    [[ "${PV_VG:-}" == "$VG_NAME" ]] && IN_VG=1
                fi
            done < <(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ')

            if [ "$IN_VG" -eq 0 ]; then
                echo "Unclaimed drive detected: $DEV"
                NEED_FORMAT=1
            fi
        done < <(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name')

        if [ "$NEED_FORMAT" -eq 0 ]; then
            echo "Pool is COMPLETE. All physical drives are in $VG_NAME."
            exit 0
        fi
        echo "Missing drives detected. Proceeding to format them."
    else
        echo "Pool exists but root LV is invalid. Purging metadata."
        vgchange -an "$VG_NAME" 2>/dev/null || true
        vgremove -f "$VG_NAME" 2>/dev/null || true
    fi
fi

declare -a DRIVES=()
while IFS= read -r DEV_NAME; do
    [ -z "$DEV_NAME" ] && continue
    [[ "$DEV_NAME" == "$LIVE_DRIVE" ]] && continue
    DEV="/dev/$DEV_NAME"

    if is_drive_done "$DEV"; then
        echo "$DEV already recorded as formatted. Skipping."
        continue
    fi

    lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null | grep -q "/" && continue
    SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
    [ "$SIZE" -lt 1000000000 ] && continue

    IN_VG=0
    while IFS= read -r PV; do
        [ -z "$PV" ] && continue
        if [[ "$PV" == "$DEV"* ]]; then
            PV_VG=$(pvs --noheadings -o vg_name "$PV" 2>/dev/null | tr -d ' ' || true)
            [[ "${PV_VG:-}" == "$VG_NAME" ]] && IN_VG=1
        fi
    done < <(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ')
    [ "$IN_VG" -eq 1 ] && { echo "$DEV already in VG. Skipping."; continue; }

    TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null || echo "unknown")
    ROTA=$(lsblk -dno ROTA "$DEV" 2>/dev/null || echo "1")
    if [[ "$DEV_NAME" == nvme* ]]; then
        CLASS=100
    elif [ "$TRAN" = "usb" ] || [ "$ROTA" = "0" ]; then
        CLASS=50
    else
        CLASS=10
    fi
    DRIVES+=("$DEV|$CLASS")
done < <(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name')

[ "${#DRIVES[@]}" -eq 0 ] && { echo "No unclaimed drives to format."; exit 0; }

SUCCESS=0
for D in "${DRIVES[@]}"; do
    IFS='|' read -r DEV CLASS <<< "$D"
    echo "Formatting unclaimed drive $DEV (class $CLASS)..."

    wipefs -a "$DEV" 2>/dev/null || { echo "wipefs failed on $DEV; skipping."; continue; }
    sleep 1

    parted -s "$DEV" unit MiB mklabel gpt 2>/dev/null || { echo "parted mklabel failed on $DEV; skipping."; continue; }
    sleep 1

    PS=""
    [[ "$DEV" == *nvme* ]] && PS="p"

    if [ "$CLASS" -eq 10 ]; then
        parted -s "$DEV" unit MiB mkpart black-pool 1MiB 100% >/dev/null 2>&1 || { echo "Failed creating pool partition on $DEV"; continue; }
        LVM_PART="${DEV}${PS}1"
    else
        parted -s "$DEV" unit MiB mkpart black-boot 1MiB 1025MiB >/dev/null 2>&1 || { echo "Failed creating boot partition on $DEV"; continue; }
        parted -s "$DEV" unit MiB mkpart black-efi 1025MiB 3073MiB >/dev/null 2>&1 || { echo "Failed creating EFI partition on $DEV"; continue; }
        parted -s "$DEV" set 2 esp on 2>/dev/null || true
        parted -s "$DEV" unit MiB mkpart black-surgery 3073MiB 6657MiB >/dev/null 2>&1 || { echo "Failed creating surgery partition on $DEV"; continue; }
        HAS_SWAP=$(lsblk -n -o LABEL "$DEV" 2>/dev/null | grep -c "BLACK-SWAP" || true)
        if [ "$CLASS" -eq 100 ] && [ "$HAS_SWAP" -eq 0 ]; then
            parted -s "$DEV" unit MiB mkpart black-swap 6657MiB 14849MiB >/dev/null 2>&1 || { echo "Failed creating swap partition on $DEV"; continue; }
            mkswap -L "BLACK-SWAP" "${DEV}${PS}4" >/dev/null 2>&1 || true
            parted -s "$DEV" unit MiB mkpart black-pool 14849MiB 100% >/dev/null 2>&1 || { echo "Failed creating pool partition on $DEV"; continue; }
            LVM_PART="${DEV}${PS}5"
        else
            parted -s "$DEV" unit MiB mkpart black-pool 6657MiB 100% >/dev/null 2>&1 || { echo "Failed creating pool partition on $DEV"; continue; }
            LVM_PART="${DEV}${PS}4"
        fi
        mkfs.btrfs -L black-boot -f "${DEV}${PS}1" >/dev/null 2>&1 || true
        mkfs.fat -F32 -n "BLACK-EFI" "${DEV}${PS}2" >/dev/null 2>&1 || true
        mkfs.btrfs -L black-surgery -f "${DEV}${PS}3" >/dev/null 2>&1 || true
    fi

    partprobe "$DEV" 2>/dev/null || true
    for i in $(seq 1 20); do [ -b "$LVM_PART" ] && break; sleep 1; done
    [ ! -b "$LVM_PART" ] && { echo "Partition node missing."; continue; }

    SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | head -n1 | tr -d ' ' || true)
    [ -z "$SERIAL" ] && SERIAL="$DEV_NAME"
    FAKE_UUID=$(printf '%s-%s' "$SERIAL" "$LVM_PART" | sha256sum | cut -c1-32 | fold -w6 | head -n6 | tr '\n' '-' | sed 's/-$//')

    if ! pvcreate -ff -y --uuid "$FAKE_UUID" "$LVM_PART" 2>/dev/null; then
        echo "pvcreate failed on $LVM_PART; retrying without explicit UUID."
        pvcreate -ff -y "$LVM_PART" 2>/dev/null || { echo "pvcreate failed on $LVM_PART"; continue; }
    fi

    pvresize "$LVM_PART" 2>/dev/null || true

    if vgs "$VG_NAME" &>/dev/null; then
        vgs --noheadings -o pv_name "$VG_NAME" 2>/dev/null | grep -q "\[unknown\]" && vgreduce --removemissing --force "$VG_NAME" 2>/dev/null || true
        vgextend "$VG_NAME" "$LVM_PART" 2>/dev/null || { echo "vgextend failed for $LVM_PART"; continue; }
    else
        vgcreate "$VG_NAME" "$LVM_PART" 2>/dev/null || { echo "vgcreate failed for $LVM_PART"; continue; }
    fi
    sleep 1

    if ! lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
        lvcreate --type thin-pool -l 10%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" 2>/dev/null || { echo "lvcreate thin-pool failed"; continue; }
    fi

    NEXT=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -c "black_drive" || true)
    if ! lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n "black_drive$NEXT" "$VG_NAME" 2>/dev/null; then
        echo "lvcreate root LV failed on $DEV"
        continue
    fi

    mkfs.btrfs -f "/dev/$VG_NAME/black_drive$NEXT" >/dev/null 2>&1 || true
    record_drive_done "$DEV"
    echo "  $DEV -> black_drive$NEXT"
    SUCCESS=1
done

[ "$SUCCESS" -eq 0 ] && { echo "No drives formatted."; exit 1; }
echo "Format complete."
exit 0
