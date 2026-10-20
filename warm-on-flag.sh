#!/bin/bash
# Warm-on-flag trigger v1.2.0
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
# - Deletes the flag BEFORE warming, so a purge during the run re-arms the next one,
#   and puts it back if the warm did not run (warmer failed, or lost the lock race
#   to another warm), so the next tick retries instead of the purge being forgotten.
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

# The flag can vanish between the test and stat (a concurrent tick): nothing to do then.
mtime=$(stat -c %Y -- "$FLAG_FILE" 2>/dev/null) || exit 0
age=$(( $(date +%s) - mtime ))
(( age >= SETTLE )) || exit 0

# Same lock file name cache-warmer.sh derives for this domain.
LOCK_FILE="$SCRIPT_DIR/run/$(echo "$DOMAIN" | tr '/' '-').lck"
mkdir -p "$SCRIPT_DIR/run"
if [[ -f "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" true; then
    exit 0
fi

rm -f -- "$FLAG_FILE"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$DOMAIN] Purge flag ${age}s old: starting warm." >&2
rc=0
# 75 (EX_TEMPFAIL) = another warm holds the lock: re-arm and let it finish first.
CACHE_WARMER_BUSY_EXIT=75 bash "$SCRIPT_DIR/cache-warmer.sh" "$DOMAIN" "$SITEMAP_PATH" "" "$ORIGIN_IP" || rc=$?
# Re-arm only when nothing useful ran. 3 = partial warm (some child sitemaps
# unreadable, the rest warmed): re-arming that would re-warm the whole site every
# tick for as long as a sitemap stays broken.
if (( rc != 0 && rc != 3 )); then
    [[ -e "$FLAG_FILE" ]] || : > "$FLAG_FILE"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$DOMAIN] Warm did not complete (exit $rc): flag re-armed." >&2
elif (( rc == 3 )); then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$DOMAIN] Partial warm (exit 3): not re-armed." >&2
fi
exit "$rc"
