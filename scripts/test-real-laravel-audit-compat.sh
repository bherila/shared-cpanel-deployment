#!/usr/bin/env bash
# Run only against the isolated application created by test-real-laravel-atomic.sh.
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" = 2 ] || exit 2
app=$1 php=$2
here=$(cd "$(dirname "$0")" && pwd)
[ "$app" = "$HOME/app" ] && [ -f "$app/bootstrap/cache/config.php" ] || exit 2
scratch=$(mktemp -d)
cp "$app/bootstrap/cache/config.php" "$scratch/original.php"
trap 'cp "$scratch/original.php" "$app/bootstrap/cache/config.php"; rm -rf "$scratch"' EXIT
# Test actual SQLite grammar quoting and prefixes, not a mock builder. These are
# disposable fixture tables, not queue payloads or production data.
(cd "$app" && "$php" /dev/stdin "$scratch/original.php" "$scratch/config.php" <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$config = require $argv[1];
$base = $config['database']['connections']['sqlite'];
$base['prefix'] = 'audit-';
$config['database']['connections']['audit-queue'] = $base;
$config['database']['connections']['audit-failed'] = $base;
$config['queue']['default'] = 'audit-selected';
$config['queue']['connections']['audit-selected'] = [
    'driver'=>'database', 'connection'=>'audit-queue', 'table'=>'main.2 jobs', 'queue'=>'default',
];
$config['queue']['failed'] = [
    'driver'=>'database-uuids', 'database'=>'audit-failed', 'table'=>'failed "history',
];
$app['config']->set('database.connections.audit-queue', $base);
$app['config']->set('database.connections.audit-failed', $base);
foreach (['audit-queue'=>['main.2 jobs', 7], 'audit-failed'=>['failed "history', 3]] as $name=>$fixture) {
    $db = $app['db']->connection($name);
    $wrapped = $db->getQueryGrammar()->wrapTable($fixture[0]);
    $db->statement('CREATE TABLE '.$wrapped.' (id INTEGER PRIMARY KEY)');
    for ($id=1; $id<=$fixture[1]; $id++) { $db->table($fixture[0])->insert(['id'=>$id]); }
}
$config['numeric_fixture'] = [PHP_INT_MIN, PHP_INT_MAX, -PHP_INT_MAX, 0, -1, 1, -0.0,
    0.0, 1.0, -1.0, PHP_FLOAT_MIN, PHP_FLOAT_MAX, -PHP_FLOAT_MAX, 5e-324, 1e-15, 1e18, 1e20];
file_put_contents($argv[2], '<?php return '.var_export($config, true).';');
PHP
)
cp "$scratch/config.php" "$app/bootstrap/cache/config.php"
# Snapshot the whole SQLite database. Every audit below must leave its bytes
# unchanged, including aggregate reads from separate queue/failed connections.
database="$app/storage/app/database.sqlite"
before=$(sha256sum "$database")
bash "$here/operational-audit.sh" app "$php" 256M >"$scratch/output"
grep -Fqx 'operational-audit pending_migrations=0 queue_driver=database queue_applicability=database pending_total=7 failed_applicability=database failed_total=3' "$scratch/output"
for driver in sync null deferred background; do
    "$php" -r '$c=require $argv[1]; $c["queue"]["connections"]["audit-selected"]["driver"]=$argv[2]; file_put_contents($argv[3],"<?php return ".var_export($c,true).";");' \
        "$scratch/config.php" "$driver" "$app/bootstrap/cache/config.php"
    bash "$here/operational-audit.sh" app "$php" 256M >"$scratch/output"
    grep -Fqx "operational-audit pending_migrations=0 queue_driver=$driver queue_applicability=no-persistent-queue pending_total=not-counted failed_applicability=database failed_total=3" "$scratch/output"
done
for number in 0 1 -1 1.0 -0.0 1.0E+20 010 08 00 -010 -00 0x10 0b10 0o10 1_000 +1 -0 01.0 1.00 1e2 1.0e+20 1.0E20 9223372036854775808 -9223372036854775808 1e309; do
    "$php" -r '$s=file_get_contents($argv[1]); $s=substr($s,0,strrpos($s,")"))."  ".var_export("bad_number",true)." => ".$argv[2].",\n);"; file_put_contents($argv[3],$s);' \
        "$scratch/config.php" "$number" "$app/bootstrap/cache/config.php"
    if bash "$here/operational-audit.sh" app "$php" 256M >"$scratch/output" 2>&1; then
        case "$number" in 0|1|-1|1.0|-0.0|1.0E+20) continue ;; esac
        echo "Noncanonical cached number $number accepted by real Laravel audit" >&2; exit 1
    fi
    case "$number" in 0|1|-1|1.0|-0.0|1.0E+20) echo 'Canonical fixture insertion failed' >&2; exit 1 ;; esac
    [ "$(wc -c <"$scratch/output")" -lt 256 ]
done
[ "$(sha256sum "$database")" = "$before" ]
echo 'Real Laravel numeric cache grammar, quoted/prefixed SQLite tables and local queue applicability passed without database writes.'
