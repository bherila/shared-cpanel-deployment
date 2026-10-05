#!/usr/bin/env bash
# Static contract for the composite action's post-deploy checks (a subset of main's contract test).
# shellcheck disable=SC2016
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
action="$here/action.yml"
fails=0

check() {
    local name=$1
    shift
    if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails + 1)); fi
}

# 2026-10-05: a proxy rule challenging the runner's location answered the health check and the
# PHP probe with its own HTML 200. Both now ask the host's own web server, and health needs text.
health_expect_default=$(awk '$1 == "health-expect:" { found=1 } found && $1 == "default:" { $1=""; sub(/^ /, ""); print; exit }' "$action")
check "health requires Laravel's /up text by default" test "$health_expect_default" = 'Application up'
check "the health check is fetched from the origin, not through the proxy" grep -Fq 'scripts/origin-fetch.sh" >"$raw"' "$action"
check "the health check no longer curls the public URL from the runner" bash -c '! grep -Fq -- "\"\${SITE_URL%/}\$HEALTH_PATH\"" "$1"' _ "$action"
check "the health text is matched in a file, not at the end of a pipe" grep -Fq 'grep -Fq -- "$HEALTH_EXPECT" "$body"' "$action"
check "the web PHP probe is fetched from the origin" grep -Fq 'origin-fetch.sh' "$here/scripts/verify-web-php.sh"
echo "failures: $fails"
exit "$fails"
