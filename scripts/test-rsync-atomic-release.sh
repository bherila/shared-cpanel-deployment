#!/usr/bin/env bash
# Local harness for candidate-release upload guards.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/rsync-atomic-release.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
original_path=$PATH
fails=0

setup() {
    root=$(mktemp -d "$scratch/case.XXXXXX")
    mkdir -p "$root/bin" "$root/checkout/app" "$root/checkout/storage"
    : >"$root/checkout/artisan"
    export REMOTE_STATE=${1:-ready} RSYNC_LOG="$root/rsync.log"
    cat >"$root/bin/ssh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "$REMOTE_STATE"
SH
    cat >"$root/bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$RSYNC_LOG"
SH
    chmod +x "$root/bin/ssh" "$root/bin/rsync"
    export PATH="$root/bin:$original_path"
    export DEPLOY_TARGET=cpanel-deploy DEPLOY_DIR=app DEPLOY_RELEASE_ID=abc-123
    export DEPLOY_PATHS=$'app\nstorage\nartisan' DEPLOY_EXCLUDES=''
}

run() { (cd "$root/checkout" && bash "$script" >/dev/null 2>&1); }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }

setup
run; status=$?
check "a lock-owned empty candidate uploads" '[ "$status" -eq 0 ] && [ -f "$RSYNC_LOG" ]'
check "upload targets only the managed candidate" 'grep -Fqx "cpanel-deploy:~/.deployments/app/releases/abc-123/" "$RSYNC_LOG"'
check "release metadata and environment are preserved" 'grep -Fqx -- "--exclude=.env" "$RSYNC_LOG" && grep -Fqx -- "--exclude=.deploy-release" "$RSYNC_LOG"'
check "candidate upload uses guarded deletion" 'grep -Fqx -- "--delete" "$RSYNC_LOG"'

for state in no-lock invalid-candidate nonempty; do
    setup "$state"
    run; status=$?
    check "remote state '$state' is refused" '[ "$status" -ne 0 ] && [ ! -f "$RSYNC_LOG" ]'
done

for bad in '' . '../x' 'bad/name'; do
    setup
    DEPLOY_RELEASE_ID=$bad run; status=$?
    check "release id '$bad' is refused" '[ "$status" -eq 2 ] && [ ! -f "$RSYNC_LOG" ]'
done

echo "failures: $fails"
exit "$fails"
