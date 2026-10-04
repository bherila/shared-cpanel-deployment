#!/usr/bin/env bash
# Real PHP with a minimal Laravel bootstrap isolates path and metadata fixtures.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
task_home="$scratch/home"
stable="$task_home/app"
control="$task_home/.deployments/app"
shared="$control/shared"
php=$(command -v php)
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$stable"/{vendor,bootstrap/cache,resources/views,public} "$control"/{releases,state} \
    "$shared/storage"/{framework/views,framework/sessions,framework/cache/data,logs,app/private/data} "$shared/public/ohif"
ln -s "$shared/storage" "$stable/storage"
ln -s "$shared/public/ohif" "$stable/public/ohif"
touch "$stable/vendor/autoload.php" "$shared/storage/app/database.sqlite"
printf 'fixture\n' > "$control/generation"
printf 'release=fixture\ncommit=%s\n' "$commit" > "$stable/.deploy-release"
cat > "$stable/bootstrap/app.php" <<'PHP'
<?php
namespace Illuminate\Contracts\Console { interface Kernel {} }
namespace {
function config($key) {
    return match ($key) {
        'queue.default' => 'sync', 'queue.connections.sync' => ['driver'=>'sync'],
        'queue.failed' => ['driver'=>null],
        'database.default' => 'sqlite',
        'database.connections.sqlite' => ['driver'=>'sqlite','database'=>getenv('DB_PATH') ?: 'storage/app/database.sqlite'],
    };
}
class Fixture {
    public function getCachedConfigPath() { return getcwd().'/bootstrap/cache/config.php'; }
    public function make($key) { return $this; }
    public function bootstrap() {
        if ($shutdown = getenv('SHUTDOWN_OUTPUT') ?: getenv('SUCCESS_SHUTDOWN_OUTPUT')) {
            register_shutdown_function(static function () use ($shutdown): void {
                $prefix = $shutdown === 'nul' ? "\0" : '';
                fwrite(STDOUT, $prefix.'SECRET_SHUTDOWN_STDOUT');
            });
            if (getenv('SHUTDOWN_OUTPUT')) { throw new \RuntimeException('SECRET_EXCEPTION'); }
        }
        if (getenv('NOISY_BOOTSTRAP')) {
            fwrite(STDOUT, getenv('NOISY_BOOTSTRAP') === 'nul' ? "\0" : "SECRET_DIRECT_STDOUT\n");
            throw new \RuntimeException('SECRET_EXCEPTION');
        }
    }
    public function paths() { return []; }
    public function databasePath($path) { return '/nonexistent/'.$path; }
    public function getMigrationFiles($paths) { return getenv('PENDING_MIGRATION') ? ['synthetic-pending'=>'synthetic'] : []; }
    public function getRepository() { return $this; }
    public function repositoryExists() { return true; }
    public function getRan() { return []; }
    public function resolveConnection($name) { if (getenv('DATABASE_FAILURE')) { throw new \RuntimeException('SECRET_DATABASE_FAILURE'); } return $this; }
    public function getConfig() {
        return ['driver'=>'sqlite', 'database'=>getenv('EFFECTIVE_DB_PATH') ?: getenv('DB_PATH') ?: 'storage/app/database.sqlite'];
    }
    public function getName() { return 'sqlite'; }
    public function isDownForMaintenance() { return (bool) getenv('DOWN'); }
}
return new Fixture;
}
PHP
cat > "$scratch/config.php" <<'PHP'
<?php
$stable = $argv[1];
$config = [
 'view'=>['paths'=>[$stable.'/resources/views'],'compiled'=>$stable.'/storage/framework/views'],
 'session'=>['files'=>$stable.'/storage/framework/sessions'],
 'cache'=>['default'=>'storage','stores'=>[
   'file'=>['driver'=>'file','path'=>$stable.'/storage/framework/cache/data','lock_path'=>null],
   'storage'=>['driver'=>'storage','path'=>'data','disk'=>'local'],
 ]],
 'filesystems'=>['default'=>'local','disks'=>['local'=>['driver'=>'local','root'=>$stable.'/storage/app/private']]],
 'logging'=>['channels'=>[
   'single'=>['driver'=>'single','path'=>$stable.'/storage/logs/laravel.log'],
   'stderr'=>['driver'=>'monolog','handler'=>'Monolog\\Handler\\StreamHandler','handler_with'=>['stream'=>'php://stderr']],
 ]],
];
switch ($argv[2]) {
 case 'stale': $config['view']['compiled'] = dirname($stable).'/.deployments/app/releases/vanished/storage/views'; break;
 case 'alias': $config['view']['compiled'] = $stable.'/storage/framework/alias'; break;
 case 'traversal': $config['cache']['stores']['storage']['path'] = '../SECRET'; break;
 case 'absolute': $config['cache']['stores']['storage']['path'] = '/SECRET'; break;
 case 'stream': $config['logging']['channels']['stderr']['handler_with']['stream'] = 'php://filter/SECRET'; break;
 case 'log-directory': $config['logging']['channels']['single']['path'] = $stable.'/storage/logs'; break;
 case 'wrong-type': $config['session']['files'] = ['SECRET']; break;
 case 'persistent-log': $config['logging']['channels']['single']['path'] = $stable.'/runtime.log'; break;
 case 'cache-escape': $config['cache']['stores']['file']['path'] = $stable.'/storage/framework/escape'; break;
}
echo '<?php return '.var_export($config, true).';';
PHP
write_config() { "$php" "$scratch/config.php" "$stable" "${1:-valid}" > "$stable/bootstrap/cache/config.php"; }
audit() { env HOME="$task_home" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" $'storage\npublic/ohif' "${1:-selected}"; }
reject() {
    if audit "${1:-selected}" > "$scratch/output" 2>&1; then echo "unexpected pass: ${2:-fixture}" >&2; exit 1; fi
    if grep -Fq SECRET "$scratch/output"; then echo 'secret leaked' >&2; exit 1; fi
}
write_config
audit
audit finalized
# Three-argument candidate audits remain operational-only before activation.
cp -a "$stable" "$control/releases/candidate-audit"
env HOME="$task_home" bash "$here/operational-audit.sh" .deployments/app/releases/candidate-audit "$php" 256M > "$scratch/candidate-output"
grep -q '^operational-audit pending_migrations=0' "$scratch/candidate-output"
if grep -Fq runtime-audit "$scratch/candidate-output"; then echo 'candidate audit enabled runtime mode' >&2; exit 1; fi
rm -rf "$control/releases/candidate-audit"
# Valid persistent inventories above the old 64-path cap remain supported.
persistent_inventory=$'storage\npublic/ohif'
for number in {1..63}; do
    mkdir "$shared/extra$number"
    ln -s "$shared/extra$number" "$stable/extra$number"
    persistent_inventory+=$'\n'"extra$number"
done
env HOME="$task_home" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" "$persistent_inventory" selected > "$scratch/large-inventory-output"
grep -Fxq 'runtime-audit identity=exact paths=canonical writable=yes database=persistent phase=selected' "$scratch/large-inventory-output"
for number in {1..63}; do
    rm "$stable/extra$number"
    rmdir "$shared/extra$number"
done
for bootstrap_noise in 1 nul; do
    if NOISY_BOOTSTRAP="$bootstrap_noise" audit selected > "$scratch/noisy-output" 2>&1; then exit 1; fi
    if grep -aFq SECRET "$scratch/noisy-output"; then echo 'direct bootstrap stdout was disclosed' >&2; exit 1; fi
    if grep -aFq 'runtime-audit key=' "$scratch/noisy-output"; then
        echo 'noisy failure records were relayed' >&2; exit 1
    fi
    grep -Fq 'diagnostics redacted' "$scratch/noisy-output"
done
for shutdown_output in unterminated nul; do
    if SHUTDOWN_OUTPUT="$shutdown_output" audit selected > "$scratch/shutdown-output" 2>&1; then exit 1; fi
    if grep -aFq SECRET "$scratch/shutdown-output"; then echo 'shutdown bootstrap stdout was disclosed' >&2; exit 1; fi
    if grep -aFq 'runtime-audit key=' "$scratch/shutdown-output"; then
        echo 'mixed failure records were relayed' >&2; exit 1
    fi
    grep -Fq 'diagnostics redacted' "$scratch/shutdown-output"
done
for shutdown_output in unterminated nul; do
    for success_mode in runtime operational; do
        if [ "$success_mode" = runtime ]; then
            if SUCCESS_SHUTDOWN_OUTPUT="$shutdown_output" audit selected > "$scratch/shutdown-success" 2>&1; then echo 'runtime shutdown output was accepted' >&2; exit 1; fi
        else
            if env HOME="$task_home" SUCCESS_SHUTDOWN_OUTPUT="$shutdown_output" bash "$here/operational-audit.sh" app "$php" 256M > "$scratch/shutdown-success" 2>&1; then echo 'operational shutdown output was accepted' >&2; exit 1; fi
        fi
        if grep -aEq 'SECRET|identity=exact|operational-audit pending_migrations=' "$scratch/shutdown-success"; then
            echo 'unvalidated success output or a shutdown secret was relayed' >&2; exit 1
        fi
        grep -Fq 'diagnostics redacted' "$scratch/shutdown-success"
    done
done
if EFFECTIVE_DB_PATH=:memory: audit selected > "$scratch/effective-db-output" 2>&1; then
    echo 'nonpersistent effective database was accepted' >&2; exit 1
fi
grep -Fq 'key=database.' "$scratch/effective-db-output"
DB_PATH="$stable/storage/app/database.sqlite" audit finalized > /dev/null
env HOME="$task_home" bash "$here/operational-audit.sh" app "$php" -1 fixture "$commit" $'storage\npublic/ohif' selected > /dev/null
for fixture in stale traversal absolute stream log-directory wrong-type; do write_config "$fixture"; reject selected "$fixture"; done
write_config
rmdir "$shared/storage/framework/cache/data"
reject selected missing-leaf
mkdir "$shared/storage/framework/cache/data"
printf 'file' > "$shared/storage/framework/not-a-directory"
ln -s "$shared/storage/framework/views" "$shared/storage/framework/alias"
write_config alias
reject selected nested-alias
mkdir "$scratch/SECRET"
ln -s "$scratch/SECRET" "$shared/storage/framework/escape"
write_config cache-escape
reject selected escape
write_config
mkdir "$scratch/generation-bin"
cat > "$scratch/generation-bin/cat" <<'CAT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "$HOME/.deployments/app/generation" ]; then
    calls=0
    [ ! -f "$GENERATION_CAT_CALLS" ] || calls=$(<"$GENERATION_CAT_CALLS")
    calls=$((calls + 1))
    printf '%s' "$calls" > "$GENERATION_CAT_CALLS"
    if [ "$calls" = 1 ]; then mkdir "$HOME/.deployments/app/deploy.lock"; fi
    if [ "$calls" = 2 ]; then printf 'newer-transaction\n' > "$HOME/.deployments/app/deploy.lock/owner"; fi
fi
exec /bin/cat "$@"
CAT
chmod +x "$scratch/generation-bin/cat"
env HOME="$task_home" PATH="$scratch/generation-bin:$PATH" GENERATION_CAT_CALLS="$scratch/generation-calls" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" $'storage\npublic/ohif' generation > "$scratch/owner-transition-output"
grep -Fxq 'runtime-audit generation=superseded' "$scratch/owner-transition-output"
rm "$control/deploy.lock/owner"
rmdir "$control/deploy.lock"
# A missing owner that never resolves must fail without guessing a generation.
mkdir "$control/deploy.lock"
if env HOME="$task_home" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" $'storage\npublic/ohif' generation > "$scratch/missing-owner-output" 2>&1; then exit 1; fi
grep -Fq 'generation proof failed' "$scratch/missing-owner-output"
printf 'malformed/SECRET_OWNER\n' > "$control/deploy.lock/owner"
if env HOME="$task_home" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" $'storage\npublic/ohif' generation > "$scratch/malformed-owner-output" 2>&1; then exit 1; fi
grep -Fq 'generation proof failed' "$scratch/malformed-owner-output"
if grep -Fq SECRET "$scratch/malformed-owner-output"; then echo 'malformed owner was disclosed' >&2; exit 1; fi
rm "$control/deploy.lock/owner"
rmdir "$control/deploy.lock"
mkdir "$control/deploy.lock"
printf 'fixture\n' > "$control/deploy.lock/owner"
audit selected > /dev/null
reject finalized held-lock
rm "$control/deploy.lock/owner"
rmdir "$control/deploy.lock"
mkdir "$control/state/incomplete"
reject finalized incomplete-transaction
rmdir "$control/state/incomplete"
if DOWN=1 audit finalized > "$scratch/output" 2>&1; then exit 1; fi
cp "$stable/.deploy-release" "$scratch/metadata"
printf 'release=wrong\ncommit=%s\n' "$commit" > "$stable/.deploy-release"
reject selected identity
cp "$scratch/metadata" "$stable/.deploy-release"
mv "$shared/public/ohif" "$scratch/ohif"
ln -s "$scratch/ohif" "$shared/public/ohif"
reject selected shared-ancestor
rm "$shared/public/ohif"
mv "$scratch/ohif" "$shared/public/ohif"
chmod 500 "$shared/storage/framework/views"
# Root ignores mode bits; the CI runner is an ordinary user.
if [ "$(id -u)" != 0 ]; then reject selected unwritable; fi
chmod 700 "$shared/storage/framework/views"
touch "$shared/runtime.log"
ln -s "$shared/runtime.log" "$stable/runtime.log"
write_config persistent-log
env HOME="$task_home" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" $'storage\npublic/ohif\nruntime.log' finalized > /dev/null
write_config
mkdir "$control/deploy.lock"
printf 'newer-transaction\n' > "$control/deploy.lock/owner"
# New owner is visible before the generation rename or transaction initialization.
audit finalized | grep -Fxq 'runtime-audit generation=superseded'
printf 'newer-transaction\n' > "$control/generation"
audit finalized | grep -Fxq 'runtime-audit generation=superseded'
mv "$stable" "$scratch/stable-in-transition"
audit finalized | grep -Fxq 'runtime-audit generation=superseded'
mv "$scratch/stable-in-transition" "$stable"
rm "$control/deploy.lock/owner"
rmdir "$control/deploy.lock"
# A newer transaction may have restored the exact prior release and unlocked.
audit finalized | grep -Fxq 'runtime-audit generation=superseded'
printf 'fixture\n' > "$control/generation"
# Simulate a newer begin after the initial generation read, both when the
# PHP proof succeeds and when its transient error would otherwise fail CI.
cat > "$scratch/racing-php" <<'RACE'
#!/usr/bin/env bash
printf 'newer-transaction\n' > "$HOME/.deployments/app/generation"
if [ "${FAIL_AUDIT:-}" = 1 ]; then echo SECRET; exit 1; fi
exec "$REAL_PHP" "$@"
RACE
chmod +x "$scratch/racing-php"
for fail in 0 1; do
    printf 'fixture\n' > "$control/generation"
    env HOME="$task_home" REAL_PHP="$php" FAIL_AUDIT="$fail" bash "$here/operational-audit.sh" app "$scratch/racing-php" 256M fixture "$commit" $'storage\npublic/ohif' finalized > "$scratch/race-output"
    grep -Fxq 'runtime-audit generation=superseded' "$scratch/race-output"
    if grep -Fq SECRET "$scratch/race-output"; then exit 1; fi
done
printf 'fixture\n' > "$control/generation"
audit finalized > /dev/null
echo 'Canonical runtime, redaction, persistence and finalization fixtures passed.'

# Candidate paths must retain the original three-argument audit mode.
mkdir -p "$control/releases/candidate"
cp -r "$stable/vendor" "$stable/bootstrap" "$control/releases/candidate/"
HOME="$task_home" bash "$here/operational-audit.sh" .deployments/app/releases/candidate "$php" 256M | grep '^operational-audit ' > /dev/null
# An ownerless lock snapshot during mkdir/owner initialization is retried.
mkdir "$control/deploy.lock"
(sleep 0.2; printf 'new-owner\n' > "$control/deploy.lock/owner") &
writer=$!
audit generation | grep -Fxq 'runtime-audit generation=superseded'
wait "$writer"
rm "$control/deploy.lock/owner"; rmdir "$control/deploy.lock"

# The accepted persistence inventory may exceed 64 paths.
links=$'storage\npublic/ohif'
for number in {1..65}; do
    mkdir "$shared/extra-$number"
    ln -s "$shared/extra-$number" "$stable/extra-$number"
    links+=$'\n'"extra-$number"
done
HOME="$task_home" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" "$links" selected | grep '^runtime-audit ' > /dev/null

# Operational failures after successful path validation must not claim cache drift.
for operational_failure in PENDING_MIGRATION DATABASE_FAILURE; do
    if env HOME="$task_home" "$operational_failure=1" bash "$here/operational-audit.sh" app "$php" 256M fixture "$commit" $'storage\npublic/ohif' selected > "$scratch/operational-failure" 2>&1; then exit 1; fi
    if grep -Eq 'runtime-audit key=|SECRET' "$scratch/operational-failure"; then echo 'operational error misclassified or disclosed' >&2; exit 1; fi
    grep -Fq 'diagnostics redacted' "$scratch/operational-failure"
done
# A newer begin's failed generation write can expose a transient PHP lock,
# then clean up without advancing the generation. Retry the current proof.
cat > "$scratch/retry-php" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
calls=0
[[ ! -f "$RETRY_CALLS" ]] || calls=$(cat "$RETRY_CALLS")
calls=$((calls+1)); printf '%s' "$calls" > "$RETRY_CALLS"
if [[ "$calls" == 1 ]]; then
    mkdir "$HOME/.deployments/app/deploy.lock"
    printf 'aborted-begin\n' > "$HOME/.deployments/app/deploy.lock/owner"
    "$REAL_PHP" "$@"
    status=$?
    rm "$HOME/.deployments/app/deploy.lock/owner"
    rmdir "$HOME/.deployments/app/deploy.lock"
    exit "$status"
fi
exec "$REAL_PHP" "$@"
SH
chmod +x "$scratch/retry-php"
env HOME="$task_home" REAL_PHP="$php" RETRY_CALLS="$scratch/retry-calls" bash "$here/operational-audit.sh" app "$scratch/retry-php" 256M fixture "$commit" $'storage\npublic/ohif' finalized > "$scratch/retry-proof"
[[ "$(cat "$scratch/retry-calls")" == 2 ]]
grep -Fxq 'runtime-audit identity=exact paths=canonical writable=yes database=persistent phase=finalized' "$scratch/retry-proof"
