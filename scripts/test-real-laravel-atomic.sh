#!/usr/bin/env bash
# Exercise the exact maintenance/status probe against a supported real Laravel skeleton.
# shellcheck disable=SC2016
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

# Exercise a real, partially applied SQLite migration in an isolated real-directory
# transaction. Only crontab is mocked: maintenance, migrations and SQL are real.
mkdir -p "$scratch/bin"
export FIXTURE_CRONTAB="$scratch/crontab"
cat >"$scratch/bin/crontab" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    -l) if [ -f "$FIXTURE_CRONTAB" ]; then cat "$FIXTURE_CRONTAB"; else echo 'no crontab for fixture' >&2; exit 1; fi ;;
    -r) rm -f "$FIXTURE_CRONTAB" ;;
    *) cp "$1" "$FIXTURE_CRONTAB" ;;
esac
SH
chmod +x "$scratch/bin/crontab"
export PATH="$scratch/bin:$PATH"
printf '* * * * * cd "$HOME/app" && php artisan schedule:run # JOB:app-scheduler\n' >"$FIXTURE_CRONTAB"
mkdir -p "$HOME/app/storage/app"
touch "$HOME/app/storage/app/database.sqlite"
cat >>"$HOME/app/.env" <<'ENV'
DB_CONNECTION=sqlite
DB_DATABASE=storage/app/database.sqlite
QUEUE_CONNECTION=database
ENV
(cd "$HOME/app" && php artisan config:clear >/dev/null && php artisan migrate --force --no-interaction >/dev/null)
bash "$here/operational-audit.sh" app "$php_binary" 256M
(cd "$HOME/app" && php artisan config:cache >/dev/null)
bash "$here/operational-audit.sh" app "$php_binary" 256M
(cd "$HOME/app" && php artisan config:clear >/dev/null)
commit=0123456789abcdef0123456789abcdef01234567
cp "$HOME/app/storage/app/database.sqlite" "$scratch/healthy.sqlite"
cp "$FIXTURE_CRONTAB" "$scratch/healthy.cron"
(cd "$HOME/app" && "$php_binary" -r '(new PDO("sqlite:storage/app/database.sqlite"))->exec("DROP TABLE failed_jobs");')
bash "$here/atomic-release.sh" begin app real-audit-preflight "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null
cp -a "$HOME/app/." "$HOME/.deployments/app/releases/real-audit-preflight/"
bash "$here/atomic-release.sh" preflight app real-audit-preflight '' >/dev/null
if bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/preflight-output" 2>&1; then
    echo 'Existing-state audit must reject missing applicable table before quiescence' >&2; exit 1
fi
[ ! -f "$HOME/app/storage/framework/down" ]
cmp -s "$scratch/healthy.cron" "$FIXTURE_CRONTAB"
bash "$here/atomic-release.sh" finalize app real-audit-preflight "$php_binary" >"$scratch/preflight-finalizer"
grep -Fqx 'live_state=serving' "$scratch/preflight-finalizer"
[ ! -e "$HOME/.deployments/app/deploy.lock" ]
cmp -s "$scratch/healthy.cron" "$FIXTURE_CRONTAB"
cp "$scratch/healthy.sqlite" "$HOME/app/storage/app/database.sqlite"
release=real-partial-failure
bash "$here/atomic-release.sh" begin app "$release" "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null
candidate="$HOME/.deployments/app/releases/$release"
cp -a "$HOME/app/." "$candidate/"
bash "$here/atomic-release.sh" preflight app "$release" '' >/dev/null
bash "$here/atomic-release.sh" quiesce app "$release" "$php_binary" >/dev/null
bash "$here/atomic-release.sh" prepare app "$release" "$php_binary" >/dev/null
cp "$HOME/app/.deploy-release" "$scratch/old-metadata"
shared_storage=$(realpath "$HOME/app/storage")
cat >"$candidate/database/migrations/2099_01_01_000000_deliberate_partial_failure.php" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\Schema;
use Illuminate\Database\Schema\Blueprint;
return new class extends Migration {
    public $withinTransaction = false;
    public function up(): void {
        Schema::create('isolated_partial_failure', function (Blueprint $table) { $table->id(); });
        throw new RuntimeException('Deliberate isolated migration failure');
    }
    public function down(): void { Schema::dropIfExists('isolated_partial_failure'); }
};
PHP
bash "$here/atomic-release.sh" risk app "$release" "$php_binary" >/dev/null
if bash "$here/remote-artisan.sh" ".deployments/app/releases/$release" "$php_binary" 256M config:clear 'migrate --force' >"$scratch/migration-output" 2>&1; then
    echo 'Expected deliberately failing actual migration' >&2; exit 1
fi
grep -Fq 'Deliberate isolated migration failure' "$scratch/migration-output"
bash "$here/atomic-release.sh" finalize app "$release" "$php_binary" >"$scratch/finalizer"
[ -d "$HOME/app" ] && [ ! -L "$HOME/app" ]
cmp -s "$scratch/old-metadata" "$HOME/app/.deploy-release"
[ "$(realpath "$HOME/app/storage")" = "$shared_storage" ]
[ ! -s "$FIXTURE_CRONTAB" ]
grep -Fq '# JOB:app-scheduler' "$HOME/.deployments/app/recovery/$release.cron"
grep -Fqx 'live_state=maintenance' "$scratch/finalizer"
grep -Fqx "live_commit=$commit" "$scratch/finalizer"
grep -Fqx "live_release=$(sed -n 's/^release=//p' "$scratch/old-metadata")" "$scratch/finalizer"
(cd "$HOME/app" && "$php_binary" -r '
require "vendor/autoload.php";
$app = require "bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
if (!Illuminate\Support\Facades\Schema::hasTable("isolated_partial_failure")) exit(1);
if (Illuminate\Support\Facades\DB::table("migrations")->where("migration", "2099_01_01_000000_deliberate_partial_failure")->exists()) exit(1);
')
if bash "$here/operational-audit.sh" ".deployments/app/releases/$release" "$php_binary" 256M >"$scratch/audit-output" 2>&1; then
    echo 'Audit must reject candidate with genuinely pending migration' >&2; exit 1
fi
echo 'Real SQLite partial failure preserves exact prior real-directory code/storage, maintenance and paused cron; partial schema is NOT rolled back.'

printf 'Laravel %s real maintenance probe passed.\n' "$version"
