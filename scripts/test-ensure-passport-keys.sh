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
if [ "${1:-}" = -d ]; then
    printf '%s\n' "$2" >"$PASSPORT_MEMORY_LOG"
    shift 2
fi
if [ "$*" = 'artisan passport:keys --force' ]; then
    mkdir -p storage/app/private/oauth
    printf private > storage/app/private/oauth/oauth-private.key
    printf public > storage/app/private/oauth/oauth-public.key
fi
SH
    chmod +x "$php"
    export PASSPORT_MEMORY_LOG="$root/memory.log"
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

for memory_limit in 1G 256M 512k -1; do
    setup
    run example-laravel "$php" storage/app/private/oauth '' "$memory_limit"; status=$?
    check "Passport receives memory limit $memory_limit as one PHP argument" \
        '[ "$status" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ "$(cat "$PASSPORT_MEMORY_LOG")" = "memory_limit=$memory_limit" ] && grep -Fxq -- "-d memory_limit=$memory_limit artisan passport:keys --force" "$PASSPORT_LOG"'
done
setup
run example-laravel "$php" storage/app/private/oauth '' ''; status=$?
check "an explicit empty limit preserves the host default" \
    '[ "$status" -eq 0 ] && [ ! -e "$PASSPORT_MEMORY_LOG" ] && grep -Fxq "artisan passport:keys --force" "$PASSPORT_LOG"'
for memory_limit in '1G -d auto_prepend_file=bad' '0M' '1;touch bad' '1G'$'\n''-d bad' '--help'; do
    setup
    run example-laravel "$php" storage/app/private/oauth '' "$memory_limit"; status=$?
    check "an invalid Passport limit is rejected before PHP or key-directory writes" \
        '[ "$status" -eq 2 ] && [ "$(calls)" -eq 0 ] && [ ! -e "$keys" ]'
done
setup
managed="$HOME/.deployments/example-laravel/releases/release-2"
shared="$HOME/.deployments/example-laravel/shared"
mkdir -p "$managed" "$shared/storage"
: >"$managed/artisan"
ln -s "$shared/storage" "$managed/storage"
keys="$shared/storage/app/private/oauth"
run .deployments/example-laravel/releases/release-2 "$php" storage/app/private/oauth .deployments/example-laravel/shared 1G; status=$?
check "an atomic candidate forwards the limit while preserving its shared key-root guard" \
    '[ "$status" -eq 0 ] && [ "$(cat "$PASSPORT_MEMORY_LOG")" = memory_limit=1G ] && [ -s "$keys/oauth-private.key" ] && [ -s "$keys/oauth-public.key" ]'
run .deployments/example-laravel/releases/release-2 "$php" storage/app/private/oauth .deployments/example-laravel/shared 2G; status=$?
check "a complete shared pair stays unchanged when the memory limit changes" \
    '[ "$status" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ "$(cat "$keys/oauth-private.key")" = private ] && [ "$(cat "$keys/oauth-public.key")" = public ]'

# Execute each actual composite transport body, with only SSH replaced by local Bash.
for phase in before-upload after-upload atomic; do
    for memory_limit in '' 1G; do
        setup
        step='Ensure Passport signing keys'
        export DEPLOY_DIR=example-laravel SHARED_ROOT=''
        if [ "$phase" = before-upload ]; then
            step='Ensure Passport signing keys before application upload'
        elif [ "$phase" = atomic ]; then
            export DEPLOY_DIR=.deployments/example-laravel/releases/release-3
            export SHARED_ROOT=.deployments/example-laravel/shared
            mkdir -p "$HOME/$DEPLOY_DIR" "$HOME/$SHARED_ROOT/storage"
            : >"$HOME/$DEPLOY_DIR/artisan"
            ln -s "$HOME/$SHARED_ROOT/storage" "$HOME/$DEPLOY_DIR/storage"
            keys="$HOME/$SHARED_ROOT/storage/app/private/oauth"
        fi
        if ! python3 - "$here/../action.yml" "$root/step.sh" "$step" <<'PYTHON'
import re
import sys
from pathlib import Path
blocks = re.split(r'(?=^    - (?:name|id):)', Path(sys.argv[1]).read_text(), flags=re.M)
block = next(block for block in blocks if f'    - name: {sys.argv[3]}\n' in block)
assert '        ARTISAN_MEMORY_LIMIT: ${{ inputs.artisan-memory-limit }}\n' in block
body = block.split('      run: |\n', 1)[1]
Path(sys.argv[2]).write_text('\n'.join(line[8:] for line in body.splitlines()))
PYTHON
        then
            echo "FAIL - could not extract the actual Passport step"
            fails=$((fails + 1))
            continue
        fi
        mkdir "$root/bin"
        cat >"$root/bin/ssh" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 2 ] && [ "$1" = fixture ] || exit 2
exec bash -c "$2"
SH
        chmod +x "$root/bin/ssh"
        export TARGET=fixture PHP_BINARY="$php" KEY_DIRECTORY=storage/app/private/oauth
        export ARTISAN_MEMORY_LIMIT="$memory_limit" GITHUB_ACTION_PATH="$here/.."
        PATH="$root/bin:$PATH" bash "$root/step.sh" >"$root/out" 2>&1; status=$?
        check "the actual $phase transport preserves limit '${memory_limit:-host-default}' and creates the guarded pair" \
            '[ "$status" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ -s "$keys/oauth-private.key" ] && [ -s "$keys/oauth-public.key" ] && { if [ -n "$memory_limit" ]; then [ "$(cat "$PASSPORT_MEMORY_LOG")" = "memory_limit=$memory_limit" ]; else [ ! -e "$PASSPORT_MEMORY_LOG" ]; fi; }'
    done
done

echo "failures: $fails"
exit "$fails"
