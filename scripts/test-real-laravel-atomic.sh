#!/usr/bin/env bash
# Exercise the exact maintenance/status probe against a supported real Laravel skeleton.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: test-real-laravel-atomic.sh <laravel-version>" >&2
    exit 2
fi

version=$1
here=$(cd "$(dirname "$0")" && pwd)
php_binary=$(command -v php)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home"
mkdir -p "$HOME"

composer create-project --no-interaction --prefer-dist "laravel/laravel:$version" "$HOME/app" >/dev/null
if [ ! -f "$HOME/app/.env" ]; then
    install -m 600 "$HOME/app/.env.example" "$HOME/app/.env"
fi
(cd "$HOME/app" && php artisan key:generate --no-interaction --no-ansi >/dev/null)

# Laravel's serialized config includes absolute application paths. Reproduce
# the stable-directory rename and prove that caching again from the final path
# removes every staging-path reference.
staging="$HOME/.deployments/app/releases/cache-path-fixture"
mkdir -p "$(dirname "$staging")"
mv "$HOME/app" "$staging"
(cd "$staging" && php artisan config:cache --no-interaction --no-ansi >/dev/null)
grep -Fq -- "$staging" "$staging/bootstrap/cache/config.php" || {
    echo "expected Laravel's candidate-built config cache to contain the staging path" >&2
    exit 1
}
mv "$staging" "$HOME/app"
(cd "$HOME/app" && php artisan config:clear --no-interaction --no-ansi >/dev/null)
(cd "$HOME/app" && php artisan config:cache --no-interaction --no-ansi >/dev/null)
if grep -Fq -- "$staging" "$HOME/app/bootstrap/cache/config.php"; then
    echo "stable-path config cache retained a staging-path reference" >&2
    exit 1
fi
grep -Fq -- "$HOME/app" "$HOME/app/bootstrap/cache/config.php" || {
    echo "expected Laravel's rebuilt config cache to contain the stable path" >&2
    exit 1
}

serving=$(bash "$here/atomic-release.sh" status app fixture "$php_binary" | sed -n 's/^live_state=//p' | head -1)
[ "$serving" = serving ] || { echo "expected real Laravel to report serving, got '$serving'" >&2; exit 1; }

(cd "$HOME/app" && php artisan down --no-ansi >/dev/null)
maintenance=$(bash "$here/atomic-release.sh" status app fixture "$php_binary" | sed -n 's/^live_state=//p' | head -1)
[ "$maintenance" = maintenance ] || { echo "expected real Laravel to report maintenance, got '$maintenance'" >&2; exit 1; }

(cd "$HOME/app" && php artisan up --no-ansi >/dev/null)
restored=$(bash "$here/atomic-release.sh" status app fixture "$php_binary" | sed -n 's/^live_state=//p' | head -1)
[ "$restored" = serving ] || { echo "expected real Laravel to return to serving, got '$restored'" >&2; exit 1; }

printf 'Laravel %s real maintenance probe passed.\n' "$version"
