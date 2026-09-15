#!/usr/bin/env bash
# Local harness for rsync-deploy.sh: fake `ssh` and `rsync` on PATH that record what they were asked.
# Usage: test-rsync-deploy.sh [scratch-root]   (defaults to mktemp; pass a directory that allows exec)
# shellcheck disable=SC2016,SC2034,SC2329 # Checks are eval'd strings; what they read looks unused.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/rsync-deploy.sh"
scratch=${1:-}
fails=0
ORIGINAL_PATH=$PATH

setup() {
    if [ -n "$scratch" ]; then root=$(mktemp -d "$scratch/rsync-test.XXXXXX"); else root=$(mktemp -d); fi
    mkdir -p "$root/bin" "$root/checkout/app" "$root/checkout/storage" "$root/checkout/public"
    : >"$root/checkout/artisan"
    export FAKE_REMOTE_STATE="${1-app}" RSYNC_LOG="$root/rsync.log" SSH_LOG="$root/ssh.log"
    cat >"$root/bin/ssh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$@" >>"$SSH_LOG"
echo "$FAKE_REMOTE_STATE"
SH
    cat >"$root/bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$RSYNC_LOG"
SH
    chmod +x "$root/bin/ssh" "$root/bin/rsync"
    export PATH="$root/bin:$ORIGINAL_PATH"
    export DEPLOY_TARGET=cpanel-deploy DEPLOY_DIR=app-laravel DEPLOY_EXCLUDES='' DEPLOY_MARKER=''
    export DEPLOY_KEEP_RUNTIME_STORAGE=true
    export DEPLOY_PATHS=$'app\nstorage\n  public  \n\nartisan'
}

run() { (cd "$root/checkout" && bash "$script" >/dev/null 2>&1); }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
synced() { [ -f "$RSYNC_LOG" ]; }
has_arg() { grep -Fqx -- "$1" "$RSYNC_LOG"; }

# 1. Destinations that could reach the account home, a webroot or another tree are refused before ssh.
for bad in '' . .. .config public_html 'app/../x' 'a b' '~'; do
    setup
    DEPLOY_DIR=$bad run; status=$?
    check "deploy dir '$bad' is refused" '[ "$status" -eq 2 ] && ! synced && [ ! -f "$SSH_LOG" ]'
done

# 2. Upload paths must be relative, inside the checkout, and present.
for bad in /etc ../outside 'app/../..' -rf missing; do
    setup
    DEPLOY_PATHS=$bad run; status=$?
    check "upload path '$bad' is refused" '[ "$status" -eq 2 ] && ! synced'
done
setup
DEPLOY_PATHS=$'\n  \n' run; status=$?
check "no upload paths is refused" '[ "$status" -eq 2 ] && ! synced'

# 3. A destination that is not absent, empty or marked is never synced.
for state in other symlink not-a-directory ''; do
    setup "$state"
    run; status=$?
    check "remote state '$state' is refused" '[ "$status" -eq 1 ] && ! synced'
done

# 4. A marked destination is synced with --delete, .env and runtime storage kept, extras added.
setup app
DEPLOY_EXCLUDES=$'svc-blobs\n/storage/app/private/oauth/' run; status=$?
check "a marked destination deploys" '[ "$status" -eq 0 ] && synced'
check "--delete is passed" 'has_arg --delete'
check ".env is excluded" 'has_arg --exclude=.env'
check "runtime storage is excluded" 'has_arg "--exclude=/storage/logs/*" && has_arg "--exclude=/storage/app/*"'
check "extra excludes are passed" 'has_arg --exclude=svc-blobs && has_arg --exclude=/storage/app/private/oauth/'
check "paths are trimmed and blank lines skipped" 'has_arg public && ! grep -q "^  public" "$RSYNC_LOG"'
check "the destination is the application directory" 'has_arg "cpanel-deploy:~/app-laravel/"'

# 5. Absent and empty destinations are allowed, so a first deploy works.
for state in absent empty; do
    setup "$state"
    run; status=$?
    check "remote state '$state' deploys" '[ "$status" -eq 0 ] && synced'
done

# 6. Turning off runtime storage keeps .env excluded regardless.
setup app
DEPLOY_KEEP_RUNTIME_STORAGE=false run; status=$?
check "without runtime storage .env is still excluded" '[ "$status" -eq 0 ] && has_arg --exclude=.env && ! has_arg "--exclude=/storage/logs/*"'
setup app
DEPLOY_KEEP_RUNTIME_STORAGE=yes run; status=$?
check "an invalid keep-runtime-storage value is refused" '[ "$status" -eq 2 ] && ! synced'

echo "failures: $fails"
exit "$fails"
