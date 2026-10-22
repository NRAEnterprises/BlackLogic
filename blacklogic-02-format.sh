#!/bin/bash
set -uo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
NEW_SIZE="15.00PiB"
CHUNK_SIZE="1G"
STATE_FILE="/tmp/blacklogic-state"

echo "=== Stage 2: Drive Formatting ==="

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

LIVE_PART=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
LIVE_DRIVE=$(lsblk -no PKNAME "$LIVE_PART" 2>/dev/null | head -n1 || true)
[ -z "$LIVE_DRIVE" ] && LIVE_DRIVE=$(basename "$LIVE_PART" 2>/dev/null | sed 's/[0-9]*$//' || true)
echo "Live OS: /dev/$LIVE_DRIVE (BLINDED)"

# =========================================================
# STEP 1: Check existing pool state — DO NOT destroy
# =========================================================
if vgs "$VG_NAME" &>/dev/null; then
    vgchange -ay "$VG_NAME" &>/dev/null || true
    sleep 1
    ROOT_LV=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -v "$POOL_NAME" | grep -v "\[" | head -n1 | tr -d ' ' || true)
    
    if [ -n "$ROOT_LV" ] && [ -b "/dev/$VG_NAME/$ROOT_LV" ]; then
        echo "Existing pool found: /dev/$VG_NAME/$ROOT_LV"
        
        # STEP 2: Try non-destructive expansion first
        VG_FREE=$(vgs --noheadings -o vg_free_count "$VG_NAME" 2>/dev/null | tr -d ' ' || echo "0")
        if [ "$VG_FREE" -gt 10 ]; then
            echo "VG has $VG_FREE free extents. Extending pool non-destructively."
            lvextend -l +100%FREE "$VG_NAME/$POOL_NAME" 2>/dev/null || true
            sleep 1
        fi

        # STEP 3: Scan for physical drives not yet in the VG
        echo "Scanning for unclaimed drives..."
        NEED_FORMAT=0
        for DEV_NAME in $(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name'); do
            [[ "$DEV_NAME" == "$LIVE_DRIVE" ]] && continue
            DEV="/dev/$DEV_NAME"
            lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null | grep -q "/" && continue

            # Check if this drive is already in the VG
            IN_VG=0
            for PV in $(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' '); do
                if [[ "$PV" == "$DEV"* ]]; then
                    PV_VG=$(pvs --noheadings -o vg_name "$PV" 2>/dev/null | tr -d ' ')
                    [[ "$PV_VG" == "$VG_NAME" ]] && IN_VG=1
                fi
            done

            if [ "$IN_VG" -eq 0 ]; then
                echo "Unclaimed drive detected: $DEV"
                NEED_FORMAT=1
            fi
        done

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

# =========================================================
# STEP 4: Format only drives that aren't already in a VG
# =========================================================
declare -a DRIVES=()
for DEV_NAME in $(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name'); do
    [[ "$DEV_NAME" == "$LIVE_DRIVE" ]] && continue
    DEV="/dev/$DEV_NAME"
    lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null | grep -q "/" && continue
    SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
    [ "$SIZE" -lt 1000000000 ] && continue

    # Check if already in VG — if so, skip (non-destructive)
    IN_VG=0
    for PV in $(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' '); do
        if [[ "$PV" == "$DEV"* ]]; then
            PV_VG=$(pvs --noheadings -o vg_name "$PV" 2>/dev/null | tr -d ' ')
            [[ "$PV_VG" == "$VG_NAME" ]] && IN_VG=1
        fi
    done
    [ "$IN_VG" -eq 1 ] && { echo "$DEV already in VG. Skipping."; continue; }

    TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null || echo "unknown")
    ROTA=$(lsblk -dno ROTA "$DEV" 2>/dev/null || echo "1")
    [[ "$DEV_NAME" == nvme* ]] && CLASS=100 || { [ "$TRAN" == "usb" -o "$ROTA" == "0" ] && CLASS=50 || CLASS=10; }
    DRIVES+=("$DEV|$CLASS")
done

[ ${#DRIVES[@]} -eq 0 ] && { echo "No unclaimed drives to format."; exit 0; }

SUCCESS=0
for D in "${DRIVES[@]}"; do
    IFS='|' read -r DEV CLASS <<< "$D"
    echo "Formatting unclaimed drive $DEV (class $CLASS)..."
    wipefs -a "$DEV" 2>/dev/null || continue
    sleep 1
    parted -s "$DEV" mklabel gpt 2>/dev/null || continue
    sleep 1
    PS=""; [[ "$DEV" == *nvme* ]] && PS="p"
    if [ "$CLASS" -eq 10 ]; then
        parted -s "$DEV" mkpart black-pool 1MiB 100% || continue
        LVM_PART="${DEV}${PS}1"
    else
        parted -s "$DEV" mkpart black-boot 1MiB 1025MiB || continue
        parted -s "$DEV" mkpart black-efi 1025MiB 3073MiB || continue
        parted -s "$DEV" set 2 esp on 2>/dev/null || true
        parted -s "$DEV" mkpart black-surgery 3073MiB 6657MiB || continue
        HAS_SWAP=$(lsblk -n -o LABEL "$DEV" 2>/dev/null | grep -c "BLACK-SWAP" || true)
        if [ "$CLASS" -eq 100 ] && [ "$HAS_SWAP" -eq 0 ]; then
            parted -s "$DEV" mkpart black-swap 6657MiB 14849MiB || continue
            mkswap -L "BLACK-SWAP" "${DEV}${PS}4" >/dev/null 2>&1 || true
            parted -s "$DEV" mkpart black-pool 14849MiB 100% || continue
            LVM_PART="${DEV}${PS}5"
        else
            parted -s "$DEV" mkpart black-pool 6657MiB 100% || continue
            LVM_PART="${DEV}${PS}4"
        fi
        mkfs.btrfs -L black-boot -f "${DEV}${PS}1" >/dev/null 2>&1 || true
        mkfs.fat -F32 -n "BLACK-EFI" "${DEV}${PS}2" >/dev/null 2>&1 || true
        mkfs.btrfs -L black-surgery -f "${DEV}${PS}3" >/dev/null 2>&1 || true
    fi
    partprobe "$DEV" 2>/dev/null || true
    for i in $(seq 1 20); do [ -b "$LVM_PART" ] && break; sleep 1; done
    [ ! -b "$LVM_PART" ] && { echo "Partition node missing."; continue; }

    # Deterministic UUID so duplicates never happen
    SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | head -n1 | tr -d ' ')
    [ -z "$SERIAL" ] && SERIAL="$DEV_NAME"
    FAKE_UUID=$(echo "${SERIAL}-${LVM_PART}" | sha256sum | cut -c1-32 | fold -w6 | head -n6 | tr '\n' '-' | sed 's/-$//')
    pvcreate -ff -y --uuid "${FAKE_UUID}" "$LVM_PART" 2>/dev/null || pvcreate -ff -y "$LVM_PART" 2>/dev/null || continue

    if vgs "$VG_NAME" &>/dev/null; then
        vgs --noheadings -o pv_name "$VG_NAME" 2>/dev/null | grep -q "\[unknown\]" && vgreduce --removemissing --force "$VG_NAME" 2>/dev/null || true
        vgextend "$VG_NAME" "$LVM_PART" 2>/dev/null || continue
    else
        vgcreate "$VG_NAME" "$LVM_PART" 2>/dev/null || continue
    fi
    sleep 1

    if ! lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
        lvcreate --type thin-pool -l 10%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" 2>/dev/null || continue
    else
        lvextend -l +100%FREE "$VG_NAME/$POOL_NAME" 2>/dev/null || true
    fi
    NEXT=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -c "black_drive" || true)
    lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n "black_drive$NEXT" "$VG_NAME" 2>/dev/null || continue
    mkfs.btrfs -f "/dev/$VG_NAME/black_drive$NEXT" >/dev/null 2>&1 || true
    echo "  $DEV -> black_drive$NEXT"
    SUCCESS=1
done

[ "$SUCCESS" -eq 0 ] && { echo "No drives formatted."; exit 1; }
echo "Format complete."
exit 0
