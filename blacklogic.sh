#!/bin/bash
set -uo pipefail
LOG_FILE="/var/log/blacklogic.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"
log() { echo "$*" | tee -a "$LOG_FILE"; }
log "========================================"
log "      BLACKLOGIC ORCHESTRATOR"
log "      $(date)"
log "========================================"
log ">>> Stage 1: Environment"
"$SCRIPT_DIR/blacklogic-01-env.sh" 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Env."; exit 1; }
log ">>> Stage 2: Format"
if ! "$SCRIPT_DIR/blacklogic-02-format.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "Format failed. Fixer."
    "$SCRIPT_DIR/blacklogic-fix-drives.sh" 2>&1 | tee -a "$LOG_FILE"
    "$SCRIPT_DIR/blacklogic-02-format.sh" 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Format."; exit 1; }
fi
log ">>> Stage 2.5: Pool Agent"
"$SCRIPT_DIR/blacklogic-pool-agent.sh" 2>&1 | tee -a "$LOG_FILE" || true
log ">>> Stage 3: Install"
if ! "$SCRIPT_DIR/blacklogic-03-install.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "Install failed. Mount fixer."
    "$SCRIPT_DIR/blacklogic-fix-mount.sh" 2>&1 | tee -a "$LOG_FILE"
    if ! "$SCRIPT_DIR/blacklogic-03-install.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log "Install failed again. Network fixer."
        "$SCRIPT_DIR/blacklogic-fix-network.sh" 2>&1 | tee -a "$LOG_FILE"
        "$SCRIPT_DIR/blacklogic-03-install.sh" 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Install."; exit 1; }
    fi
fi
log ">>> Stage 4: Aftermath"
"$SCRIPT_DIR/blacklogic-04-aftermath.sh" 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Aftermath."; exit 1; }
log "   SUCCESS: BlackLogic Pipeline Complete"
log "   Log: $LOG_FILE"
