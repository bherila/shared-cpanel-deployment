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
ssh "$TARGET" "bash -s -- $(printf '%q ' "$CANDIDATE_DIR" "$PHP_BINARY" "$STABLE_DIR")" <"$SCRIPT"
