#!/usr/bin/env bash
# Invoked by the Laravel 12/13 harness on its isolated, finalized managed fixture.
# shellcheck disable=SC2016
set -euo pipefail
[[ $# == 2 && $1 == "$HOME/app" ]] || exit 2
stable=$1 php=$2
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
web_pid=''
step=setup
result=0
trap 'result=$?; if [[ $result != 0 ]]; then echo "Real orphan fixture failed at $step" >&2; [[ ! -f $work/output ]] || cat "$work/output" >&2; fi; if [[ -n $web_pid ]]; then kill "$web_pid" 2>/dev/null || true; wait "$web_pid" 2>/dev/null || true; fi; rm -rf -- "$work"' EXIT
release=$(sed -n 's/^release=//p' "$stable/.deploy-release")
commit=$(sed -n 's/^commit=//p' "$stable/.deploy-release")
control="$HOME/.deployments/app"
real_curl=$(command -v curl)
mkdir -p "$work/bin" "$stable/app/Services"
# The source environment is authoritative for this explicit operation.
sed -i '/^SESSION_DRIVER=/d; /^CACHE_STORE=/d' "$stable/.env"
printf '\nSESSION_DRIVER=file\nCACHE_STORE=file\n' >>"$stable/.env"
printf 'APP_MAINTENANCE_DRIVER=cache\nAPP_CONFIG_CACHE=bootstrap/cache/unsupported.php\nDB_DATABASE=/nonexistent/wrong-selection.sqlite\n' >"$stable/.env.local"
cat >"$stable/app/Services/RecoveryFixtureTarget.php" <<'PHP'
<?php
namespace App\Services;
class RecoveryFixtureTarget { public function answer(): int { return 42; } }
PHP
cat >"$stable/app/Providers/RecoveryFixtureProvider.php" <<'PHP'
<?php
namespace App\Providers;
class RecoveryFixtureProvider extends \Illuminate\Support\ServiceProvider {
    public function boot(): void {
        if (file_exists(storage_path('app/break-bootstrap'))) { throw new \RuntimeException('deliberately broken trusted bootstrap'); }
        if (\Facades\App\Services\RecoveryFixtureTarget::answer() !== 42) { throw new \RuntimeException('facade semantics'); }
    }
}
PHP
cat >"$stable/bootstrap/providers.php" <<'PHP'
<?php return [App\Providers\AppServiceProvider::class, App\Providers\RecoveryFixtureProvider::class];
PHP
cat >>"$stable/routes/web.php" <<'PHP'

\Illuminate\Support\Facades\Route::get('/__recovery-fixture', fn () => response('selected-recovery-fixture'));
PHP
cp -p "$stable/storage/framework/down" "$work/original-down"
cp "$stable/.env" "$work/original-env"
database="$stable/storage/app/database.sqlite"
db_hash=$(sha256sum "$database"); db_hash=${db_hash%% *}
metadata_hash=$(sha256sum "$stable/.deploy-release"); metadata_hash=${metadata_hash%% *}
facade_hash=$("$php" -r 'echo sha1("Facades\\App\\Services\\RecoveryFixtureTarget");')
# A web request must not execute any old generated cache PHP after preparation.
for path in "$stable/bootstrap/cache/"{config.php,packages.php,services.php,routes-v7.php,events.php} \
    "$stable/storage/framework/cache/facade-$facade_hash.php"; do
    printf '<?php file_put_contents(getenv("HOME")."/unsafe-orphan-cache", "executed"); exit(0);' >"$path"
done
step=native-guards
bash "$here/test-real-laravel-orphan-guards.sh" "$stable" "$php"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
(cd "$stable/public"; exec "$php" -S "127.0.0.1:$port" -t . ../vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php) >"$work/web.log" 2>&1 &
web_pid=$!
export REAL_RECOVERY_PORT="$port" REAL_RECOVERY_CURL="$real_curl"
cat >"$work/bin/curl" <<'SH'
#!/usr/bin/env bash
args=("$@")
args[${#args[@]}-1]="http://127.0.0.1:$REAL_RECOVERY_PORT/up"
exec "$REAL_RECOVERY_CURL" "${args[@]}"
SH
chmod +x "$work/bin/curl"
new_bundle() {
    bundle=$(mktemp -d "$work/bundle.XXXXXX")
    cp "$here"/{recover-orphan-remote.sh,recover-orphan-state.php,recover-orphan-framework.php,validate-recover-orphan-inputs.sh,operational-audit.sh} "$bundle/"
    cat >"$bundle/orphan-verification.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${REAL_RECOVERY_FAILURE:-} != bootstrap ]] || { touch "$1/storage/app/break-bootstrap"; exit 1; }
body=$("$REAL_RECOVERY_CURL" --fail --silent --show-error --max-time 15 "http://127.0.0.1:$REAL_RECOVERY_PORT/__recovery-fixture")
[[ $body == selected-recovery-fixture ]]
SH
    token=orphan-$("$php" -r 'echo bin2hex(random_bytes(16));')
}
resume() {
    PATH="$work/bin:$PATH" bash "$bundle/recover-orphan-remote.sh" resume app "$release" "$commit" "$token" storage "$php" 256M \
        https://isolated.test/up selected-maintenance-source-config true orphan-verification.sh >"$work/output" 2>&1
}
new_bundle
step=custom-path-refusal
if APP_CONFIG_CACHE=bootstrap/cache/custom.php resume; then echo 'External custom config path must be refused' >&2; exit 1; fi
[[ ! -e $control/deploy.lock && ! -e $control/recovery/$token && ! -e $HOME/unsafe-orphan-cache ]]
printf '\nAPP_CONFIG_CACHE=bootstrap/cache/custom.php\n' >>"$stable/.env"
if resume; then echo 'Dotenv custom config path must be refused' >&2; exit 1; fi
[[ ! -e $control/deploy.lock && ! -e $control/recovery/$token && ! -e $HOME/unsafe-orphan-cache ]]
cp "$work/original-env" "$stable/.env"
step=resume
resume
grep -Fq 'result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released' "$work/output"
[[ ! -e $control/deploy.lock && ! -e $stable/storage/framework/down && ! -e $HOME/unsafe-orphan-cache ]]
[[ ! -e $stable/bootstrap/cache/routes-v7.php && ! -e $stable/bootstrap/cache/events.php ]]
[[ $(sha256sum "$database") == "$db_hash "* && $(sha256sum "$stable/.deploy-release") == "$metadata_hash "* ]]
cmp -s "$stable/.env" "$work/original-env"
[[ ! -s $FIXTURE_CRONTAB ]]
echo 'Real source config and trusted provider/facade caches serve the exact selected app; old generated PHP never executed.'
(cd "$stable"; "$php" artisan down --no-ansi >/dev/null)
cp -p "$stable/storage/framework/down" "$work/failure-down"
new_bundle
step=bootstrap-rollback
if REAL_RECOVERY_FAILURE=bootstrap resume; then echo 'Expected verification failure' >&2; exit 1; fi
[[ -f $stable/storage/app/break-bootstrap && ! -e $control/deploy.lock ]]
cmp -s "$stable/storage/framework/down" "$work/failure-down"
grep -Fq 'rollback=maintenance cron=paused lock=released' "$work/output"
[[ $(sha256sum "$database") == "$db_hash "* ]]
echo 'Real Laravel bootstrap failure after up restores exact original maintenance without bootstrapping Laravel.'
rm "$stable/storage/app/break-bootstrap"
# Restoration intentionally remains down; ordinary deployment never overrides it.
guarded_normal=normal-after-restore-${token:7:8}
if bash "$here/atomic-release.sh" begin app "$guarded_normal" "$commit" 60 3 maintenance '' stable-directory storage >"$work/begin" 2>&1; then
    # begin acquires/prepares only; the actual maintenance refusal is quiesce.
    if bash "$here/atomic-release.sh" quiesce app "$guarded_normal" "$php" >"$work/quiesce" 2>&1; then exit 1; fi
    bash "$here/atomic-release.sh" finalize app "$guarded_normal" "$php" >"$work/finalize"
fi
[[ -f $stable/storage/framework/down && ! -e $control/deploy.lock ]]
new_bundle
step=resume-after-rollback
resume
# The conflicting file served only the recovery single-selection regression;
# ordinary config:cache has its own fresh bootstrap, outside this operation.
rm "$stable/.env.local"
# A normal transaction can proceed after a separately proven explicit resume.
next=normal-after-recovery-${token:7:8}
step=normal-deployment
bash "$here/atomic-release.sh" begin app "$next" "$commit" 60 3 maintenance '' stable-directory storage >/dev/null
candidate="$control/releases/$next"
cp -a "$stable/." "$candidate/"
rm "$candidate/storage"
mkdir "$candidate/storage"
rm "$candidate/.deploy-release"
bash "$here/atomic-release.sh" preflight app "$next" '' >/dev/null
bash "$here/atomic-release.sh" quiesce app "$next" "$php" >/dev/null
bash "$here/atomic-release.sh" prepare app "$next" "$php" >/dev/null
bash "$here/atomic-release.sh" risk app "$next" "$php" >/dev/null
bash "$here/atomic-release.sh" activate app "$next" "$php" 256M >/dev/null
bash "$here/atomic-release.sh" refresh-caches app "$next" "$php" 256M config:cache >/dev/null
bash "$here/atomic-release.sh" serve app "$next" "$php" >/dev/null
bash "$here/atomic-release.sh" commit app "$next" "$php" >/dev/null
bash "$here/atomic-release.sh" finalize app "$next" "$php" >/dev/null
[[ ! -e $control/deploy.lock && ! -e $stable/storage/framework/down && ! -s $FIXTURE_CRONTAB ]]
[[ $(sha256sum "$database") == "$db_hash "* ]]
echo 'A later normal deployment succeeds after confirmed restoration and a fresh explicit resume; no database migration/data writes occurred.'
