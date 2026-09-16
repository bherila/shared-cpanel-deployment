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
cp "$HOME/app/bootstrap/providers.php" "$scratch/original-providers"
mkdir -p "$HOME/app/app/Services"
cat >"$HOME/app/app/Services/AuditFacadeTarget.php" <<'PHP'
<?php
namespace App\Services;
class AuditFacadeTarget { public function answer(): int { return 42; } }
PHP
cat >"$HOME/app/app/Providers/AuditFixtureServiceProvider.php" <<'PHP'
<?php
namespace App\Providers;
class AuditFixtureServiceProvider extends \Illuminate\Support\ServiceProvider {
    public function boot(): void {
        $loader = \Illuminate\Foundation\AliasLoader::getInstance();
        if (!$loader instanceof \PrivateAuditAliasLoader) { throw new \RuntimeException('unsafe alias loader'); }
        foreach (spl_autoload_functions() ?: [] as $callback) {
            $target = $callback instanceof \Closure ? (new \ReflectionFunction($callback))->getClosureThis() : null;
            if ($target instanceof \Illuminate\Foundation\AliasLoader && !$target instanceof \PrivateAuditAliasLoader) {
                throw new \RuntimeException('old alias callback remains');
            }
        }
        if ((new \AuditPreexistingAlias)->answer() !== 42 || \Facades\App\Services\AuditFacadeTarget::answer() !== 42) {
            throw new \RuntimeException('facade behavior changed');
        }
        if (getenv('AUDIT_INVALID_FACADE')) { $loader->load("Facades\\Invalid'Injected"); }
    }
}
PHP
cat >"$HOME/app/bootstrap/providers.php" <<'PHP'
<?php return [App\Providers\AppServiceProvider::class, App\Providers\AuditFixtureServiceProvider::class];
PHP
mv "$HOME/app/vendor/autoload.php" "$HOME/app/vendor/audit-original-autoload.php"
cat >"$HOME/app/vendor/autoload.php" <<'PHP'
<?php
$composer = require __DIR__.'/audit-original-autoload.php';
Illuminate\Foundation\AliasLoader::getInstance(['AuditPreexistingAlias'=>App\Services\AuditFacadeTarget::class])->register();
return $composer;
PHP
facade_hash=$("$php_binary" -r 'echo sha1("Facades\\App\\Services\\AuditFacadeTarget");')
facade_cache="$HOME/app/storage/framework/cache/facade-$facade_hash.php"
bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/normal-facade-proof"
[ ! -e "$facade_cache" ]
cat >"$facade_cache" <<'PHP'
<?php
file_put_contents(getenv('HOME').'/unsafe-bootstrap-cache', 'executed');
shell_exec('touch '.getenv('HOME').'/unsafe-facade-descendant &');
echo "operational-audit pending_migrations=0 queue_driver=database queue_applicability=database pending_total=777 failed_applicability=database failed_total=777\n";
exit(0);
PHP
cp "$facade_cache" "$scratch/forged-facade"
bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/safe-facade-proof"
grep -Fq 'pending_total=0 failed_applicability=database failed_total=0' "$scratch/safe-facade-proof"
cmp -s "$scratch/forged-facade" "$facade_cache"
[ ! -e "$HOME/unsafe-bootstrap-cache" ] && [ ! -e "$HOME/unsafe-facade-descendant" ]
if AUDIT_INVALID_FACADE=1 bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/invalid-facade-proof" 2>&1; then
    echo 'Invalid facade namespace must fail without code generation' >&2; exit 1
fi
for cache_file in services.php packages.php routes-v7.php events.php; do
    cache_path="$HOME/app/bootstrap/cache/$cache_file"
    original_present=false
    if [ -f "$cache_path" ]; then cp "$cache_path" "$scratch/original-cache"; original_present=true; fi
    cat >"$cache_path" <<'PHP'
<?php
file_put_contents(getenv('HOME').'/unsafe-bootstrap-cache', 'executed');
echo "operational-audit pending_migrations=0 queue_driver=database queue_applicability=database pending_total=777 failed_applicability=database failed_total=777\n";
exit(0);
PHP
    cp "$cache_path" "$scratch/forged-cache"
    bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/cache-proof"
    grep -Fq 'pending_total=0 failed_applicability=database failed_total=0' "$scratch/cache-proof"
    [ ! -e "$HOME/unsafe-bootstrap-cache" ]
    cmp -s "$scratch/forged-cache" "$cache_path"
    if [ "$original_present" = true ]; then cp "$scratch/original-cache" "$cache_path"; else rm "$cache_path"; fi
done
rm "$facade_cache"
mv "$HOME/app/vendor/audit-original-autoload.php" "$HOME/app/vendor/autoload.php"
cp "$scratch/original-providers" "$HOME/app/bootstrap/providers.php"
rm "$HOME/app/app/Services/AuditFacadeTarget.php" "$HOME/app/app/Providers/AuditFixtureServiceProvider.php"

# Laravel's actual schema:dump --prune artifact must not hide unapplied schema
# when migration PHP files are gone. Both missing and existing-empty repositories
# need the schema import; a nonempty applied repository with the dump is healthy.
cp -a "$HOME/app/database/migrations" "$scratch/migrations-before-prune"
cp "$HOME/app/storage/app/database.sqlite" "$scratch/applied-schema.sqlite"
(cd "$HOME/app" && php artisan schema:dump --prune --no-interaction >/dev/null)
bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/applied-schema-proof"
grep -Fq 'pending_migrations=0' "$scratch/applied-schema-proof"
cat >"$scratch/schema-audit-config.php" <<'PHP'
<?php
require getcwd().'/vendor/autoload.php';
$app = require getcwd().'/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
config(['queue.default'=>'sync', 'queue.failed.driver'=>null]);
file_put_contents($app->getCachedConfigPath(), '<?php return '.var_export(config()->all(),true).';');
PHP
(cd "$HOME/app" && "$php_binary" "$scratch/schema-audit-config.php")
(cd "$HOME/app" && "$php_binary" -r '$db = new PDO("sqlite:storage/app/database.sqlite"); foreach ($db->query("SELECT name FROM sqlite_master WHERE type=\"table\" AND name NOT LIKE \"sqlite_%\"")->fetchAll(PDO::FETCH_COLUMN) as $table) { $db->exec("DROP TABLE \"".str_replace("\"", "\"\"", $table)."\""); }')
if bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/missing-schema-proof" 2>&1; then
    echo 'Unapplied schema dump with missing repository must fail' >&2; exit 1
fi
(cd "$HOME/app" && "$php_binary" -r '(new PDO("sqlite:storage/app/database.sqlite"))->exec("CREATE TABLE migrations (id INTEGER PRIMARY KEY, migration TEXT, batch INTEGER)");')
if bash "$here/operational-audit.sh" app "$php_binary" 256M >"$scratch/empty-schema-proof" 2>&1; then
    echo 'Unapplied schema dump with empty repository must fail' >&2; exit 1
fi
(cd "$HOME/app" && "$php_binary" -r 'if ((new PDO("sqlite:storage/app/database.sqlite"))->query("SELECT COUNT(*) FROM migrations")->fetchColumn() != 0) exit(1);')
cp "$scratch/applied-schema.sqlite" "$HOME/app/storage/app/database.sqlite"
rm -rf "$HOME/app/database/schema" "$HOME/app/database/migrations"
cp -a "$scratch/migrations-before-prune" "$HOME/app/database/migrations"
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
