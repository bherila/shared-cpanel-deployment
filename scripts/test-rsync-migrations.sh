#!/usr/bin/env bash
# Local harness for rsync-migrations.sh.
# shellcheck disable=SC2016,SC2034,SC2329 # Checks are eval'd strings; functions and setup values are used there.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/rsync-migrations.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
original_path=$PATH
fails=0

setup() {
    root=$(mktemp -d "$scratch/case.XXXXXX")
    mkdir -p "$root/bin" "$root/checkout/database/migrations"
    export FAKE_REMOTE_STATE=${1-app} RSYNC_LOG="$root/rsync.log" SSH_LOG="$root/ssh.log"
    cat >"$root/bin/ssh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$@" >"$SSH_LOG"
printf '%s\n' "$FAKE_REMOTE_STATE"
SH
    cat >"$root/bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$RSYNC_LOG"
SH
    chmod +x "$root/bin/ssh" "$root/bin/rsync"
    export PATH="$root/bin:$original_path"
    export DEPLOY_TARGET=cpanel-deploy DEPLOY_DIR=example-laravel
    unset DEPLOY_MIGRATIONS_PATH
}

run() { (cd "$root/checkout" && bash "$script" >"$root/out" 2>&1); }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
synced() { [ -f "$RSYNC_LOG" ]; }
has_arg() { grep -Fqx -- "$1" "$RSYNC_LOG"; }

for bad in '' . .. .config public_html 'app/../x' 'a b'; do
    setup
    DEPLOY_DIR=$bad run; status=$?
    check "deploy dir '$bad' is refused" '[ "$status" -eq 2 ] && ! synced'
done

for bad in /etc ../outside 'database/../outside' -rf missing; do
    setup
    DEPLOY_MIGRATIONS_PATH=$bad run; status=$?
    check "migrations path '$bad' is refused" '[ "$status" -eq 2 ] && ! synced'
done

for state in absent symlink not-an-app migration-alias no-migration-dir ''; do
    setup "$state"
    run; status=$?
    check "remote state '$state' is refused" '[ "$status" -eq 1 ] && ! synced'
done

setup app
run; status=$?
check "an existing application accepts candidate migrations" '[ "$status" -eq 0 ] && synced'
check "migration upload never uses --delete" '! has_arg --delete'
check "only migration contents are uploaded" 'has_arg "database/migrations/" && has_arg "cpanel-deploy:~/example-laravel/database/migrations/"'

echo "failures: $fails"
exit "$fails"
