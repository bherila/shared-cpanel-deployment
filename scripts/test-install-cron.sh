#!/usr/bin/env bash
# Local harness for install-cron.sh: a fake `crontab` and `flock` on PATH, and a fake $HOME.
# Usage: test-install-cron.sh [scratch-root]   (defaults to mktemp; pass a directory that allows exec)
# shellcheck disable=SC2016,SC2034,SC2329 # Checks are eval'd strings; what they read looks unused.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/install-cron.sh"
scratch=${1:-}
fails=0
ORIGINAL_PATH=$PATH

setup() {
    if [ -n "$scratch" ]; then root=$(mktemp -d "$scratch/cron-test.XXXXXX"); else root=$(mktemp -d); fi
    export HOME="$root/home"; mkdir -p "$HOME" "$root/bin"
    export CRONTAB_FILE="$root/crontab" CRONTAB_MODE="${1:-normal}"
    cat >"$root/bin/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then
    if [ "$CRONTAB_MODE" = fail ]; then echo "crontab: cannot open spool" >&2; exit 1; fi
    [ -f "$CRONTAB_FILE" ] || { echo "no crontab for tester" >&2; exit 1; }
    cat "$CRONTAB_FILE"
else
    cp "$1" "$CRONTAB_FILE"
fi
SH
    printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/flock"
    chmod +x "$root/bin/crontab" "$root/bin/flock"
    export PATH="$root/bin:$ORIGINAL_PATH"
}

check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
backups() { find "$HOME/.crontab-backups" -type f 2>/dev/null | wc -l | tr -d ' '; }

SCHED='* * * * * cd "$HOME/app" && php -d memory_limit=1G artisan schedule:run > /dev/null 2>&1 # JOB:app-scheduler'
WORKER='* * * * * cd "$HOME/app" && php -d memory_limit=1G artisan queue:work > /dev/null 2>&1 # JOB:app-queue-worker'

# 1. An account with no crontab gets exactly the desired lines.
setup
bash "$script" app "$SCHED" "$WORKER" >/dev/null
check "an empty crontab gets the desired lines" '[ "$(cat "$CRONTAB_FILE")" = "$(printf "%s\n%s" "$SCHED" "$WORKER")" ]'

# 2. A failed read never writes.
setup fail
printf 'MAILTO=""\nother line # JOB:other-x\n' >"$CRONTAB_FILE"; before=$(cat "$CRONTAB_FILE")
bash "$script" app "$SCHED" >/dev/null 2>&1; status=$?
check "a failed crontab -l exits non-zero" '[ "$status" -ne 0 ]'
check "a failed crontab -l leaves the crontab untouched" '[ "$(cat "$CRONTAB_FILE")" = "$before" ]'
check "a failed crontab -l takes no backup" '[ "$(backups)" = 0 ]'

# 3. This application's lines are replaced — legacy untagged, tagged with an old limit, a renamed job,
#    a stray copy of a desired job id — and every other line is kept, in order, including a directory
#    and a tag that merely share this application's name as a prefix.
setup
cat >"$CRONTAB_FILE" <<EOF
MAILTO=""
SHELL="/bin/bash"
* * * * * cd "\$HOME/app" && php artisan schedule:run > /dev/null 2>&1
* * * * * cd /elsewhere/app-two && php artisan schedule:run # JOB:app-two-scheduler
* * * * * cd $HOME/app-laravel && php artisan schedule:run
* * * * * cd $HOME/app && php -d memory_limit=512M artisan queue:work # JOB:app-queue-worker
* * * * * cd "\$HOME/app" && php artisan old:job # JOB:app-old-job
* * * * * cd /somewhere/else && php artisan schedule:run # JOB:app-scheduler
* * * * * cd "\$HOME/svc" && php artisan schedule:run
EOF
bash "$script" app "$SCHED" "$WORKER" >/dev/null
expected=$(printf '%s\n' 'MAILTO=""' 'SHELL="/bin/bash"' \
    '* * * * * cd /elsewhere/app-two && php artisan schedule:run # JOB:app-two-scheduler' \
    "* * * * * cd $HOME/app-laravel && php artisan schedule:run" \
    '* * * * * cd "$HOME/svc" && php artisan schedule:run' "$SCHED" "$WORKER")
check "owned lines are replaced and every other line is kept" '[ "$(cat "$CRONTAB_FILE")" = "$expected" ]'
check "the previous crontab is backed up" '[ "$(backups)" = 1 ]'

# 4. Running again changes nothing and takes no new backup.
bash "$script" app "$SCHED" "$WORKER" | grep -q 'unchanged'; again=$?
check "a second run reports unchanged" '[ "$again" -eq 0 ]'
check "a second run takes no backup" '[ "$(backups)" = 1 ]'
check "a second run leaves the same crontab" '[ "$(cat "$CRONTAB_FILE")" = "$expected" ]'

# 5. Malformed desired lines are refused before anything is read or written.
setup
printf 'keep me\n' >"$CRONTAB_FILE"
bash "$script" app '* * * * * cd "$HOME/app" && php artisan schedule:run' >/dev/null 2>&1; untagged=$?
bash "$script" app '* * * * * cd "$HOME/other" && php artisan schedule:run # JOB:app-scheduler' >/dev/null 2>&1; elsewhere=$?
bash "$script" 'app/../x' "$SCHED" >/dev/null 2>&1; traversal=$?
check "a desired line without a job id is refused" '[ "$untagged" -eq 2 ]'
check "a desired line running from another directory is refused" '[ "$elsewhere" -eq 2 ]'
check "an application directory that is not a plain name is refused" '[ "$traversal" -eq 2 ]'
check "refusals leave the crontab untouched" '[ "$(cat "$CRONTAB_FILE")" = "keep me" ]'

# 6. Quoting survives the hop the workflow uses (printf %q, then bash -s).
setup
quoted=$(printf '%q ' app "$SCHED")
bash -c "bash -s -- $quoted" <"$script" >/dev/null
check "lines passed through printf %q and bash -s arrive intact" '[ "$(cat "$CRONTAB_FILE")" = "$SCHED" ]'

echo "failures: $fails"
exit "$fails"
