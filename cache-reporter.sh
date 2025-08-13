#!/bin/bash
# Cache Warmer Daily Report Generator v1.3 (Adjusted for new stats format)
set -euo pipefail

# --- CONFIGURATION ---
REPORT_EMAIL="your-email@example.com"
LOG_DIR="/var/log/cache-warmer"
STATS_FILE="/var/log/cache-warmer/stats.csv"
# --- END CONFIGURATION ---

if [ ! -d "$LOG_DIR" ]; then echo "Log dir not found" >&2; exit 1; fi
REPORT_FILE=$(mktemp)
trap 'rm -f -- "$REPORT_FILE"' EXIT

echo "Cache Warmer Daily Report for $(hostname) - $(date)" >> "$REPORT_FILE"
echo "======================================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# FAILED SITES Section (no changes)
echo "--- FAILED SITES (in last 24 hours) ---" >> "$REPORT_FILE"
FAILED_LOGS=$(find "$LOG_DIR" -name "*.log" -mtime -1 -exec grep -l -i -E "ERROR|fail|403|404|503|blocked|denied" {} +)
if [ -n "$FAILED_LOGS" ]; then
    for logfile in $FAILED_LOGS; do
        SITENAME=$(basename "$logfile" .log)
        LAST_ERROR=$(grep -i -E "ERROR|fail|403|404|503|blocked|denied" "$logfile" | tail -n 1)
        echo "  - $SITENAME: $LAST_ERROR" >> "$REPORT_FILE"
    done
else
    echo "  No sites failed." >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# PERFORMANCE HIGHLIGHTS Section (updated column numbers)
echo "--- PERFORMANCE HIGHLIGHTS (from last 24 hours) ---" >> "$REPORT_FILE"
if [ ! -f "$STATS_FILE" ]; then
    echo "  Stats file not found yet." >> "$REPORT_FILE"
else
    RECENT_STATS=$(tail -n +2 "$STATS_FILE" | awk -F, -v d="$(date --date='-24 hours' --iso-8601=seconds)" '$1 > d')
    if [ -z "$RECENT_STATS" ]; then
        echo "  No new stats recorded in the last 24 hours." >> "$REPORT_FILE"
    else
        echo "  Slowest Average Desktop Times:" >> "$REPORT_FILE"
        # --- THE FIX IS HERE: Column numbers are updated (e.g., k6 -> k7) ---
        echo "$RECENT_STATS" | sort -t, -k7 -nr | head -n 5 | awk -F, '{printf "    - %-30s Avg: %s s\n", $2, $7}' >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "  Slowest Average Mobile Times:" >> "$REPORT_FILE"
        # --- THE FIX IS HERE: Column numbers are updated (e.g., k9 -> k10) ---
        echo "$RECENT_STATS" | sort -t, -k10 -nr | head -n 5 | awk -F, '{printf "    - %-30s Avg: %s s\n", $2, $10}' >> "$REPORT_FILE"
    fi
fi
echo "" >> "$REPORT_FILE"

# SUCCESSFUL SITES Section (updated to pull from stats file)
echo "--- SUCCESSFUL SITES (in last 24 hours) ---" >> "$REPORT_FILE"
if [ -z "${RECENT_STATS:-}" ]; then
    echo "  No sites ran successfully in the last 24 hours." >> "$REPORT_FILE"
else
    # --- THE FIX IS HERE: Now uses the stats file for a cleaner report ---
    echo "$RECENT_STATS" | awk -F, '{printf "  - %-30s Warmed %s of %s pages\n", $2, $4, $3}' >> "$REPORT_FILE"
fi

mail -s "Cache Warmer Daily Report for $(hostname)" "$REPORT_EMAIL" < "$REPORT_FILE"
echo "Report sent to $REPORT_EMAIL."
