#!/usr/bin/env bash
# Local harness for install-branding.sh.
# shellcheck disable=SC2016,SC2034 # Checks are eval'd strings; setup values are used there.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/install-branding.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

setup() {
    root=$(mktemp -d "$scratch/case.XXXXXX")
    export HOME="$root/home"
    app="$HOME/example-laravel"
    source="$HOME/.config/example/branding"
    destination="$app/public/branding"
    mkdir -p "$app/public" "$source"
    printf light >"$source/logo-light.svg"
    printf dark >"$source/logo-dark.svg"
    printf icon >"$source/favicon.ico"
    printf theme >"$source/theme.css"
}

run() { bash "$script" "$@" >"$root/out" 2>&1; }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }

setup
run example-laravel .config/example/branding logo-light.svg logo-dark.svg favicon.ico theme.css; status=$?
check "approved private branding files are installed" '[ "$status" -eq 0 ] && [ "$(cat "$destination/theme.css")" = theme ] && [ -n "$(find "$destination/theme.css" -perm 644 -print)" ]'
printf updated >"$source/theme.css"
run example-laravel .config/example/branding logo-light.svg logo-dark.svg favicon.ico theme.css; status=$?
check "a later deploy atomically updates configured files" '[ "$status" -eq 0 ] && [ "$(cat "$destination/theme.css")" = updated ] && ! find "$destination" -name ".deploy-*" | grep -q .'

setup
printf sentinel >"$app/public/sentinel"
rm "$source/favicon.ico"
run example-laravel .config/example/branding logo-light.svg logo-dark.svg favicon.ico theme.css; status=$?
check "a missing source fails before destination creation" '[ "$status" -eq 1 ] && [ ! -e "$destination" ] && [ -f "$app/public/sentinel" ]'

setup
private="$HOME/.config/private-branding"
mv "$source" "$private"
ln -s "$private" "$source"
run example-laravel .config/example/branding logo-light.svg; alias_status=$?
check "a source path alias is refused" '[ "$alias_status" -eq 1 ] && [ ! -e "$destination" ]'

setup
run example-laravel /tmp/branding logo-light.svg; absolute_source=$?
run example-laravel .config/example/branding ../logo-light.svg; unsafe_file=$?
check "sources outside .config and unsafe file names are refused" '[ "$absolute_source" -eq 2 ] && [ "$unsafe_file" -eq 2 ]'

echo "failures: $fails"
exit "$fails"
