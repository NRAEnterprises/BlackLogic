#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools parted wipefs pvcreate vgcreate vgextend lvcreate lvextend mkfs.fat mkfs.btrfs partprobe blkid lsblk jq blockdev udevadm smartctl mdadm fuser pkill systemctl modprobe swapon mkswap lvs vgs pvs mount umount findmnt wget tar zstd 2>/dev/null || true

VG_NAME="black_pool"
POOL_NAME="black_pool"
NEW_SIZE="64GiB"
CHUNK_SIZE="1G"
STATE_FILE="/tmp/blacklogic-state"
LOG_FILE="/var/log/blacklogic-format.log"
PROGRESS_FILE="/tmp/blacklogic-progress"
STARTING_POOL_GIB="64"
LOCK_FILE="/tmp/blacklogic-format.lock"
MAX_PART_WAIT="60"
EFI_PART_SAVED=0
FIRMWARE_DETECTED=0

mkdir -p /tmp
: > "$PROGRESS_FILE"
warn() { echo "WARNING: $*" >&2; }
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
fail() { echo "FATAL: $*" >&2; exit 1; }

# Prevent concurrent execution
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another format instance is running. Exiting."
    exit 1
fi

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

make_uuid() {
    local hex seed="$1"
    hex=$(printf '%s' "$seed" | sha256sum | cut -c1-32)
    printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

clear_foreign_signatures() {
    local dev="$1"
    mdadm --zero-superblock "$dev" 2>/dev/null || true
    zpool labelclear -f "$dev" 2>/dev/null || true
    dmraid -r -E "$dev" 2>/dev/null || true
    wipefs -a "$dev" 2>/dev/null || true
    dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync 2>/dev/null || true
    dd if=/dev/zero of="$dev" bs=1M seek=$(($(blockdev --getsz "$dev" 2>/dev/null || echo 0) / 2048 - 10)) count=10 conv=fsync 2>/dev/null || true
}

wait_for_partition() {
    local part="$1" max="$2" i=0
    while [ "$i" -lt "$max" ]; do
        [ -b "$part" ] && return 0
        udevadm settle 2>/dev/null || true
        partprobe "$(echo "$part" | sed 's/[0-9]*$//;s/p$//')" 2>/dev/null || true
        sleep 1
        i=$((i + 1))
    done
    return 1
}

disk_healthy() {
    local dev="$1"
    if command -v smartctl >/dev/null 2>&1; then
        smartctl -H "$dev" 2>/dev/null | grep -qi "PASSED" || return 1
    fi
    local sz
    sz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    [ "$sz" -ge 1073741824 ] || return 1
    return 0
}

detect_firmware() {
    log "Detecting firmware requirements..."

    # CPU microcode
    if [ -f /proc/cpuinfo ]; then
        if grep -q "GenuineIntel" /proc/cpuinfo; then
            echo "intel-ucode" >> "$STATE_FILE.firmware"
            FIRMWARE_DETECTED=1
        elif grep -q "AuthenticAMD" /proc/cpuinfo; then
            echo "amd-ucode" >> "$STATE_FILE.firmware"
            FIRMWARE_DETECTED=1
        fi
    fi

    # GPU detection
    if command -v lspci >/dev/null 2>&1; then
        if lspci | grep -qi "NVIDIA"; then
            echo "nvidia" >> "$STATE_FILE.firmware"
            echo "nvidia-utils" >> "$STATE_FILE.firmware"
            FIRMWARE_DETECTED=1
        fi
        if lspci | grep -qi "AMD/ATI\|Advanced Micro Devices.*VGA"; then
            echo "xf86-video-amdgpu" >> "$STATE_FILE.firmware"
            echo "mesa" >> "$STATE_FILE.firmware"
            echo "vulkan-radeon" >> "$STATE_FILE.firmware"
            FIRMWARE_DETECTED=1
        fi
        if lspci | grep -qi "Intel.*Graphics"; then
            echo "xf86-video-intel" >> "$STATE_FILE.firmware"
            echo "mesa" >> "$STATE_FILE.firmware"
            echo "vulkan-intel" >> "$STATE_FILE.firmware"
            FIRMWARE_DETECTED=1
        fi
    fi

    # Wireless firmware
    if command -v lspci >/dev/null 2>&1; then
        lspci | grep -qi "Intel.*Wireless\|iwlwifi" && echo "iwlwifi" >> "$STATE_FILE.firmware"
        lspci | grep -qi "Realtek.*Wireless" && echo "rtl8xxxu" >> "$STATE_FILE.firmware"
        lspci | grep -qi "Atheros.*Wireless" && echo "ath10k" >> "$STATE_FILE.firmware"
    fi

    # If nothing detected, fall back to bulk
    if [ "$FIRMWARE_DETECTED" -eq 0 ]; then
        echo "linux-firmware" >> "$STATE_FILE.firmware"
    fi

    # Always include base firmware
    grep -qx "linux-firmware" "$STATE_FILE.firmware" 2>/dev/null || echo "linux-firmware" >> "$STATE_FILE.firmware"

    # Remove duplicates
    if [ -f "$STATE_FILE.firmware" ]; then
        sort -u "$STATE_FILE.firmware" -o "$STATE_FILE.firmware"
        log "Firmware packages detected:"
        cat "$STATE_FILE.firmware" | sed 's/^/  /'
    fi
}

# Interactive drive selection
select_drives_to_format() {
    local -a ALL_DRIVES=()
    local -a EMPTY_DRIVES=()
    local -a DATA_DRIVES=()
    local -a SELECTED=()

    # Gather all eligible drives
    while IFS= read -r DEV_NAME; do
        [ -z "$DEV_NAME" ] && continue
        [[ "$DEV_NAME" == "$LIVE_DRIVE" ]] && continue
        local DEV="/dev/$DEV_NAME"
        local SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
        [ "$SIZE" -lt 1000000000 ] && continue

        # Check if drive has data
        local HAS_DATA=0
        if blkid -s TYPE "$DEV" &>/dev/null || lsblk -n -o FSTYPE "$DEV" 2>/dev/null | grep -q .; then
            HAS_DATA=1
        elif lsblk -n -o LABEL "$DEV" 2>/dev/null | grep -q .; then
            HAS_DATA=1
        elif lsblk -n -o PARTLABEL "$DEV" 2>/dev/null | grep -q .; then
            HAS_DATA=1
        fi

        local SIZE_HR=$(lsblk -bdno SIZE "$DEV" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "${SIZE}B")

        if [ "$HAS_DATA" -eq 1 ]; then
            DATA_DRIVES+=("$DEV_NAME|$SIZE_HR|has data")
        else
            EMPTY_DRIVES+=("$DEV_NAME|$SIZE_HR|empty")
        fi
    done < <(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name')

    # Auto-add empty drives to selection
    for entry in "${EMPTY_DRIVES[@]}"; do
        SELECTED+=("$entry")
    done

    # If there are data drives, ask about them
    if [ "${#DATA_DRIVES[@]}" -gt 0 ]; then
        echo "=== Drive Selection ==="
        echo "The following drives have data:"
        echo ""
        local i=1
        for entry in "${DATA_DRIVES[@]}"; do
            IFS='|' read -r DEV_NAME SIZE_HR STATUS <<< "$entry"
            echo "  $i) /dev/$DEV_NAME ($SIZE_HR) - $STATUS"
            i=$((i + 1))
        done
        echo ""
        echo "Enter the numbers of drives to format (space-separated, or 'none' to skip):"
        read -r -a INPUT_SEL < /dev/tty

        for sel in "${INPUT_SEL[@]}"; do
            if [ "$sel" = "none" ]; then
                break
            fi
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#DATA_DRIVES[@]}" ]; then
                SELECTED+=("${DATA_DRIVES[$((sel-1))]}")
            fi
        done
    fi

    # If no drives selected, exit
    if [ "${#SELECTED[@]}" -eq 0 ]; then
        echo "No drives selected for formatting."
        exit 0
    fi

    # Save selection
    printf '%s\n' "${SELECTED[@]}" > /tmp/blacklogic-selected-drives
}

echo "=== Stage 2: Drive Formatting ==="
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

LIVE_PART=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
LIVE_DRIVE=""
if [ -n "${LIVE_PART:-}" ]; then
    LIVE_DRIVE=$(lsblk -no PKNAME "$LIVE_PART" 2>/dev/null | head -n1 || true)
    [ -n "${LIVE_DRIVE:-}" ] || LIVE_DRIVE=$(basename "$LIVE_PART" 2>/dev/null | sed 's/[0-9]*$//' || true)
    [[ "$LIVE_DRIVE" == *p ]] && LIVE_DRIVE="${LIVE_DRIVE%p}"
fi
if [ -n "${LIVE_DRIVE:-}" ]; then
    echo "Live OS: /dev/$LIVE_DRIVE (BLINDED)"
else
    echo "Live OS: unknown"
fi

# Detect firmware
detect_firmware

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
            local DEV="/dev/$DEV_NAME"
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

        if [ "$NEED_FORMAT" -eq 0 ] && blkid -s TYPE -o value "/dev/$VG_NAME/blacklogic" 2>/dev/null | grep -q btrfs; then
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

# Select drives to format
select_drives_to_format

declare -a DRIVES=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r DEV_NAME SIZE_HR STATUS <<< "$line"
    DEV="/dev/$DEV_NAME"

    if is_drive_done "$DEV"; then
        echo "$DEV already recorded as formatted. Skipping."
        continue
    fi

    lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null | grep -q "/" && continue
    SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
    [ "$SIZE" -lt 1000000000 ] && continue

    disk_healthy "$DEV" || { echo "$DEV failed health check (non-fatal, continuing)."; }

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
done < /tmp/blacklogic-selected-drives

[ "${#DRIVES[@]}" -eq 0 ] && {
    if blkid -s TYPE -o value "/dev/$VG_NAME/blacklogic" 2>/dev/null | grep -q btrfs; then
        echo "No unclaimed drives to format."
        exit 0
    else
        echo "Root LV invalid; recreating..."
        lvchange -ay "$VG_NAME/blacklogic" 2>/dev/null || true
        if lvs "$VG_NAME/blacklogic" &>/dev/null; then lvremove -f "$VG_NAME/blacklogic" 2>/dev/null || true; fi
        if lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n "blacklogic" "$VG_NAME" 2>/dev/null; then
            lvchange -ay "$VG_NAME/blacklogic"
            if mkfs.btrfs -f "/dev/$VG_NAME/blacklogic"; then
                mkdir -p /tmp/blacklogic-mnt
                mount "/dev/$VG_NAME/blacklogic" /tmp/blacklogic-mnt && { btrfs subvolume create /tmp/blacklogic-mnt/@ 2>/dev/null || true; umount /tmp/blacklogic-mnt; }
            fi
        else
            echo "Thin pool failed; purging VG to rebuild from scratch."
            vgchange -an "$VG_NAME" 2>/dev/null || true
            for pv in $(pvs --noheadings -o pv_name -S "vg_name=$VG_NAME" 2>/dev/null); do pvremove -ff -y "$pv" 2>/dev/null || true; done
            vgremove -f "$VG_NAME" 2>/dev/null || true
        fi
        exit 0
    fi
}

SUCCESS=0
for D in "${DRIVES[@]}"; do
    IFS='|' read -r DEV CLASS <<< "$D"
    echo "Formatting unclaimed drive $DEV (class $CLASS)..."

    # Unmount any stale mounts on this device
    for mp in $(lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null); do
        [ -n "$mp" ] && [ "$mp" != "/" ] && umount -l "$mp" 2>/dev/null || true
    done
    swapoff "$DEV" 2>/dev/null || true
    for p in $(lsblk -n -o NAME "$DEV" 2>/dev/null); do
        [ -n "$p" ] && swapoff "/dev/$p" 2>/dev/null || true
    done

    fuser -k -9 "$DEV" 2>/dev/null || true
    for p in $(lsblk -n -o NAME "$DEV" 2>/dev/null); do fuser -k -9 "/dev/$p" 2>/dev/null || true; done
    for vg in black_pool black_surgery surgery_vg; do
        if vgs "$vg" &>/dev/null; then
            for pv in $(pvs --noheadings -o pv_name -S "vg_name=$vg" 2>/dev/null); do
                [ -z "$pv" ] && continue
                if [[ "$pv" == "$DEV"* ]]; then
                    vgchange -an "$vg" 2>/dev/null || true
                    vgremove -f "$vg" 2>/dev/null || true
                fi
            done
        fi
    done
    for p in $(lsblk -n -o NAME "$DEV" 2>/dev/null); do dmsetup remove "/dev/$p" 2>/dev/null || true; done
    for vg in black_pool black_surgery surgery_vg; do
        if vgs "$vg" &>/dev/null; then
            for pv in $(pvs --noheadings -o pv_name -S "vg_name=$vg" 2>/dev/null); do
                [ -z "$pv" ] && continue
                [[ "$pv" == "$DEV"* ]] && { vgchange -an "$vg" 2>/dev/null || true; vgremove -f "$vg" 2>/dev/null || true; break; }
            done
        fi
    done
    pvremove -ff -y "$DEV" 2>/dev/null || true
    for p in $(lsblk -n -o NAME "$DEV" 2>/dev/null); do pvremove -ff -y "/dev/$p" 2>/dev/null || true; done
    clear_foreign_signatures "$DEV"
    sleep 1
    partprobe "" 2>/dev/null || true
    blockdev --rereadpt "$DEV" 2>/dev/null || true

    if ! parted -s "$DEV" unit MiB mklabel gpt 2>/dev/null; then
        echo "parted mklabel failed on $DEV; retrying after signature clear."
        clear_foreign_signatures "$DEV"
        sleep 2
        parted -s "$DEV" unit MiB mklabel gpt 2>/dev/null || { echo "parted mklabel failed on $DEV; skipping."; continue; }
    fi
    sleep 1

    PS=""
    [[ "$DEV" == *nvme* ]] && PS="p"

    if [ "$CLASS" -eq 10 ]; then
        parted -s "$DEV" unit MiB mkpart black_pool 1MiB "${STARTING_POOL_GIB}MiB" >/dev/null 2>&1 || { echo "Failed creating pool partition on $DEV"; continue; }
        LVM_PART="${DEV}${PS}1"
    else
        parted -s "$DEV" unit MiB mkpart black_boot 1MiB 1025MiB >/dev/null 2>&1 || { echo "Failed creating boot partition on $DEV"; continue; }
        parted -s "$DEV" unit MiB mkpart black_EFI 1025MiB 1537MiB >/dev/null 2>&1 || { echo "Failed creating EFI partition on $DEV"; continue; }
        parted -s "$DEV" set 2 esp on 2>/dev/null || true
        parted -s "$DEV" unit MiB mkpart black_surgery 1537MiB 5121MiB >/dev/null 2>&1 || { echo "Failed creating surgery partition on $DEV"; continue; }
        HAS_SWAP=$(lsblk -n -o LABEL "$DEV" 2>/dev/null | grep -c "BLACK-SWAP" || true)
        if [ "$CLASS" -eq 100 ] && [ "$HAS_SWAP" -eq 0 ]; then
            parted -s "$DEV" unit MiB mkpart black_swap 5121MiB 13313MiB >/dev/null 2>&1 || { echo "Failed creating swap partition on $DEV"; continue; }
            mkswap -L "black_swap" "${DEV}${PS}4" >/dev/null 2>&1 || true
            parted -s "$DEV" unit MiB mkpart black_pool 13313MiB "$((13313 + STARTING_POOL_GIB * 1024))MiB" >/dev/null 2>&1 || { echo "Failed creating pool partition on $DEV"; continue; }
            LVM_PART="${DEV}${PS}5"
        else
            parted -s "$DEV" unit MiB mkpart black_pool 5121MiB "$((5121 + STARTING_POOL_GIB * 1024))MiB" >/dev/null 2>&1 || { echo "Failed creating pool partition on $DEV"; continue; }
            LVM_PART="${DEV}${PS}4"
        fi
        if ! mkfs.btrfs -L black_boot -f "${DEV}${PS}1" >/dev/null 2>&1; then
            echo "Failed to format boot partition on $DEV"
            continue
        fi
        if ! mkfs.fat -F32 -n "BLACK-EFI" "${DEV}${PS}2" >/dev/null 2>&1; then
            echo "Failed to format EFI partition on $DEV"
            continue
        fi
        if ! pvcreate -ff -y "${DEV}${PS}3" 2>/dev/null; then
            echo "Failed to create PV on surgery partition $DEV"
            continue
        fi
        if vgs black_surgery &>/dev/null; then
            vgextend black_surgery "${DEV}${PS}3" 2>/dev/null || true
        else
            vgcreate black_surgery "${DEV}${PS}3" 2>/dev/null || true
        fi
    fi

    if ! wait_for_partition "$LVM_PART" "$MAX_PART_WAIT"; then
        echo "Partition node missing: $LVM_PART"
        continue
    fi

    SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | head -n1 | tr -d ' ' || true)
    [ -z "$SERIAL" ] && SERIAL="$DEV_NAME"
    PV_UUID=$(make_uuid "${SERIAL}-${LVM_PART}")

    pv_ok=0
    if pvcreate -ff -y --uuid "$PV_UUID" "$LVM_PART" 2>/dev/null; then
        pv_ok=1
    else
        echo "pvcreate with UUID failed on $LVM_PART; retrying with random UUID."
        pvcreate -ff -y "$LVM_PART" 2>/dev/null && pv_ok=1
    fi
    [ "$pv_ok" -eq 0 ] && { echo "pvcreate failed on $LVM_PART"; continue; }

    # Label PV as black_driveN (lowest unassigned number starting at 0)
    DRIVE_NUM=0
    while pvs --noheadings -o pv_tags 2>/dev/null | tr ',' '
' | grep -qx "black_drive${DRIVE_NUM}"; do
        DRIVE_NUM=$((DRIVE_NUM + 1))
    done
    pvchange --addtag "black_drive${DRIVE_NUM}" "$LVM_PART" 2>/dev/null || true

    pvresize "$LVM_PART" 2>/dev/null || true

    if vgs "$VG_NAME" &>/dev/null; then
        vgs --noheadings -o pv_name "$VG_NAME" 2>/dev/null | grep -q "\[unknown\]" && vgreduce --removemissing --force "$VG_NAME" 2>/dev/null || true
        vgextend "$VG_NAME" "$LVM_PART" 2>/dev/null || { echo "vgextend failed for $LVM_PART"; continue; }
    else
        vgcreate "$VG_NAME" "$LVM_PART" 2>/dev/null || { echo "vgcreate failed for $LVM_PART"; continue; }
    fi
    sleep 1

    if ! lvs "$VG_NAME/$POOL_NAME" &>/dev/null; then
        lvcreate --type thin-pool -l 50%VG -c "$CHUNK_SIZE" -n "$POOL_NAME" "$VG_NAME" 2>/dev/null || { echo "lvcreate thin-pool failed"; continue; }
    fi

    lvchange -ay "$VG_NAME/blacklogic" 2>/dev/null || true
    if ! lvs "$VG_NAME/blacklogic" &>/dev/null || ! blkid -s TYPE -o value "/dev/$VG_NAME/blacklogic" 2>/dev/null | grep -q btrfs; then
        if lvs "$VG_NAME/blacklogic" &>/dev/null; then lvremove -f "$VG_NAME/blacklogic" 2>/dev/null || true; fi
        if ! lvcreate -V "$NEW_SIZE" --thinpool "$POOL_NAME" -n "blacklogic" "$VG_NAME" 2>/dev/null; then
            echo "lvcreate root LV failed on $DEV"
            continue
        fi
        lvchange -ay "$VG_NAME/blacklogic" 2>/dev/null || true
    fi

    if ! mkfs.btrfs -f "/dev/$VG_NAME/blacklogic"; then
        echo "mkfs.btrfs failed on $DEV"
        continue
    fi
    mkdir -p /tmp/blacklogic-mnt 2>/dev/null || true
    if ! mount "/dev/$VG_NAME/blacklogic" /tmp/blacklogic-mnt; then
        echo "Failed to mount root LV on $DEV"
        continue
    fi
    btrfs subvolume create /tmp/blacklogic-mnt/@ 2>/dev/null || true
    umount /tmp/blacklogic-mnt 2>/dev/null || true
    # Create blacksurgery LV in black_surgery VG
    if vgs black_surgery &>/dev/null && ! lvs black_surgery/blacksurgery &>/dev/null; then
        lvcreate -L 4G -n blacksurgery black_surgery 2>/dev/null || true
        mkfs.btrfs -f "/dev/black_surgery/blacksurgery" >/dev/null 2>&1 || true
    fi
    # Save boot and EFI partition paths for install stage (first drive with these partitions)
    if [ "$CLASS" -ne 10 ] && [ -z "${EFI_PART_SAVED:-}" ]; then
        EFI_PART="${DEV}${PS}2"
        BOOT_PART="${DEV}${PS}1"
        echo "EFI_PART=$EFI_PART" >> "$STATE_FILE"
        echo "BOOT_PART=$BOOT_PART" >> "$STATE_FILE"
        EFI_PART_SAVED=1
    fi
    record_drive_done "$DEV"
    echo "  $DEV -> blacklogic (pool partition: ${STARTING_POOL_GIB}GiB starting allocation)"
    SUCCESS=1
done

[ "$SUCCESS" -eq 0 ] && { echo "No drives formatted."; exit 1; }
echo "Format complete. Most drive space left unpartitioned for agent-driven expansion."
exit 0