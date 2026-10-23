#!/usr/bin/env bash
# Prove ensure-passport-keys.sh against real Passport: a pair it creates or keeps loads, and a
# pair Passport refuses fails the step even when the declared key directory looks fine.
# shellcheck disable=SC2016,SC2034 # PHP source written into the fixture; statuses are read in eval'd checks.
set -uo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: test-real-laravel-passport.sh <laravel-version>" >&2
    exit 2
fi

version=$1
here=$(cd "$(dirname "$0")" && pwd)
script="$here/ensure-passport-keys.sh"
php_binary=$(command -v php)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home"
mkdir -p "$HOME"
fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; cat "$scratch/out" >&2; fails=$((fails + 1)); fi; }
run() { bash "$script" app "$php_binary" storage/app/private/oauth >"$scratch/out" 2>&1; }

set -e
composer create-project --no-interaction --prefer-dist "laravel/laravel:$version" "$HOME/app" >/dev/null 2>&1
if [ ! -f "$HOME/app/.env" ]; then
    install -m 600 "$HOME/app/.env.example" "$HOME/app/.env"
fi
cd "$HOME/app"
php artisan key:generate --no-interaction --no-ansi >/dev/null
composer require --no-interaction --no-progress 'laravel/passport:^13.0' >/dev/null 2>&1
set +e

# The application loads its keys from a path the test controls, as the apps using this
# action do. OAUTH_KEY_PATH lets a case point it somewhere other than the declared directory.
php -r '
    $file = "app/Providers/AppServiceProvider.php";
    $source = file_get_contents($file);
    $boot = "public function boot(): void\n    {\n";
    $line = "        \\Laravel\\Passport\\Passport::loadKeysFrom(env(\"OAUTH_KEY_PATH\", storage_path(\"app/private/oauth\")));\n"
        ."        if (env(\"OAUTH_FAIL_ANONYMOUS\")) { \$this->app->bind(\\League\\OAuth2\\Server\\ResourceServer::class, static function () { throw new class(\"fixture\") extends \\RuntimeException {}; }); }\n";
    if (substr_count($source, $boot) !== 1) { exit(1); }
    file_put_contents($file, str_replace($boot, $boot.$line, $source));
' || { echo "could not register the fixture key path" >&2; exit 1; }
keys="$HOME/app/storage/app/private/oauth"

run; status=$?
check "a pair created by passport:keys loads" \
    '[ "$status" -eq 0 ] && [ -s "$keys/oauth-private.key" ] && grep -Fxq "Passport loads the signing key pair." "$scratch/out"'
run; status=$?
check "the kept pair loads again" '[ "$status" -eq 0 ] && grep -Fxq "Passport loads the signing key pair." "$scratch/out"'

# The declared directory is complete and private, but the application reads another pair,
# with the public key readable by others: the configuration production had on 2026-10-22.
elsewhere="$HOME/app/storage/app/private/elsewhere"
mkdir -p "$elsewhere"
cp "$keys/oauth-private.key" "$keys/oauth-public.key" "$elsewhere/"
chmod 600 "$elsewhere/oauth-private.key"
chmod 644 "$elsewhere/oauth-public.key"
echo "OAUTH_KEY_PATH=$elsewhere" >>.env
run; status=$?
check "a key Passport refuses fails even though the declared pair is private" \
    '[ "$status" -eq 1 ] && grep -Fq "::error::Passport cannot load its signing keys" "$scratch/out" && grep -Fq "requires mode 0600 or 0660" "$scratch/out" && ! grep -Fq "$elsewhere" "$scratch/out"'

chmod 600 "$elsewhere/oauth-public.key"
run; status=$?
check "the same pair loads once it is private" '[ "$status" -eq 0 ]'

printf 'not a key\n' >"$elsewhere/oauth-public.key"
chmod 600 "$elsewhere/oauth-public.key"
run; status=$?
check "an unparseable key fails with only its exception class" \
    '[ "$status" -eq 1 ] && grep -Eq "Passport could not be built: [A-Za-z\\\\]+$" "$scratch/out" && ! grep -Fq "$elsewhere" "$scratch/out"'

# A migration-first in-place deployment ensured the pair against the previous code. Verify
# mode checks what the uploaded release loads, here a refused key outside the declared
# directory, and leaves it exactly as it found it.
cp "$keys/oauth-public.key" "$elsewhere/oauth-public.key"
chmod 644 "$elsewhere/oauth-public.key"
bash "$script" app "$php_binary" storage/app/private/oauth '' '' verify >"$scratch/out" 2>&1; status=$?
check "verify mode refuses the key the uploaded release loads, without repairing it" \
    '[ "$status" -eq 1 ] && grep -Fq "requires mode 0600 or 0660" "$scratch/out" && [ -n "$(find "$elsewhere/oauth-public.key" -perm 644 -print)" ]'
chmod 600 "$elsewhere/oauth-public.key"
bash "$script" app "$php_binary" storage/app/private/oauth '' '' verify >"$scratch/out" 2>&1; status=$?
check "verify mode accepts the same pair once it is private" '[ "$status" -eq 0 ]'

# An anonymous exception's class name carries a NUL byte and the defining file path.
echo "OAUTH_FAIL_ANONYMOUS=1" >>.env
run; status=$?
check "an anonymous exception is named generically, with no path or control byte" \
    '[ "$status" -eq 1 ] && grep -Fxq "Passport could not be built: an anonymous exception" "$scratch/out" && ! grep -Fq "@anonymous" "$scratch/out" && ! grep -Fq "$HOME" "$scratch/out" && ! tr -d "\n" <"$scratch/out" | grep -q "[^[:print:]]"'
sed -i.bak '/^OAUTH_FAIL_ANONYMOUS=/d' .env && rm -f .env.bak

echo "failures: $fails"
exit "$fails"
