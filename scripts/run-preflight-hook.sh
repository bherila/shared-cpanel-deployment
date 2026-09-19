#!/usr/bin/env bash
# Runner-side dispatch for the optional read-only atomic application preflight.
set -euo pipefail

: "${TARGET:?}"
: "${CANDIDATE_DIR:?}"
: "${PHP_BINARY:?}"
: "${STABLE_DIR:?}"
: "${SCRIPT:?}"

[ -f "$SCRIPT" ] || {
    echo '::error::preflight-script does not exist in the checkout.' >&2
    exit 2
}
# Arguments intentionally expand on the runner and are escaped for remote Bash.
# shellcheck disable=SC2029
ssh "$TARGET" "bash -s -- $(printf '%q ' "$CANDIDATE_DIR" "$PHP_BINARY" "$STABLE_DIR")" <"$SCRIPT"
