#!/bin/bash
set -uo pipefail

VG_NAME="black_vg"
POOL_NAME="black_pool"
POOL_VOL_NAME="root"
MOUNT_DIR="/mnt/blackarch"
STATE_FILE="/tmp/blacklogic-state"
LOG_FILE="/var/log/blacklogic-pool-agent.log"
THRESHOLD="${POOL_AGENT_THRESHOLD:-70}"
EXTEND_STEP_GIB="${POOL_AGENT_STEP:-32}"

log() { echo "[$(date +%F_%T)] $*" | tee -a "$LOG_FILE"; }

[ -f "$STATE_FILE" ] && source "$STATE_FILE"
export LIVE_DRIVE

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
for c in lvs vgs lvcreate lvextend pvcreate vgextend parted partprobe blockdev lsblk wipefs jq btrfs df udevadm; do require_cmd "$c"; done

[ -b "/dev/$VG_NAME/$POOL_NAME" ] || { log "Thin pool not found, nothing to manage."; exit 0; }

[ -z "${PRIMARY_DEV:-}" ] && PRIMARY_DEV=$(pvs --noheadings -o pv_name -S "vg_name=$VG_NAME" 2>/dev/null | head -n1 | tr -d ' ')

free_space_bytes() {
    local dev="$1" total last_end
    total=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    last_end=$(parted -s "$dev" unit B print 2>/dev/null | awk '/^[[:space:]]*[0-9]+/{end=$3} END{gsub(/[^0-9]/,"",end); print end+0}')
    last_end=${last_end:-0}
    echo $((total - last_end))
}

extend_pool_from() {
    local dev="$1" free_bytes need start_b end_b ps next_num np i
    free_bytes=$(free_space_bytes "$dev")
    need=$((EXTEND_STEP_GIB * 1024 * 1024 * 1024))
    [ "$free_bytes" -gt "$need" ] || return 1
    read -r _ start_b < <(parted -s "$dev" unit B print 2>/dev/null | awk '/^[[:space:]]*[0-9]+/{print $2,$3; end=$3} END{print ""}' | tail -n1)
    start_b=${start_b:-0}
    [ "$start_b" -eq 0 ] && start_b=2048
    end_b=$((start_b + need))
    [[ "$dev" == *nvme* ]] && ps="p" || ps=""
    next_num=$(lsblk -n -o NAME "$dev" 2>/dev/null | grep -cE '[0-9]$' || echo 0)
    next_num=$((next_num + 1))
    np="${dev}${ps}${next_num}"
    parted -s "$dev" mkpart primary "pool-ext" "${start_b}B" "${end_b}B" || return 1
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    for i in $(seq 1 20); do [ -b "$np" ] && break; sleep 1; done
    [ -b "$np" ] || return 1
    wipefs -a "$np" 2>/dev/null || true
    pvcreate -y "$np" 2>/dev/null || return 1
    vgextend "$VG_NAME" "$np" 2>/dev/null || return 1
    lvextend -L +"${EXTEND_STEP_GIB}G" "/dev/$VG_NAME/$POOL_NAME" 2>/dev/null || return 1
    log "Extended pool by ${EXTEND_STEP_GIB}GiB using $np"
    return 0
}

read -r data_pct meta_pct < <(lvs --noheadings -o data_percent,metadata_percent "/dev/$VG_NAME/$POOL_NAME" 2>/dev/null | awk '{gsub(/%/,"",$1); gsub(/%/,"",$2); print $1, $2}')
data_pct=${data_pct:-0}
meta_pct=${meta_pct:-0}
log "Pool: data=${data_pct}% metadata=${meta_pct}% threshold=${THRESHOLD}%"

if [ "$data_pct" -ge "$THRESHOLD" ] || [ "$meta_pct" -ge "$THRESHOLD" ]; then
    log "Pool usage at/above threshold. Attempting extension..."
    if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
        extend_pool_from "$PRIMARY_DEV" && { log "Pool extended from primary drive free space."; exit 0; }
    fi
    for d in $(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name' 2>/dev/null); do
        dev="/dev/$d"
        [ "$dev" = "$PRIMARY_DEV" ] && continue
        lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q "/" && continue
        extend_pool_from "$dev" && { log "Pool extended from $dev."; exit 0; }
    done
    log "WARNING: No extendable space found. Pool may run out."
fi

ROOT_PATH="/dev/$VG_NAME/$POOL_VOL_NAME"
if [ -b "$ROOT_PATH" ] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    root_used=$(df --output=pcent "$MOUNT_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
    root_used=${root_used:-0}
    if [ "$root_used" -ge 80 ]; then
        log "Root FS at ${root_used}%. Extending thin volume."
        lvextend -V +"${EXTEND_STEP_GIB}G" --thinpool "$POOL_NAME" "$VG_NAME/$POOL_VOL_NAME" 2>/dev/null || log "Thin volume extend failed."
        btrfs filesystem resize max "$MOUNT_DIR" 2>/dev/null || log "Btrfs resize failed."
    fi
fi

log "Agent check complete."
exit 0
