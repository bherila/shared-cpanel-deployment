#!/usr/bin/env bash
# Local harness for remote-artisan.sh.
# shellcheck disable=SC2016,SC2034 # Checks are eval'd strings and use variables assigned by run().
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/remote-artisan.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home"
app="$HOME/example-laravel"
php="$scratch/php"
log="$scratch/php.log"
mkdir -p "$app"
touch "$app/artisan"
fails=0

cat >"$php" <<'PHP'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PHP_LOG"
PHP
chmod +x "$php"
export PHP_LOG="$log"

run() { bash "$script" "$@" >"$scratch/out" 2>&1; }
check() {
    if eval "$2"; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        fails=$((fails + 1))
    fi
}

run example-laravel "$php" 1G 'config:clear' 'example:import --strict'; status=$?
check "commands receive the requested memory limit" \
    '[ "$status" -eq 0 ] && grep -Fqx -- "-d memory_limit=1G artisan config:clear" "$log" && grep -Fqx -- "-d memory_limit=1G artisan example:import --strict" "$log"'

: >"$log"
run example-laravel "$php" '' 'config:cache'; status=$?
check "an empty limit uses the PHP default" \
    '[ "$status" -eq 0 ] && grep -Fqx -- "artisan config:cache" "$log"'

run example-laravel "$php" 128MB 'config:cache'; invalid_memory=$?
run '../app' "$php" 1G 'config:cache'; invalid_dir=$?
check "unsafe memory limits and application paths are refused" \
    '[ "$invalid_memory" -eq 2 ] && [ "$invalid_dir" -eq 2 ]'

managed="$HOME/.deployments/example-laravel/releases/release-1"
mkdir -p "$managed"
: >"$managed/artisan"
: >"$log"
run .deployments/example-laravel/releases/release-1 "$php" 1G 'config:cache'; status=$?
check "commands run against a managed atomic candidate" \
    '[ "$status" -eq 0 ] && grep -Fqx -- "-d memory_limit=1G artisan config:cache" "$log"'

echo "failures: $fails"
exit "$fails"
