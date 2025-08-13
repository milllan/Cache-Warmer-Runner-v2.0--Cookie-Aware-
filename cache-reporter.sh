#!/bin/bash
# Cache Warmer Daily Report Generator v1.3
set -euo pipefail

# --- CONFIGURATION ---
# IMPORTANT: Change this to your actual email address.
REPORT_EMAIL="your-email@example.com"
LOG_DIR="/var/log/cache-warmer"
STATS_FILE="/var/log/cache-warmer/stats.csv"
# --- END CONFIGURATION ---

YESTERDAY=$(date -d "yesterday" --iso-8601=date)
REPORT_FILE=$(mktemp)
trap 'rm -f "$REPORT_FILE"' EXIT

echo "Subject: Cache Warmer Daily Report for ${YESTERDAY}" > "$REPORT_FILE"
echo "Content-Type: text/plain; charset=UTF-8" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "=== Cache Warmer Summary for ${YESTERDAY} ===" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Section 1: Error Summary
echo "--- Error Summary ---" >> "$REPORT_FILE"
# Find any file in the log dir modified in the last 24 hours, search for "ERROR"
ERROR_LOG=$(find "$LOG_DIR" -mtime -1 -type f -name "*.log" -exec grep -H "ERROR" {} +)
if [[ -n "$ERROR_LOG" ]]; then
    echo "Errors were detected in the last 24 hours:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "$ERROR_LOG" >> "$REPORT_FILE"
else
    echo "No errors detected in the last 24 hours." >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# Section 2: Performance Highlights from stats.csv
echo "--- Performance Highlights (from stats.csv) ---" >> "$REPORT_FILE"
if [[ -f "$STATS_FILE" ]]; then
    # Get header and yesterday's data
    (head -n 1 "$STATS_FILE" && grep "^${YESTERDAY}" "$STATS_FILE") > "${REPORT_FILE}.tmp"

    if [[ $(wc -l < "${REPORT_FILE}.tmp") -gt 1 ]]; then
        echo "Sites warmed yesterday:" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        column -t -s, "${REPORT_FILE}.tmp" >> "$REPORT_FILE"
        
        # Add summary stats
        echo "" >> "$REPORT_FILE"
        echo "---" >> "$REPORT_FILE"
        # Skip header(NR>1), get stats, then use awk for summary
        awk -F, 'NR>1 {
            count++; 
            urls+=$4; 
            d_avg_sum+=$7; 
            m_avg_sum+=$10; 
            if(min_d=="" || $5<min_d) min_d=$5; 
            if(max_d=="" || $6>max_d) max_d=$6;
        } END {
            if(count>0) {
                printf "Sites Processed: %d\n", count;
                printf "Total URLs Warmed: %d\n", urls;
                printf "Fastest Desktop Page (min): %.4f s\n", min_d;
                printf "Slowest Desktop Page (max): %.4f s\n", max_d;
                printf "Overall Desktop Avg: %.4f s\n", d_avg_sum/count;
                printf "Overall Mobile Avg:  %.4f s\n", m_avg_sum/count;
            }
        }' "${REPORT_FILE}.tmp" >> "$REPORT_FILE"
        
    else
        echo "No warming statistics were recorded for ${YESTERDAY}." >> "$REPORT_FILE"
    fi
    rm -f "${REPORT_FILE}.tmp"
else
    echo "Statistics file not found at ${STATS_FILE}." >> "$REPORT_FILE"
fi

# Send the email
/usr/sbin/sendmail -t < "$REPORT_FILE"