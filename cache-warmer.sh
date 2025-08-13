#!/bin/bash
# Cache Warmer Script v5.3 (Replaces all wget with curl for consistency)
set -euo pipefail

# --- CONFIGURATION ---
STATS_FILE="/var/log/cache-warmer/stats.csv"
LOCK_DIR="/var/run/cache-warmer"
EXCLUSION_FILE="/root/warmer_exclusions.txt"
USER_AGENT_DESKTOP="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
USER_AGENT_MOBILE="Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) CriOS/28.0.1500.12 Mobile/10B329 Safari/8536.25"
# --- End Configuration ---

if [[ $# -lt 2 ]]; then echo "Usage: $0 <domain/path> <sitemap_path> [verbose] [origin_ip]" >&2; exit 1; fi

URL_DOMAIN=$1
SITEMAP_PATH=$2
VERBOSE_FLAG="${3:-}"
ORIGIN_IP="${4:-}"

SAFE_ID=$(echo "$URL_DOMAIN" | tr '/' '-')
SITEMAP_INDEX_URL="https://$URL_DOMAIN/$SITEMAP_PATH"
LOCK_FILE="${LOCK_DIR}/${SAFE_ID}.lck"

declare -a resolve_args=()
if [[ -n "$ORIGIN_IP" ]]; then
    base_domain=$(echo "$URL_DOMAIN" | cut -d'/' -f1)
    resolve_args=("--resolve" "${base_domain}:443:${ORIGIN_IP}")
fi

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$SAFE_ID] $1" >&2; }
if [[ -n "$ORIGIN_IP" ]]; then log "Using Origin IP ${ORIGIN_IP} to bypass proxy/CDN."; fi

exec 200>"$LOCK_FILE"
if ! flock -n 200; then log "Could not acquire lock, another process is running. Exiting."; exit 0; fi
trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT

is_numeric() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

warm_url() {
    local url_to_warm="$1"; local progress_counter="$2"; local total_urls="$3"
    local desktop_time mobile_time
    desktop_time=$(nice -n 19 curl --max-time 30 "${resolve_args[@]}" -A "$USER_AGENT_DESKTOP" -sL --compressed -w "%{time_total}" "$url_to_warm" -o /dev/null || echo "0")
    mobile_time=$(nice -n 19 curl --max-time 30 "${resolve_args[@]}" -A "$USER_AGENT_MOBILE" -sL --compressed -w "%{time_total}" "$url_to_warm" -o /dev/null || echo "0")
    
    local desktop_sleep=0; if is_numeric "$desktop_time"; then desktop_sleep=$(bc <<< "scale=4; if($desktop_time > 0) $desktop_time * $desktop_time * 1.2 + 0.1 else 0" 2>/dev/null); fi
    local mobile_sleep=0; if is_numeric "$mobile_time"; then mobile_sleep=$(bc <<< "scale=4; if($mobile_time > 0) $mobile_time * $mobile_time * 1.2 + 0.1 else 0" 2>/dev/null); fi
    if [[ "$VERBOSE_FLAG" == "verbose" ]]; then
        local progress_str="($progress_counter/$total_urls)"; local pause_str="Pausing D: ${desktop_sleep:-0}s, M: ${mobile_sleep:-0}s"
        printf "[%s] %-12s / %-30s / %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$progress_str" "$pause_str" "$url_to_warm" >&2
    fi
    sleep "${desktop_sleep:-0}"; sleep "${mobile_sleep:-0}"
    echo "${desktop_time:-0} ${mobile_time:-0}"
}

calculate_stats() { # This function remains unchanged
    if [[ $# -eq 0 ]]; then echo "0,0,0"; return; fi
    local times_array=("$@")
    local min max; min=$(printf "%s\n" "${times_array[@]}" | sort -n | head -n1); max=$(printf "%s\n" "${times_array[@]}" | sort -n | tail -n1)
    local total=0; for t in "${times_array[@]}"; do if is_numeric "$t"; then total=$(bc <<< "$total + $t"); fi; done
    local avg; avg=$(bc <<< "scale=4; $total / ${#times_array[@]}"); echo "$min,$max,$avg"
}

main() {
    if [[ ! -f "$EXCLUSION_FILE" ]]; then log "ERROR: Exclusion file not found"; exit 1; fi
    log "Starting warmer. Fetching index: $SITEMAP_INDEX_URL"
    # --- MODIFICATION: Replaced wget with curl ---
    local sitemap_index_content; sitemap_index_content=$(curl --max-time 30 "${resolve_args[@]}" --user-agent="$USER_AGENT_DESKTOP" -sL --compressed "$SITEMAP_INDEX_URL" 2>/dev/null || true)
    
    if [[ -z "$sitemap_index_content" ]]; then log "ERROR: Sitemap index is empty or failed to download."; exit 1; fi
    local initial_locs; initial_locs=$(echo "$sitemap_index_content" | xmlstarlet sel -t -v "//_:loc" -n 2>/dev/null)
    if [ $? -ne 0 ]; then log "ERROR: Failed to parse sitemap (likely HTML block)."; exit 1; fi
    declare -a all_page_urls=()
    while read -r url; do
        if [[ -z "$url" ]]; then continue; fi
        if [[ "$url" == *.xml* && "$url" != *attachment-sitemap.xml* ]]; then
            log "Processing nested sitemap: $url"
            # --- MODIFICATION: Replaced wget with curl ---
            mapfile -t nested_urls < <(curl --max-time 30 "${resolve_args[@]}" --user-agent="$USER_AGENT_DESKTOP" -sL --compressed "$url" 2>/dev/null | xmlstarlet sel -t -v "//_:loc" -n 2>/dev/null || true)
            all_page_urls+=("${nested_urls[@]}")
        elif [[ "$url" != *.xml* ]]; then all_page_urls+=("$url"); fi
    done < <(echo "$initial_locs")
    if [[ ${#all_page_urls[@]} -eq 0 ]]; then log "No page URLs found after processing. Exiting."; exit 0; fi
    mapfile -t unique_urls < <(printf "%s\n" "${all_page_urls[@]}" | grep . | sort -u)
    local total_unique_count=${#unique_urls[@]}
    mapfile -t final_urls < <(printf "%s\n" "${unique_urls[@]}" | grep -vFf "$EXCLUSION_FILE")
    if [[ ${#final_urls[@]} -eq 0 ]]; then log "No valid URLs left after filtering. Exiting."; exit 0; fi
    log "Found $total_unique_count total unique pages. Warming ${#final_urls[@]} after filtering..."
    declare -a desktop_times=()
    declare -a mobile_times=()
    local total_warmed_count="${#final_urls[@]}"
    for (( i=0; i<total_warmed_count; i++ )); do
        page_url="${final_urls[i]}"
        read -r d_time m_time < <(warm_url "$page_url" "$((i+1))" "$total_warmed_count")
        desktop_times+=("$d_time")
        mobile_times+=("$m_time")
    done
    local desktop_stats; desktop_stats=$(calculate_stats "${desktop_times[@]}")
    local mobile_stats; mobile_stats=$(calculate_stats "${mobile_times[@]}")
    local timestamp; timestamp=$(date --iso-8601=seconds)
    if [ ! -f "$STATS_FILE" ]; then echo "timestamp,domain,total_unique_urls,urls_warmed,desktop_min_s,desktop_max_s,desktop_avg_s,mobile_min_s,mobile_max_s,mobile_avg_s" > "$STATS_FILE"; fi
    echo "$timestamp,$SAFE_ID,$total_unique_count,${#final_urls[@]},$desktop_stats,$mobile_stats" >> "$STATS_FILE"
    log "Warming complete. Stats saved to $STATS_FILE"
}

main