#!/bin/bash
#
# Master Cache Warmer Runner v2.0 (Cookie-Aware)
# This version is updated to read an optional third column from sites.conf
# for cookie values and pass them to the worker script.
#
set -euo pipefail

# Config
WARMER_SCRIPT="/root/cache-warmer.sh"
SITES_CONFIG="/root/sites.conf"
LOG_DIR="/var/log/cache-warmer"
LOCK_DIR="/var/run/cache-warmer"

# Safer default for memory-constrained servers
MAX_JOBS=4

VERBOSE_MODE=""
if [[ "${1:-}" == "verbose" ]]; then
    VERBOSE_MODE="verbose"
fi

mkdir -p "$LOG_DIR" "$LOCK_DIR"

MASTER_LOG_FILE="${LOG_DIR}/master.log"
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [MASTER] $1" >> "$MASTER_LOG_FILE"; }

# Truncate the log file at the start of a new run
>"$MASTER_LOG_FILE"
log "Starting master warmer process (v2.0) with up to $MAX_JOBS concurrent jobs."

initial_delay=$(awk -v min=5 -v max=15 'BEGIN{srand(); print min+rand()*(max-min)}')
log "Waiting for ${initial_delay}s before starting first job..."
sleep "$initial_delay"

# Read the config file, shuffle it, and process each line
grep -vE '^\s*(#|$)' "$SITES_CONFIG" | shuf | while IFS= read -r line; do
    # --- THE FIX IS HERE ---
    # Use 'read' to parse up to 3 columns from the line.
    # 'cookies' will be empty if the third column doesn't exist.
    read -r domain sitemap cookies <<< "$line"

    if [[ -z "$domain" || -z "$sitemap" ]]; then
        log "Skipping malformed line: $line"
        continue
    fi
    
    # Wait if the max number of jobs are already running
    while (( $(jobs -r -p | wc -l) >= MAX_JOBS )); do
        wait -n
    done

    random_delay=$(awk -v min=3 -v max=7 'BEGIN{srand(); print min+rand()*(max-min)}')
    log "Pausing for ${random_delay}s then dispatching for $domain"
    sleep "$random_delay"
    
    # Build the argument list for the worker script
    declare -a worker_args=("$domain" "$sitemap")
    if [[ -n "$cookies" ]]; then
        worker_args+=("$cookies")
        log "--> Found cookie variations for $domain."
    fi
    if [[ -n "$VERBOSE_MODE" ]]; then
        worker_args+=("$VERBOSE_MODE")
    fi
    
    # Dispatch the worker script with the correct set of arguments
    (
        bash "$WARMER_SCRIPT" "${worker_args[@]}"
    ) > "${LOG_DIR}/${domain}.log" 2>&1 &

done

wait
log "All warming tasks dispatched and completed."