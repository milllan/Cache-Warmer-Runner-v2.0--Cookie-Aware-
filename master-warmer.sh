#!/bin/bash
# Master Cache Warmer Runner v2.0 (Interactive logging & increased concurrency)
set -euo pipefail

# --- CONFIGURATION ---
WARMER_SCRIPT="/root/cache-warmer.sh"
SITES_CONFIG="/root/sites.conf"
LOG_DIR="/var/log/cache-warmer"
LOCK_DIR="/var/run/cache-warmer"
MAX_JOBS=4
# --- END CONFIGURATION ---

VERBOSE_MODE=""
if [[ "${1:-}" == "verbose" ]]; then
    VERBOSE_MODE="verbose"
fi

# This directory is created by the robust cron job, but we ensure it here too.
mkdir -p "$LOG_DIR" "$LOCK_DIR"

MASTER_LOG_FILE="${LOG_DIR}/master.log"

# The log function sends output to the terminal AND appends to the master log file.
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [MASTER] $1" | tee -a "$MASTER_LOG_FILE"; }

# If in verbose mode, clear the master log for a clean run. Otherwise, append.
if [[ "$VERBOSE_MODE" == "verbose" ]]; then
    >"$MASTER_LOG_FILE"
else
    # For cron, add a separator for new runs for readability.
    echo "---" >> "$MASTER_LOG_FILE"
fi

log "Starting master warmer process with up to $MAX_JOBS concurrent jobs."

initial_delay=$(awk -v min=5 -v max=15 'BEGIN{srand(); print min+rand()*(max-min)}')
log "Waiting for ${initial_delay}s before starting first job..."
sleep "$initial_delay"

grep -vE '^\s*(#|$)' "$SITES_CONFIG" | shuf | while IFS= read -r line; do
    domain=$(echo "$line" | awk '{print $1}')
    sitemap=$(echo "$line" | awk '{print $2}')
    if [[ -z "$domain" || -z "$sitemap" ]]; then continue; fi
    
    while (( $(jobs -r -p | wc -l) >= MAX_JOBS )); do
        wait -n
    done

    random_delay=$(awk -v min=3 -v max=7 'BEGIN{srand(); print min+rand()*(max-min)}')
    log "Pausing for ${random_delay}s then dispatching for $domain"
    sleep "$random_delay"
    
    # Use `tee` to send worker output to BOTH the log file and stdout (the terminal)
    (
        bash "$WARMER_SCRIPT" "$domain" "$sitemap" "$VERBOSE_MODE"
    ) 2>&1 | tee "${LOG_DIR}/${domain}.log" &

done
wait
log "All warming tasks dispatched and completed."