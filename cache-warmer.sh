#!/bin/bash
# Cache Warmer Script - PORTABLE v5.7.1 (portable XML parser, errexit-safe)
# v5.7: xmlstarlet is now OPTIONAL. It is used when installed; otherwise the
# sitemap <loc> entries are extracted with a grep/sed fallback. This keeps one
# identical script runnable on hosts where no packages can be installed
# (managed shared hosting). Behavior where xmlstarlet exists is unchanged.
# v5.7.1 (review fixes): errexit-safe curl exit capture in warm_url, || true
# on the grep branch, &#038;/&#38; entity decoding, whitespace-trim parity
# between parser modes, and -- before the URL argument.
set -euo pipefail

# This line finds the directory where the script is located.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# --- CONFIGURATION (Paths are relative to the script's location) ---
STATS_FILE="$SCRIPT_DIR/logs/stats.csv"
LOCK_DIR="$SCRIPT_DIR/run"
EXCLUSION_FILE="$SCRIPT_DIR/warmer_exclusions.txt"
USER_AGENT_DESKTOP="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
USER_AGENT_MOBILE="Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) CriOS/28.0.1500.12 Mobile/10B329 Safari/8536.25"

# Set by check_dependencies(): "xmlstarlet" or "grep"
PARSE_MODE=""

# -----------------
# FUNCTION DEFINITIONS
# -----------------

check_dependencies() {
    local -a required_cmds=("curl" "bc" "flock")
    local -a missing_cmds=()

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo "ERROR: Missing required command(s): ${missing_cmds[*]}." >&2
        exit 1
    fi

    # xmlstarlet is optional: it parses sitemaps more robustly, but hosts
    # where nothing can be installed fall back to grep/sed (see parse_locs).
    if command -v xmlstarlet &> /dev/null; then
        PARSE_MODE="xmlstarlet"
    else
        PARSE_MODE="grep"
    fi
}

# Logs a message to standard error.
log() {
    # $1: The SAFE_ID of the site
    # $2: The message to log
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$1] $2" >&2
}

# Extract one URL per line from sitemap XML on stdin.
# Both modes trim surrounding whitespace. The modes are equivalent for
# standard sitemaps (plain <loc> elements, as emitted by WordPress/Yoast) but
# differ on exotic content: the grep branch does not match CDATA, multiline,
# or namespace-prefixed <loc>; xmlstarlet handles those. Entities: xmlstarlet
# decodes numeric entities (&#038; etc.) but re-escapes &amp; on output; the
# grep branch decodes &amp;, &#38; and &#038; explicitly (WordPress esc_url
# emits &#038;). The || true in both branches keeps a no-match grep (exit 1)
# or a failing xmlstarlet from aborting the caller under `set -euo pipefail`.
parse_locs() {
    if [[ "$PARSE_MODE" == "xmlstarlet" ]]; then
        { xmlstarlet sel -t -v "//_:loc" -n 2>/dev/null || true; } \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    else
        { grep -o '<loc>[^<]*</loc>' || true; } \
            | sed -e 's|^<loc>||' -e 's|</loc>$||' \
                  -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                  -e 's/&#038;/\&/g' -e 's/&#38;/\&/g' -e 's/&amp;/\&/g'
    fi
}

is_numeric() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

warm_url() {
    local url_to_warm="$1"
    local progress_counter="$2"
    local total_urls="$3"
    local -n resolve_args_ref="$4"
    local safe_id="$5"
    local verbose_flag="$6"
    local desktop_time mobile_time
    local curl_ret=0

    # Desktop
    # The `|| curl_ret=$?` shape is required: a bare failing assignment would
    # trip errexit and abort the whole run before the handling below could
    # run. `--` guards against a URL that begins with a dash being parsed as
    # curl options.
    curl_ret=0
    desktop_time=$(nice -n 19 curl --max-time 30 "${resolve_args_ref[@]}" -A "$USER_AGENT_DESKTOP" -sL --compressed -o /dev/null -w "%{time_total}" -- "$url_to_warm" 2>/dev/null) || curl_ret=$?
    if [[ $curl_ret -eq 28 ]]; then
        log "$safe_id" "WARNING: Timeout warming $url_to_warm (Desktop Agent)"
        desktop_time="0"
    elif [[ $curl_ret -ne 0 ]]; then
        desktop_time="0"
    fi

    # Mobile
    curl_ret=0
    mobile_time=$(nice -n 19 curl --max-time 30 "${resolve_args_ref[@]}" -A "$USER_AGENT_MOBILE" -sL --compressed -o /dev/null -w "%{time_total}" -- "$url_to_warm" 2>/dev/null) || curl_ret=$?
    if [[ $curl_ret -eq 28 ]]; then
        log "$safe_id" "WARNING: Timeout warming $url_to_warm (Mobile Agent)"
        mobile_time="0"
    elif [[ $curl_ret -ne 0 ]]; then
        mobile_time="0"
    fi

    local desktop_sleep=0; if is_numeric "$desktop_time"; then desktop_sleep=$(bc <<< "scale=4; if($desktop_time > 0) $desktop_time * $desktop_time * 1.2 + 0.1 else 0" 2>/dev/null); fi
    local mobile_sleep=0; if is_numeric "$mobile_time"; then mobile_sleep=$(bc <<< "scale=4; if($mobile_time > 0) $mobile_time * $mobile_time * 1.2 + 0.1 else 0" 2>/dev/null); fi
    if [[ "$verbose_flag" == "verbose" ]]; then
        local progress_str="($progress_counter/$total_urls)"
        local pause_str="Pausing D: ${desktop_sleep:-0}s, M: ${mobile_sleep:-0}s"
        printf "[%s] %-12s / %-30s / %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$progress_str" "$pause_str" "$url_to_warm" >&2
    fi
    sleep "${desktop_sleep:-0}"
    sleep "${mobile_sleep:-0}"
    echo "${desktop_time:-0} ${mobile_time:-0}"
}

