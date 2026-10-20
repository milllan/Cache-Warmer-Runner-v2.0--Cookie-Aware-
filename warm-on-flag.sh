#!/bin/bash
# Warm-on-flag trigger v1.0.0
# Runs cache-warmer.sh when a site has dropped a flag file after a cache purge
# (e.g. a WordPress mu-plugin that touches
# wp-content/<name>.flag on every response carrying X-LiteSpeed-Purge: public).
#
# Meant to be called from cron every 1-2 minutes:
#   */2 * * * * /path/warm-on-flag.sh <flag_file> <domain> <sitemap_path> [settle_seconds] [origin_ip]
#
# - Waits until the flag is at least settle_seconds old (default 60), so a burst
#   of saves is warmed once, after the purges have landed.
# - Leaves the flag in place while a warm for the domain is already running;
#   the next tick picks it up after that run.
# - Deletes the flag BEFORE warming, so a purge during the run re-arms the next one.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <flag_file> <domain> <sitemap_path> [settle_seconds] [origin_ip]" >&2
    exit 1
fi

FLAG_FILE=$1
DOMAIN=$2
SITEMAP_PATH=$3
SETTLE=${4:-60}
ORIGIN_IP=${5:-}

[[ -f "$FLAG_FILE" ]] || exit 0

age=$(( $(date +%s) - $(stat -c %Y -- "$FLAG_FILE") ))
(( age >= SETTLE )) || exit 0

# Same lock file name cache-warmer.sh derives for this domain.
LOCK_FILE="$SCRIPT_DIR/run/$(echo "$DOMAIN" | tr '/' '-').lck"
mkdir -p "$SCRIPT_DIR/run"
if [[ -f "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" true; then
    exit 0
fi

rm -f -- "$FLAG_FILE"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$DOMAIN] Purge flag ${age}s old: starting warm." >&2
exec "$SCRIPT_DIR/cache-warmer.sh" "$DOMAIN" "$SITEMAP_PATH" "" "$ORIGIN_IP"
