#!/usr/bin/env bash
# Local harness for ensure-passport-keys.sh.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329 # Checks are eval'd strings; functions and setup values are used there.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/ensure-passport-keys.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

setup() {
    root=$(mktemp -d "$scratch/case.XXXXXX")
    export HOME="$root/home"
    app="$HOME/example-laravel"
    keys="$app/storage/app/private/oauth"
    php="$root/fake-php"
    mkdir -p "$app"
    : >"$app/artisan"
    cat >"$php" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PASSPORT_LOG"
if [ "$*" = 'artisan passport:keys --force' ]; then
    mkdir -p storage/app/private/oauth
    printf private > storage/app/private/oauth/oauth-private.key
    printf public > storage/app/private/oauth/oauth-public.key
fi
SH
    chmod +x "$php"
    export PASSPORT_LOG="$root/passport.log"
    : >"$PASSPORT_LOG"
}

run() { bash "$script" "$@" >"$root/out" 2>&1; }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
calls() { wc -l <"$PASSPORT_LOG" | tr -d ' '; }

setup
run example-laravel "$php" storage/app/private/oauth; status=$?
check "an absent pair is created once" '[ "$status" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ -s "$keys/oauth-private.key" ] && [ -s "$keys/oauth-public.key" ]'
run example-laravel "$php" storage/app/private/oauth; status=$?
check "a complete pair is preserved" '[ "$status" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ -n "$(find "$keys/oauth-private.key" -perm 600 -print)" ]'

setup
mkdir -p "$keys"
printf private >"$keys/oauth-private.key"
run example-laravel "$php" storage/app/private/oauth; status=$?
check "a partial pair fails without rotation" '[ "$status" -eq 1 ] && [ "$(calls)" -eq 0 ] && [ -s "$keys/oauth-private.key" ] && [ ! -e "$keys/oauth-public.key" ]'

setup
mkdir -p "$app/storage/app/private"
outside="$root/outside"
mkdir -p "$outside"
ln -s "$outside" "$keys"
run example-laravel "$php" storage/app/private/oauth; status=$?
check "a symlinked key path is refused" '[ "$status" -eq 1 ] && [ "$(calls)" -eq 0 ]'

setup
run example-laravel relative/php storage/app/private/oauth; relative_php=$?
run example-laravel "$php" ../outside; unsafe_path=$?
check "relative PHP and unsafe key paths are refused" '[ "$relative_php" -eq 2 ] && [ "$unsafe_path" -eq 2 ]'

setup
managed="$HOME/.deployments/example-laravel/releases/release-1"
shared="$HOME/.deployments/example-laravel/shared"
mkdir -p "$managed" "$shared/storage"
: >"$managed/artisan"
ln -s "$shared/storage" "$managed/storage"
keys="$shared/storage/app/private/oauth"
run .deployments/example-laravel/releases/release-1 "$php" storage/app/private/oauth .deployments/example-laravel/shared; status=$?
check "an atomic candidate may traverse only its declared shared root" \
    '[ "$status" -eq 0 ] && [ -s "$keys/oauth-private.key" ] && [ -s "$keys/oauth-public.key" ]'

echo "failures: $fails"
exit "$fails"