calculate_stats() {
    if [[ $# -eq 0 ]]; then echo "0,0,0"; return; fi
    local times_array=("$@")
    local min max
    min=$(printf "%s\n" "${times_array[@]}" | sort -n | head -n1)
    max=$(printf "%s\n" "${times_array[@]}" | sort -n | tail -n1)
    local total=0
    for t in "${times_array[@]}"; do
        if is_numeric "$t"; then total=$(bc <<< "$total + $t"); fi
    done
    local avg
    avg=$(bc <<< "scale=4; $total / ${#times_array[@]}")
    echo "$min,$max,$avg"
}

# -----------------
# MAIN SCRIPT LOGIC
# -----------------

main() {
    local URL_DOMAIN=$1
    local SITEMAP_PATH=$2
    local VERBOSE_FLAG="${3:-}"
    local ORIGIN_IP="${4:-}"

    local SITEMAP_INDEX_URL="https://$URL_DOMAIN/$SITEMAP_PATH"

    # Ensure local directories exist
    mkdir -p "$LOCK_DIR"
    mkdir -p "$(dirname "$STATS_FILE")"

    # --- Self-locking ---
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "$SAFE_ID" "Could not acquire lock, another process is running. Exiting."
        exit 0
    fi
    trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT

    if [[ ! -f "$EXCLUSION_FILE" ]]; then
        log "$SAFE_ID" "ERROR: Exclusion file not found at $EXCLUSION_FILE"
        exit 1
    fi
    declare -a resolve_args=()
    if [[ -n "$ORIGIN_IP" ]]; then
        local base_domain=$(echo "$URL_DOMAIN" | cut -d'/' -f1)
        resolve_args=("--resolve" "${base_domain}:443:${ORIGIN_IP}")
        log "$SAFE_ID" "Using Origin IP ${ORIGIN_IP} to bypass proxy/CDN."
    fi
    log "$SAFE_ID" "Starting warmer (parser: $PARSE_MODE). Fetching index: $SITEMAP_INDEX_URL"
    local sitemap_index_content
    local curl_exit_code=0

    # Capture output and exit code carefully.
    # We use temporary set +e because we want to handle the failure manually.
    set +e
    # Strip leading whitespace/BOM before the XML declaration — some WP plugins
    # echo a blank line into sitemap renders, which breaks XML parsing.
    # (incident 2026-09-06, sculpiflex.com)
    sitemap_index_content=$(curl --fail --max-time 30 "${resolve_args[@]}" -A "$USER_AGENT_DESKTOP" -sL --compressed "$SITEMAP_INDEX_URL" 2>&1 | sed -e 's/\xef\xbb\xbf//' -e '/./,$!d' | sed -e 's/^[[:space:]]*//' )
    curl_exit_code=$?
    set -e

    if [[ $curl_exit_code -ne 0 ]]; then
        if [[ $curl_exit_code -eq 28 ]]; then
             log "$SAFE_ID" "CRITICAL ERROR: Connection timed out fetching sitemap (Exit Code 28). Possible Firewall/IP Block."
        elif [[ $curl_exit_code -eq 7 ]]; then
             log "$SAFE_ID" "CRITICAL ERROR: Connection refused (Exit Code 7). Server might be down or not listening on this port."
        elif [[ $curl_exit_code -eq 22 ]]; then
             log "$SAFE_ID" "CRITICAL ERROR: HTTP Error (Exit Code 22). The server returned a 4xx or 5xx status."
        elif [[ $curl_exit_code -eq 6 ]]; then
             log "$SAFE_ID" "CRITICAL ERROR: Could not resolve host (Exit Code 6). Check DNS or typos."
        else
             log "$SAFE_ID" "CRITICAL ERROR: Failed to download sitemap. Curl Exit Code: $curl_exit_code. Error details: $sitemap_index_content"
        fi
        exit 1
    fi

    if [[ "$VERBOSE_FLAG" == "verbose" ]]; then
        log "$SAFE_ID" "DEBUG: Downloaded sitemap content length: ${#sitemap_index_content} chars"
    fi

    local initial_locs
    initial_locs=$(echo "$sitemap_index_content" | parse_locs)

    # Check if we actually got any URLs
    if [[ -z "$initial_locs" ]]; then
         # An HTML page instead of XML usually means an error page, a redirect
         # into the site, or a bot-block — not a valid sitemap.
         if echo "$sitemap_index_content" | grep -qi '<html'; then
             log "$SAFE_ID" "ERROR: Sitemap URL returned an HTML page, not XML (redirect to site or error page?). Content preview: $(echo "$sitemap_index_content" | head -c 200)"
             exit 1
         else
             log "$SAFE_ID" "WARNING: Sitemap parsed successfully but contained no <loc> elements."
         fi
    fi
    declare -a all_page_urls=()
    while read -r url; do
        if [[ -z "$url" ]]; then continue; fi
        if [[ "$url" == *.xml* && "$url" != *attachment-sitemap.xml* ]]; then
            log "$SAFE_ID" "Processing nested sitemap: $url"
            mapfile -t nested_urls < <(curl --max-time 30 "${resolve_args[@]}" -A "$USER_AGENT_DESKTOP" -sL --compressed "$url" 2>/dev/null | sed -e 's/\xef\xbb\xbf//' -e '/./,$!d' -e 's/^[[:space:]]*//' | parse_locs)
            all_page_urls+=("${nested_urls[@]}")
        elif [[ "$url" != *.xml* ]]; then
            all_page_urls+=("$url")
        fi
    done < <(echo "$initial_locs")
    if [[ ${#all_page_urls[@]} -eq 0 ]]; then
        log "$SAFE_ID" "No page URLs found after processing. Exiting."
        exit 0
    fi
    mapfile -t unique_urls < <(printf "%s\n" "${all_page_urls[@]}" | grep . | sort -u)
    local total_unique_count=${#unique_urls[@]}
    mapfile -t final_urls < <(printf "%s\n" "${unique_urls[@]}" | grep -vFf "$EXCLUSION_FILE")
    if [[ ${#final_urls[@]} -eq 0 ]]; then
        log "$SAFE_ID" "No valid URLs left after filtering. Exiting."
        exit 0
    fi
    log "$SAFE_ID" "Found $total_unique_count total unique pages. Warming ${#final_urls[@]} after filtering..."
    declare -a desktop_times=()
    declare -a mobile_times=()
    local total_warmed_count="${#final_urls[@]}"
    for (( i=0; i<total_warmed_count; i++ )); do
        page_url="${final_urls[i]}"
        read -r d_time m_time < <(warm_url "$page_url" "$((i+1))" "$total_warmed_count" resolve_args "$SAFE_ID" "$VERBOSE_FLAG") || { d_time=0; m_time=0; }
        desktop_times+=("$d_time")
        mobile_times+=("$m_time")
    done
    local desktop_stats
    desktop_stats=$(calculate_stats "${desktop_times[@]}")
    local mobile_stats
    mobile_stats=$(calculate_stats "${mobile_times[@]}")
    local timestamp
    timestamp=$(date --iso-8601=seconds)
    if [ ! -f "$STATS_FILE" ]; then
        echo "timestamp,domain,total_unique_urls,urls_warmed,desktop_min_s,desktop_max_s,desktop_avg_s,mobile_min_s,mobile_max_s,mobile_avg_s" > "$STATS_FILE"
    fi
    echo "$timestamp,$SAFE_ID,$total_unique_count,${#final_urls[@]},$desktop_stats,$mobile_stats" >> "$STATS_FILE"
    log "$SAFE_ID" "Warming complete. Stats saved to $STATS_FILE"
}

# --- SCRIPT EXECUTION STARTS HERE ---

check_dependencies

# Check for arguments before defining variables that depend on them
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <domain/path> <sitemap_path> [verbose] [origin_ip]" >&2
    exit 1
fi

# Define variables needed by the trap in the global scope
SAFE_ID=$(echo "$1" | tr '/' '-')
LOCK_FILE="${LOCK_DIR}/${SAFE_ID}.lck"

# Pass all command-line arguments to the main function.
main "$@"
