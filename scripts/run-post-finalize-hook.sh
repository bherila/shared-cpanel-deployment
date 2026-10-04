#!/usr/bin/env bash
# Read-only hooks can retry an aborted writer's transient observation once.
set -euo pipefail
[[ $# -le 1 ]] || exit 2
budget=${1:-120}
[[ "$budget" =~ ^[1-9][0-9]{0,2}$ && "$budget" -le 120 ]] || exit 2
[ -f "$SCRIPT" ] || { echo '::error::post-finalize-script does not exist in the checkout.' >&2; exit 2; }
started=$SECONDS
remaining() {
    time_left=$((budget - (SECONDS - started)))
    [ "$time_left" -gt 0 ] || { echo '::error::Post-finalizer diagnostic exceeded its total deadline.' >&2; return 1; }
}
generation() {
    remaining || return 1
    local limit=$time_left
    [ "$limit" -le 60 ] || limit=60
    timeout --signal=TERM --kill-after=2s "${limit}s" ssh "$DEPLOY_SSH_TARGET" \
        "bash -s -- $(printf '%q ' "$DEPLOY_DIR" "$DEPLOY_PHP_BINARY" "$MEMORY_LIMIT" "$DEPLOY_RELEASE_ID" "$DEPLOY_SOURCE_COMMIT" "$PERSISTENT_PATHS" "$1")" \
        <"$GITHUB_ACTION_PATH/scripts/operational-audit.sh"
}
superseded() {
    echo 'Post-finalizer diagnostic superseded by a newer deployment.'
}
for ((attempt=0; attempt<2; attempt++)); do
    before=$(generation generation)
    case "$before" in
        'runtime-audit generation=superseded') superseded; exit 0 ;;
        'runtime-audit generation=current') ;;
        *) echo '::error::Post-finalizer generation proof rejected.' >&2; exit 1 ;;
    esac
    remaining
    status=0
    timeout --signal=TERM --kill-after=2s "${time_left}s" bash "$SCRIPT" || status=$?
    after=$(generation generation)
    case "$after" in
        'runtime-audit generation=superseded') superseded; exit 0 ;;
        'runtime-audit generation=current') ;;
        *) echo '::error::Post-finalizer generation proof rejected.' >&2; exit 1 ;;
    esac
    [ "$status" -ne 0 ] || exit 0
    [ "$attempt" -eq 0 ] || exit "$status"
    retry=$(generation generation-unlocked)
    case "$retry" in
        'runtime-audit generation=superseded') superseded; exit 0 ;;
        'runtime-audit generation=current lock=absent')
            echo 'Retrying the read-only post-finalizer diagnostic after a current, unlocked observation.' ;;
        'runtime-audit generation=current lock=present') exit "$status" ;;
        *) echo '::error::Post-finalizer unlocked generation proof rejected.' >&2; exit 1 ;;
    esac
done
