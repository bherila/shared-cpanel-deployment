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
        'database.connections.sqlite' => ['driver'=>'sqlite','database'=>getenv('HOME').'/.deployments/app/shared/storage/app/database.sqlite'],
    };
}
class Fixture {
    public function getCachedConfigPath() { return getcwd().'/bootstrap/cache/config.php'; }
    public function make($key) { return $this; }
    public function bootstrap() {}
    public function paths() { return []; }
    public function databasePath($path) { return '/nonexistent/'.$path; }
    public function getMigrationFiles($paths) { return []; }
    public function getRepository() { return $this; }
    public function repositoryExists() { return true; }
    public function getRan() { return []; }
    public function resolveConnection($name) { return $this; }
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
 'cache'=>['stores'=>[
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
mkdir "$control/deploy.lock"
audit selected > /dev/null
reject finalized held-lock
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
audit finalized > /dev/null
echo 'Canonical runtime, redaction, persistence and finalization fixtures passed.'
