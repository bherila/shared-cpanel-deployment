#!/usr/bin/env bash
# Called by the isolated Laravel 12/13 integration after migrations are applied.
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 2 ] || exit 2
app=$1 php=$2
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
cp "$app/.env" "$scratch/env"
cp "$app/bootstrap/app.php" "$scratch/app.php"
cleanup() {
    cp "$scratch/env" "$app/.env"
    cp "$scratch/app.php" "$app/bootstrap/app.php"
    rm -f "$app/bootstrap/audit-original-app.php" "$app/bootstrap/cache/config.php" "$app/bootstrap/cache/custom.php" "$app/bootstrap/cache/external.php" "$app/.env.audit-fixture" "$app/.env.local"
    rm -rf "$scratch"
}
trap cleanup EXIT
unset APP_CONFIG_CACHE APP_ENV
cache() { (cd "$app" && "$php" artisan config:cache >/dev/null); }
audit() { bash "$here/operational-audit.sh" "$(basename "$app")" "$php" 256M; }
assert_driver() {
    local expected=$1
    (cd "$app" && "$php" -r '
require "vendor/autoload.php";
$app = require "bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
echo config("queue.connections.".config("queue.default").".driver");
') >"$scratch/actual-driver"
    [ "$(cat "$scratch/actual-driver")" = "$expected" ]
    audit >"$scratch/audit"
    grep -Fq "queue_driver=$expected " "$scratch/audit"
}
# Default cache suppresses dotenv entirely. Changing only dotenv must not make
# the audit silently inspect source config instead of the serving cache.
assert_driver database
printf '\nQUEUE_CONNECTION=sync\n' >>"$app/.env"
assert_driver database
rm "$app/bootstrap/cache/config.php"
# APP_ENV acquired from dotenv must not trigger a second environment-file load.
cp "$app/.env" "$app/.env.local"
printf '\nQUEUE_CONNECTION=database\n' >>"$app/.env.local"
assert_driver sync
rm "$app/.env.local"
# With the initial default absent, dotenv selects its own relative cache path.
printf '\nAPP_CONFIG_CACHE=bootstrap/cache/custom.php\n' >>"$app/.env"
cache
printf '\nQUEUE_CONNECTION=database\n' >>"$app/.env"
assert_driver sync
rm "$app/bootstrap/cache/custom.php"
assert_driver database
# Externally selected cache wins over dotenv, including when it is absent.
export APP_CONFIG_CACHE="$app/bootstrap/cache/external.php"
printf '\nQUEUE_CONNECTION=sync\n' >>"$app/.env"
cache
printf '\nQUEUE_CONNECTION=database\n' >>"$app/.env"
assert_driver sync
rm "$APP_CONFIG_CACHE"
assert_driver database
unset APP_CONFIG_CACHE
# APP_ENV selects .env.<environment> by the framework's ordinary precedence.
cp "$app/.env" "$app/.env.audit-fixture"
printf '\nQUEUE_CONNECTION=sync\n' >>"$app/.env.audit-fixture"
APP_ENV=audit-fixture assert_driver sync
rm "$app/.env.audit-fixture"
# Reject executable custom cache without requiring it or exposing its output.
cat >"$app/bootstrap/cache/custom.php" <<'PHP'
<?php
file_put_contents(getenv('HOME').'/unsafe-custom-cache', 'executed');
echo 'SECRET custom cache';
exit(0);
PHP
if audit >"$scratch/rejected" 2>&1; then echo 'Executable custom cache accepted' >&2; exit 1; fi
[ ! -e "$HOME/unsafe-custom-cache" ]
if grep -Fq SECRET "$scratch/rejected"; then exit 1; fi
rm "$app/bootstrap/cache/custom.php"
# Late generated PHP appears immediately before real LoadConfiguration. The
# audit must use its frozen absence for both default and dotenv-selected paths.
cp "$app/bootstrap/app.php" "$app/bootstrap/audit-original-app.php"
cat >"$app/bootstrap/app.php" <<'PHP'
<?php
$app = require __DIR__.'/audit-original-app.php';
if (getenv('AUDIT_CUSTOM_ENV_LOADER')) {
    $app->instance(Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables::class, new class {
        public function bootstrap($app): void { file_put_contents(getenv('HOME').'/unsafe-custom-env', 'executed'); }
    });
}
$app->beforeBootstrapping(Illuminate\Foundation\Bootstrap\LoadConfiguration::class, static function () {
    if ($path = getenv('AUDIT_LATE_CACHE')) {
        file_put_contents($path, '<?php file_put_contents(getenv("HOME")."/unsafe-late-cache", "executed"); echo "SECRET late cache"; exit(0);');
    }
});
return $app;
PHP
for selection in dotenv external default; do
    cp "$scratch/env" "$app/.env"
    case "$selection" in
        dotenv) printf '\nAPP_CONFIG_CACHE=bootstrap/cache/custom.php\n' >>"$app/.env"; path="$app/bootstrap/cache/custom.php" ;;
        external) path="$app/bootstrap/cache/external.php"; export APP_CONFIG_CACHE="$path" ;;
        default) path="$app/bootstrap/cache/config.php" ;;
    esac
    AUDIT_LATE_CACHE="$path" audit >"$scratch/late-audit"
    grep -Fq 'queue_driver=database ' "$scratch/late-audit"
    [ -f "$path" ] && [ ! -e "$HOME/unsafe-late-cache" ]
    if grep -Fq SECRET "$scratch/late-audit"; then exit 1; fi
    rm "$path"
    unset APP_CONFIG_CACHE
done
# Customized environment bootstrapping cannot be assumed to have these semantics.
cp "$scratch/env" "$app/.env"
cache
for state in cached uncached; do
    if AUDIT_CUSTOM_ENV_LOADER=1 audit >"$scratch/custom-env" 2>&1; then
        echo 'Custom environment bootstrapper accepted' >&2; exit 1
    fi
    [ ! -e "$HOME/unsafe-custom-env" ]
    if [ "$state" = cached ]; then rm "$app/bootstrap/cache/config.php"; fi
done
printf 'Real Laravel cache selection: default, dotenv, external, APP_ENV, executable rejection and frozen absence passed.\n'
