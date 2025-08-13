#!/bin/bash
#
# Cache Warmer Script v5.0 (Cookie Support)
# Expands on v4.9 to support multiple cookie values for warming
# separate cache versions, mirroring the WP plugin's functionality.
#

set -euo pipefail

# --- CONFIGURATION ---
STATS_FILE="/var/log/cache-warmer/stats.csv"
LOCK_DIR="/var/run/cache-warmer"
EXCLUSION_FILE="/root/warmer_exclusions.txt"

# Set the name of the cookie your site uses for variations.
COOKIE_NAME="yay_currency_widget"

USER_AGENT_DESKTOP="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
USER_AGENT_MOBILE="Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) CriOS/28.0.1500.12 Mobile/10B329 Safari/8536.25"
# --- End Configuration ---

# --- Argument Parsing ---
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <domain> <sitemap_path> [cookie_values] [verbose]" >&2
    echo "Example: $0 example.com sitemap_index.xml \"USD,EUR,GBP\" verbose" >&2
    exit 1
fi

URL_DOMAIN=$1
SITEMAP_PATH=$2
COOKIE_VALUES_STR="${3:-}" # Optional 3rd arg
VERBOSE_FLAG="${4:-}"      # Optional 4th arg
SITEMAP_INDEX_URL="https://$URL_DOMAIN/$SITEMAP_PATH"
LOCK_FILE="${LOCK_DIR}/${URL_DOMAIN}.lck"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$URL_DOMAIN] $1" >&2; }

# --- Locking Mechanism ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Could not acquire lock, another process is running. Exiting."
    exit 0
fi
trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT

is_numeric() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

warm_url() {
    local url_to_warm="$1"
    local cookie_value="$2"
    local progress_counter="$3"
    local total_urls="$4"

    # Build the cookie argument for curl only if a cookie value is provided
    declare -a cookie_arg=()
    if [[ -n "$cookie_value" ]]; then
        cookie_arg=("--cookie" "$COOKIE_NAME=$cookie_value")
    fi

    local desktop_time mobile_time
    desktop_time=$(nice -n 19 curl --max-time 30 -A "$USER_AGENT_DESKTOP" "${cookie_arg[@]}" -sL --compressed -w "%{time_total}" "$url_to_warm" -o /dev/null || echo "0")
    mobile_time=$(nice -n 19 curl --max-time 30 -A "$USER_AGENT_MOBILE" "${cookie_arg[@]}" -sL --compressed -w "%{time_total}" "$url_to_warm" -o /dev/null || echo "0")

    local desktop_sleep=0; if is_numeric "$desktop_time"; then desktop_sleep=$(bc <<< "scale=4; if($desktop_time > 0) $desktop_time * $desktop_time * 1.2 + 0.1 else 0" 2>/dev/null); fi
    local mobile_sleep=0; if is_numeric "$mobile_time"; then mobile_sleep=$(bc <<< "scale=4; if($mobile_time > 0) $mobile_time * $mobile_time * 1.2 + 0.1 else 0" 2>/dev/null); fi

    if [[ "$VERBOSE_FLAG" == "verbose" ]]; then
        local progress_str="($progress_counter/$total_urls)"
        local cookie_str="Cookie: ${cookie_value:-none}"
        local pause_str="Pause D:${desktop_sleep:-0}s,M:${mobile_sleep:-0}s"
        printf "[%s] %-12s / %-20s / %-25s / %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$progress_str" "$cookie_str" "$pause_str" "$url_to_warm" >&2
    fi

    sleep "${desktop_sleep:-0}"; sleep "${mobile_sleep:-0}"
    echo "${desktop_time:-0} ${mobile_time:-0}"
}

