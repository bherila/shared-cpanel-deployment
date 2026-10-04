#!/usr/bin/env bash
# Synthetic writer transitions; execute the real metadata proof without SSH.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
task_home="$scratch/home"
control="$task_home/.deployments/app"
mkdir -p "$control" "$scratch/bin"
export FIXTURE_HOME="$task_home" CONTROL="$control" TRACE_ROOT="$scratch"
export SCRIPT="$scratch/hook" GITHUB_ACTION_PATH="$(dirname "$here")"
export DEPLOY_SSH_TARGET=fixture DEPLOY_DIR=app DEPLOY_RELEASE_ID=fixture
export DEPLOY_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export PERSISTENT_PATHS=storage MEMORY_LIMIT=256M
DEPLOY_PHP_BINARY=$(command -v php)
export DEPLOY_PHP_BINARY
cat > "$scratch/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == fixture && $# == 2 ]] || exit 2
calls=0
[[ ! -f "$TRACE_ROOT/probe-calls" ]] || calls=$(<"$TRACE_ROOT/probe-calls")
calls=$((calls + 1))
printf '%s\n' "$calls" > "$TRACE_ROOT/probe-calls"
case "$SCENARIO:$calls" in
    before-superseded:1|after-superseded:2|retry-superseded:3|next-superseded:4)
        printf 'newer\n' > "$CONTROL/generation" ;;
    aborted:2)
        rm "$CONTROL/deploy.lock/owner"
        rmdir "$CONTROL/deploy.lock" ;;
    malformed:1) echo 'invalid generation output'; exit 0 ;;
esac
env HOME="$FIXTURE_HOME" bash -c "$2"
case "$SCENARIO:$calls" in
    aborted:1|held:1)
        mkdir "$CONTROL/deploy.lock"
        if [[ "$SCENARIO" == aborted ]]; then owner=newer; else owner=fixture; fi
        printf '%s\n' "$owner" > "$CONTROL/deploy.lock/owner" ;;
esac
SSH
cat > "$scratch/hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
calls=0
[[ ! -f "$TRACE_ROOT/hook-calls" ]] || calls=$(<"$TRACE_ROOT/hook-calls")
printf '%s\n' "$((calls + 1))" > "$TRACE_ROOT/hook-calls"
case "$SCENARIO" in
    success) exit 0 ;;
    aborted) [[ ! -e "$CONTROL/deploy.lock" ]] ;;
    deadline) sleep 1.2; exit 7 ;;
    *) exit 7 ;;
esac
HOOK
chmod +x "$scratch/bin/ssh" "$scratch/hook"
export PATH="$scratch/bin:$PATH"
reset_fixture() {
    rm -f "$scratch/probe-calls" "$scratch/hook-calls"
    rm -rf "$control/deploy.lock"
    printf 'fixture\n' > "$control/generation"
    export SCENARIO=$1
}
hook_calls() {
    if [[ -f "$scratch/hook-calls" ]]; then cat "$scratch/hook-calls"; else echo 0; fi
}
run_hook() {
    bash "${POST_FINALIZE_HOOK_TEST_RUNNER:-$here/run-post-finalize-hook.sh}" "$@" > "$scratch/output" 2>&1
}
reset_fixture success
before=$(find "$task_home" -type f -exec sha256sum {} + | sort)
run_hook
[[ $(hook_calls) == 1 ]]
[[ "$(find "$task_home" -type f -exec sha256sum {} + | sort)" == "$before" ]]

reset_fixture aborted
run_hook
[[ $(hook_calls) == 2 && ! -e "$control/deploy.lock" ]]
grep -Fq 'Retrying the read-only' "$scratch/output"
[[ "$(cat "$control/generation")" == fixture ]]

for scenario in persistent held; do
    reset_fixture "$scenario"
    if run_hook; then echo 'failing hook was accepted' >&2; exit 1; else [[ $? == 7 ]]; fi
    if [[ "$scenario" == persistent ]]; then [[ $(hook_calls) == 2 ]]; else [[ $(hook_calls) == 1 ]]; fi
done
for scenario in before-superseded after-superseded retry-superseded next-superseded; do
    reset_fixture "$scenario"
    run_hook
    grep -Fq 'superseded by a newer deployment' "$scratch/output"
    if [[ "$scenario" == before-superseded ]]; then [[ $(hook_calls) == 0 ]]; else [[ $(hook_calls) == 1 ]]; fi
    # Any observed supersession must be terminal, even if a later probe could
    # return current again. No hook or probe is allowed after that observation.
    case "$scenario" in
        before-superseded) expected_probes=1 ;;
        after-superseded) expected_probes=2 ;;
        retry-superseded) expected_probes=3 ;;
        next-superseded) expected_probes=4 ;;
    esac
    [[ "$(cat "$scratch/probe-calls")" == "$expected_probes" ]]
done
reset_fixture malformed
if run_hook; then exit 1; fi
[[ $(hook_calls) == 0 ]]
grep -Fq 'generation proof rejected' "$scratch/output"

reset_fixture deadline
started=$(date +%s)
if run_hook 2; then echo 'deadline was ignored' >&2; exit 1; fi
[[ $(( $(date +%s) - started )) -le 5 && $(hook_calls) -le 2 ]]
grep -Fq 'total deadline' "$scratch/output"
echo 'Post-finalizer retry, held lock, terminal supersession, failure, deadline and read-only fixtures passed.'
