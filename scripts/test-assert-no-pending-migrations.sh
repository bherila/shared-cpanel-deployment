#!/usr/bin/env bash
# Local harness for assert-no-pending-migrations.sh.
# shellcheck disable=SC2016,SC2034 # Checks are eval'd strings, including variables assigned by run().
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/assert-no-pending-migrations.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
deploy_home="$scratch/deploy-home"
php="$scratch/php"
mkdir -p "$deploy_home/app"
touch "$deploy_home/app/artisan"
fails=0

cat >"$php" <<'PHP'
#!/usr/bin/env bash
if [ "${1:-}" = -d ]; then
    [ "${2:-}" = memory_limit=1G ] || { echo "unexpected PHP option" >&2; exit 2; }
    shift 2
fi
if [ "$#" -ne 4 ] || [ "$1" != artisan ] || [ "$2" != migrate:status ] || [ "$3" != --pending ] || [ "$4" != --no-ansi ]; then
    echo "unexpected php arguments" >&2
    exit 2
fi
printf '%b' "${FAKE_MIGRATION_STATUS_OUTPUT:-INFO  Nothing to migrate.\\n}"
exit "${FAKE_MIGRATION_STATUS_EXIT:-0}"
PHP
chmod +x "$php"

run() {
    DEPLOY_HOME="$deploy_home" bash "$script" "$@" >"$scratch/out" 2>&1
}
check() {
    if eval "$2"; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        fails=$((fails + 1))
    fi
}

run app "$php" ''; status=$?
check "a fully migrated application passes" '[ "$status" -eq 0 ] && grep -Fq "No pending migrations remain." "$scratch/out"'

run app "$php" 1G; status=$?
check "an explicit memory limit is passed to PHP" '[ "$status" -eq 0 ]'

FAKE_MIGRATION_STATUS_OUTPUT='2026_09_15_000000_example ........ Pending\n' run app "$php" ''; status=$?
check "a pending migration fails and is shown" '[ "$status" -eq 1 ] && grep -Fq "Migrations remain pending" "$scratch/out" && grep -Fq "2026_09_15_000000_example" "$scratch/out"'

FAKE_MIGRATION_STATUS_OUTPUT='database unavailable\n' FAKE_MIGRATION_STATUS_EXIT=1 run app "$php" ''; status=$?
check "a status-command failure fails with context" '[ "$status" -eq 1 ] && grep -Fq "Could not read migration status" "$scratch/out"'

run '../app' "$php" ''; invalid_dir=$?
run app relative/php ''; relative_php=$?
run app "$php" 128MB; invalid_memory=$?
check "unsafe directories, PHP paths and memory limits are refused" '[ "$invalid_dir" -eq 2 ] && [ "$relative_php" -eq 2 ] && [ "$invalid_memory" -eq 2 ]'

rm "$deploy_home/app/artisan"
run app "$php" ''; missing_artisan=$?
check "a missing artisan file fails" '[ "$missing_artisan" -eq 1 ]'

echo "failures: $fails"
exit "$fails"
