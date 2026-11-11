#!/bin/bash
set -uo pipefail
SCRIPT_DIR=""
for _src in "${ZSH_SOURCE:-}" "${BASH_SOURCE:-}" "${KSH_SOURCE:-}" "$0"; do
    [ -n "$_src" ] && [ -f "$_src" ] && { SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"; break; }
done
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
[ -f "$SCRIPT_DIR/blacklogic-ensure-tools.sh" ] && . "$SCRIPT_DIR/blacklogic-ensure-tools.sh"
require_root
ensure_tools lvs vgs lvextend pvcreate parted btrfs jq blockdev udevadm mount umount 2>/dev/null || true

VG_NAME="black_pool"
POOL_NAME="black_pool"
POOL_VOL_NAME="blacklogic"
MOUNT_DIR="/mnt/blackarch"
STATE_FILE="/tmp/blacklogic-state"
LOG_FILE="/var/log/blacklogic-pool-agent.log"
THRESHOLD="${POOL_AGENT_THRESHOLD:-70}"
META_THRESHOLD="${POOL_AGENT_META_THRESHOLD:-80}"
EXTEND_STEP_GIB="${POOL_AGENT_STEP:-32}"
LOCK_FILE="/tmp/blacklogic-pool-agent.lock"
MAX_PART_WAIT="30"

log() { echo "[$(date +%F_%T)] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date +%F_%T)] WARNING: $*" | tee -a "$LOG_FILE" >&2; }
fail() { echo "[$(date +%F_%T)] FATAL: $*" | tee -a "$LOG_FILE" >&2; exit 1; }

[ -f "$STATE_FILE" ] && source "$STATE_FILE"
export LIVE_DRIVE

# Prevent concurrent execution
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another agent instance is running. Exiting."
    exit 0
fi

vgchange -ay "$VG_NAME" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

if [ ! -b "/dev/$VG_NAME/$POOL_NAME" ] && [ ! -b "/dev/mapper/${VG_NAME}-${POOL_NAME}" ]; then
    log "Thin pool not found, nothing to manage."
    exit 0
fi

PRIMARY_DEV="${PRIMARY_DEV:-}"
[ -z "$PRIMARY_DEV" ] && PRIMARY_DEV=$(pvs --noheadings -o pv_name -S "vg_name=$VG_NAME" 2>/dev/null | head -n1 | tr -d ' ')

clear_foreign_signatures() {
    local dev="$1"
    mdadm --zero-superblock "$dev" 2>/dev/null || true
    zpool labelclear -f "$dev" 2>/dev/null || true
    dmraid -r -E "$dev" 2>/dev/null || true
    wipefs -a "$dev" 2>/dev/null || true
}

free_space_bytes() {
    local dev="$1" total last_end
    total=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    last_end=$(parted -s "$dev" unit B print 2>/dev/null | awk '/^[[:space:]]*[0-9]+/{end=$3} END{gsub(/[^0-9]/,"",end); print end+0}')
    last_end=${last_end:-0}
    echo $((total - last_end))
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

extend_pool_from() {
    local dev="$1" free_bytes need start_b end_b ps next_num np i
    free_bytes=$(free_space_bytes "$dev")
    need=$((EXTEND_STEP_GIB * 1024 * 1024 * 1024))
    [ "$free_bytes" -gt "$need" ] || return 1

    start_b=$(parted -s "$dev" unit B print 2>/dev/null | awk '/^[[:space:]]*[0-9]+/{end=$3} END{gsub(/[^0-9]/,"",end); print end+0}')
    [ -z "$start_b" ] && start_b=2048
    end_b=$((start_b + need))

    [[ "$dev" == *nvme* ]] && ps="p" || ps=""
    next_num=$(lsblk -n -o NAME "$dev" 2>/dev/null | grep -cE '[0-9]$' || echo 0)
    next_num=$((next_num + 1))
    np="${dev}${ps}${next_num}"

    if ! parted -s "$dev" mkpart primary "pool-ext" "${start_b}B" "${end_b}B" 2>/dev/null; then
        return 1
    fi
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    if ! wait_for_partition "$np" "$MAX_PART_WAIT"; then
        return 1
    fi

    clear_foreign_signatures "$np"
    if ! pvcreate -y "$np" 2>/dev/null; then
        return 1
    fi
    if ! vgextend "$VG_NAME" "$np" 2>/dev/null; then
        pvremove -ff -y "$np" 2>/dev/null || true
        return 1
    fi
    if ! lvextend -L +"${EXTEND_STEP_GIB}G" "/dev/$VG_NAME/$POOL_NAME" 2>/dev/null; then
        return 1
    fi
    log "Extended pool by ${EXTEND_STEP_GIB}GiB using $np"
    return 0
}

# Get pool usage
data_pct=0
meta_pct=0
if lvs "/dev/$VG_NAME/$POOL_NAME" &>/dev/null; then
    read -r data_pct meta_pct < <(lvs --noheadings -o data_percent,metadata_percent "/dev/$VG_NAME/$POOL_NAME" 2>/dev/null | awk '{gsub(/%/,"",$1); gsub(/%/,"",$2); print $1, $2}')
fi
data_pct=${data_pct:-0}
meta_pct=${meta_pct:-0}
log "Pool: data=${data_pct}% metadata=${meta_pct}% threshold=${THRESHOLD}%/${META_THRESHOLD}%"

if awk "BEGIN{exit !($data_pct >= $THRESHOLD || $meta_pct >= $META_THRESHOLD)}"; then
    log "Pool usage at/above threshold. Attempting extension..."
    if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
        if extend_pool_from "$PRIMARY_DEV"; then
            log "Pool extended from primary drive free space."
            exit 0
        fi
    fi
    for d in $(lsblk -J -b -o NAME,TYPE 2>/dev/null | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name|startswith("zram")|not) | select(.name|startswith("loop")|not) | .name' 2>/dev/null); do
        dev="/dev/$d"
        [ "$dev" = "$PRIMARY_DEV" ] && continue
        lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q "/" && continue
        if extend_pool_from "$dev"; then
            log "Pool extended from $dev."
            exit 0
        fi
    done
    log "WARNING: No extendable space found. Pool may run out."
fi

# Thin pool metadata LV check
META_LV="${POOL_NAME}_tmeta"
if lvs "$VG_NAME/$META_LV" &>/dev/null; then
    META_USED=$(lvs --noheadings -o data_percent "$VG_NAME/$META_LV" 2>/dev/null | tr -dc '0-9.' | head -c 6)
    META_USED=${META_USED:-0}
    if awk "BEGIN{exit !($META_USED >= $META_THRESHOLD)}"; then
        log "Metadata LV at ${META_USED}%. Extending metadata."
        if ! lvextend -L +1G "/dev/$VG_NAME/$META_LV" 2>/dev/null; then
            log "Metadata extend failed."
        fi
    fi
fi

# Root FS check
ROOT_PATH="/dev/$VG_NAME/$POOL_VOL_NAME"
if [ -b "$ROOT_PATH" ] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    root_used=$(df --output=pcent "$MOUNT_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
    root_used=${root_used:-0}
    if [ "$root_used" -ge 80 ]; then
        log "Root FS at ${root_used}%. Extending thin volume."
        if ! lvextend -V +"${EXTEND_STEP_GIB}G" --thinpool "$POOL_NAME" "$VG_NAME/$POOL_VOL_NAME" 2>/dev/null; then
            log "Thin volume extend failed."
        else
            btrfs filesystem resize max "$MOUNT_DIR" 2>/dev/null || log "Btrfs resize failed."
        fi
    fi
fi

log "Agent check complete."
exit 0