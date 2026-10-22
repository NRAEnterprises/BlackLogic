#!/bin/bash
set -Eeuo pipefail

LOG_FILE="/var/log/blacklogic.log"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

fail() {
    log "FATAL: $*"
    exit 1
}

run_stage() {
    local label="$1"
    shift
    log ">>> $label"
    "$@" 2>&1 | tee -a "$LOG_FILE" || fail "$label failed"
}

log "========================================"
log "      BLACKLOGIC ORCHESTRATOR"
log "      $(date)"
log "========================================"

run_stage "Stage 1: Environment" "$BIN_DIR/blacklogic-01-env.sh"

log ">>> Stage 2: Format"
if ! "$BIN_DIR/blacklogic-02-format.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "Format failed. Running drive fixer."
    "$BIN_DIR/blacklogic-fix-drives.sh" 2>&1 | tee -a "$LOG_FILE" || fail "Drive fixer failed"
    "$BIN_DIR/blacklogic-02-format.sh" 2>&1 | tee -a "$LOG_FILE" || fail "Format failed after fixer"
fi

log ">>> Stage 3: Install"
if ! "$BIN_DIR/blacklogic-03-install.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "Install failed. Running mount fixer."
    "$BIN_DIR/blacklogic-fix-mount.sh" 2>&1 | tee -a "$LOG_FILE" || fail "Mount fixer failed"
    if ! "$BIN_DIR/blacklogic-03-install.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log "Install failed again. Running network fixer."
        "$BIN_DIR/blacklogic-fix-network.sh" 2>&1 | tee -a "$LOG_FILE" || fail "Network fixer failed"
        "$BIN_DIR/blacklogic-03-install.sh" 2>&1 | tee -a "$LOG_FILE" || fail "Install failed after all fixers"
    fi
fi

log ">>> Stage 4: Aftermath"
"$BIN_DIR/blacklogic-04-aftermath.sh" 2>&1 | tee -a "$LOG_FILE" || fail "Aftermath failed"

log "   SUCCESS: BlackLogic Pipeline Complete"
log "   Log: $LOG_FILE"
