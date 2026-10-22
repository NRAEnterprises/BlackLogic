#!/bin/bash
set -uo pipefail
LOG_FILE="/var/log/blacklogic.log"
mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"
log() { echo "$*" | tee -a "$LOG_FILE"; }
log "========================================"
log "      BLACKLOGIC ORCHESTRATOR"
log "      $(date)"
log "========================================"
log ">>> Stage 1: Environment"
/usr/local/bin/blacklogic-01-env.sh 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Env."; exit 1; }
log ">>> Stage 2: Format"
if ! /usr/local/bin/blacklogic-02-format.sh 2>&1 | tee -a "$LOG_FILE"; then
    log "Format failed. Fixer."
    /usr/local/bin/blacklogic-fix-drives.sh 2>&1 | tee -a "$LOG_FILE"
    /usr/local/bin/blacklogic-02-format.sh 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Format."; exit 1; }
fi
log ">>> Stage 3: Install"
if ! /usr/local/bin/blacklogic-03-install.sh 2>&1 | tee -a "$LOG_FILE"; then
    log "Install failed. Mount fixer."
    /usr/local/bin/blacklogic-fix-mount.sh 2>&1 | tee -a "$LOG_FILE"
    if ! /usr/local/bin/blacklogic-03-install.sh 2>&1 | tee -a "$LOG_FILE"; then
        log "Install failed again. Network fixer."
        /usr/local/bin/blacklogic-fix-network.sh 2>&1 | tee -a "$LOG_FILE"
        /usr/local/bin/blacklogic-03-install.sh 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Install."; exit 1; }
    fi
fi
log ">>> Stage 4: Aftermath"
/usr/local/bin/blacklogic-04-aftermath.sh 2>&1 | tee -a "$LOG_FILE" || { log "FATAL: Aftermath."; exit 1; }
log "   SUCCESS: BlackLogic Pipeline Complete"
log "   Log: $LOG_FILE"