calculate_stats() {
    if [[ $# -eq 0 ]]; then echo "0,0,0"; return; fi
    local times_array=("$@")
    local min max; min=$(printf "%s\n" "${times_array[@]}" | sort -n | head -n1); max=$(printf "%s\n" "${times_array[@]}" | sort -n | tail -n1)
    local total=0; for t in "${times_array[@]}"; do if is_numeric "$t"; then total=$(bc <<< "$total + $t"); fi; done
    local avg; avg=$(bc <<< "scale=4; $total / ${#times_array[@]}"); echo "$min,$max,$avg"
}

main() {
    if [[ ! -f "$EXCLUSION_FILE" ]]; then log "ERROR: Exclusion file not found at $EXCLUSION_FILE"; exit 1; fi

    log "Starting warmer. Fetching index: $SITEMAP_INDEX_URL"
    local sitemap_index_content; sitemap_index_content=$(wget --user-agent="$USER_AGENT_DESKTOP" -qO- "$SITEMAP_INDEX_URL" 2>/dev/null || true)
    if [[ -z "$sitemap_index_content" ]]; then log "ERROR: Sitemap index is empty or failed to download."; exit 1; fi
    local initial_locs; initial_locs=$(echo "$sitemap_index_content" | xmlstarlet sel -t -v "//_:loc" -n 2>/dev/null)
    if [ $? -ne 0 ]; then log "ERROR: Failed to parse sitemap (likely HTML block)."; exit 1; fi

    declare -a all_page_urls=()
    while read -r url; do
        if [[ -z "$url" ]]; then continue; fi
        if [[ "$url" == *.xml* && "$url" != *attachment-sitemap.xml* ]]; then
            log "Processing nested sitemap: $url"
            mapfile -t nested_urls < <(wget --user-agent="$USER_AGENT_DESKTOP" -qO- "$url" 2>/dev/null | xmlstarlet sel -t -v "//_:loc" -n 2>/dev/null || true)
            all_page_urls+=("${nested_urls[@]}")
        elif [[ "$url" != *.xml* ]]; then all_page_urls+=("$url"); fi
    done < <(echo "$initial_locs")

    if [[ ${#all_page_urls[@]} -eq 0 ]]; then log "No page URLs found after processing sitemaps. Exiting."; exit 0; fi
    mapfile -t unique_urls < <(printf "%s\n" "${all_page_urls[@]}" | grep . | sort -u)
    local total_unique_count=${#unique_urls[@]}
    mapfile -t final_urls < <(printf "%s\n" "${unique_urls[@]}" | grep -vFf "$EXCLUSION_FILE")
    if [[ ${#final_urls[@]} -eq 0 ]]; then log "No valid URLs left after filtering. Exiting."; exit 0; fi

    # Convert comma-separated cookie string into a bash array
    declare -a cookies_to_process=()
    if [[ -n "$COOKIE_VALUES_STR" ]]; then
        IFS=',' read -r -a cookies_to_process <<< "$COOKIE_VALUES_STR"
    fi

    # If no cookies are provided, add an empty element to the array
    # so the loop runs once without a cookie.
    if (( ${#cookies_to_process[@]} == 0 )); then
        cookies_to_process+=("")
    fi

    local num_urls=${#final_urls[@]}
    local num_cookies=${#cookies_to_process[@]}
    local total_requests=$(( num_urls * num_cookies ))

    log "Found $total_unique_count total unique pages."
    log "Warming $num_urls URLs with $num_cookies variations each ($total_requests total requests)..."

    declare -a desktop_times=()
    declare -a mobile_times=()
    local request_counter=0

    # Main loop: iterate through URLs, then through cookies for each URL
    for page_url in "${final_urls[@]}"; do
        for cookie_val in "${cookies_to_process[@]}"; do
            request_counter=$(( request_counter + 1 ))
            read -r d_time m_time < <(warm_url "$page_url" "$cookie_val" "$request_counter" "$total_requests")
            desktop_times+=("$d_time")
            mobile_times+=("$m_time")
        done
    done

    local desktop_stats; desktop_stats=$(calculate_stats "${desktop_times[@]}")
    local mobile_stats; mobile_stats=$(calculate_stats "${mobile_times[@]}")
    local timestamp; timestamp=$(date --iso-8601=seconds)
    if [ ! -f "$STATS_FILE" ]; then
        echo "timestamp,domain,total_unique_urls,urls_warmed,cookie_variations,total_requests,desktop_min_s,desktop_max_s,desktop_avg_s,mobile_min_s,mobile_max_s,mobile_avg_s" > "$STATS_FILE"
    fi
    echo "$timestamp,$URL_DOMAIN,$total_unique_count,$num_urls,$num_cookies,$total_requests,$desktop_stats,$mobile_stats" >> "$STATS_FILE"
    log "Warming complete. Stats saved to $STATS_FILE"
}

main