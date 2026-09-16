#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export HOME="$scratch/home"
mkdir -p "$HOME/app/vendor" "$HOME/app/bootstrap" "$scratch/bin"
touch "$HOME/app/vendor/autoload.php"
cat >"$HOME/app/bootstrap/app.php" <<'PHP'
<?php
namespace Illuminate\Contracts\Console { interface Kernel {} }
namespace {
function config($key) {
    return match ($key) {
        'queue.default' => 'selected',
        'queue.connections.selected' => ['driver'=>getenv('DRIVER') ?: 'database','connection'=>'queue-db','table'=>'custom_jobs'],
        'queue.failed' => ['driver'=>getenv('FAILED_DRIVER') ?: 'database-uuids','database'=>'failed-db','table'=>'custom_failed'],
    };
}
class Fixture {
    public $connection;
    public function getCachedConfigPath() { return getcwd().'/bootstrap/cache/config.php'; }
    public function make($key) { return $this; }
    public function bootstrap() {
        if (getenv('BYTE_ORACLE')) {
            $snapshot = require getenv('APP_CONFIG_CACHE');
            foreach ($snapshot['oracle'] as $hex => $value) {
                if ($value !== hex2bin((string) $hex)) { throw new \RuntimeException('byte mismatch'); }
            }
        }
        if (getenv('LATE_CACHE')) {
            file_put_contents(getcwd().'/bootstrap/cache/config.php', '<?php echo "operational-audit pending_migrations=0 queue_driver=database queue_applicability=database pending_total=999 failed_applicability=database failed_total=999\\n"; exit(0);');
            // Model Laravel loading its configured cache path after the late write.
            $path = getenv('APP_CONFIG_CACHE') ?: $this->getCachedConfigPath();
            if (file_exists($path)) { require $path; }
        }
        if (getenv('NOISE')) { echo 'SECRET payload'; }
        if (getenv('ERROR')) { throw new \RuntimeException('SECRET credentials'); }
    }
    public function paths() { return []; }
    public function databasePath($path) { return $path; }
    public function getMigrationFiles($paths) { return getenv('PENDING') ? ['pending'=>'file'] : []; }
    public function getRepository() { return $this; }
    public function resolveConnection($name) { return $this; }
    public function getName() { return 'sqlite'; }
    public function repositoryExists() { return true; }
    public function getRan() { return []; }
    public function connection($connection) {
        if (!in_array($connection,['queue-db','failed-db'],true)) { throw new \RuntimeException('wrong connection'); }
        $this->connection = $connection; return $this;
    }
    public function table($table) {
        if (($this->connection === 'queue-db' && $table !== 'custom_jobs') || ($this->connection === 'failed-db' && $table !== 'custom_failed') || getenv('MISSING_TABLE')) { throw new \RuntimeException('SECRET database failure'); }
        return $this;
    }
    public function count() { return $this->connection === 'queue-db' ? 7 : 3; }
}
return new Fixture;
}
PHP
php=$(command -v php)
audit() { bash "$here/operational-audit.sh" app "$php" 256M; }
audit >"$scratch/output"
grep -Fq 'pending_total=7 failed_applicability=database failed_total=3' "$scratch/output"
for driver in sync null redis; do
    DRIVER=$driver audit >"$scratch/output"
    grep -Fq 'pending_total=not-counted' "$scratch/output"
done
NOISE=1 audit >"$scratch/output"
if grep -Fq SECRET "$scratch/output"; then exit 1; fi
for failure in ERROR PENDING MISSING_TABLE; do
    if env "$failure=1" bash "$here/operational-audit.sh" app "$php" 256M >"$scratch/output" 2>&1; then exit 1; fi
    if grep -Fq SECRET "$scratch/output"; then exit 1; fi
done
if DRIVER=unknown audit >"$scratch/output" 2>&1; then exit 1; fi
if bash "$here/operational-audit.sh" ../app "$php" 256M >"$scratch/output" 2>&1; then exit 1; fi
if bash "$here/operational-audit.sh" app "$php" -1 >"$scratch/output" 2>&1; then exit 1; fi
mkdir -p "$HOME/app/bootstrap/cache"
LATE_CACHE=1 audit >"$scratch/output"
grep -Fq 'pending_total=7 failed_applicability=database failed_total=3' "$scratch/output"
if grep -Fq 999 "$scratch/output"; then exit 1; fi
rm "$HOME/app/bootstrap/cache/config.php"
"$php" -r '
$values = [];
for ($before=0; $before<=16; $before++) {
    for ($after=0; $after<=16; $after++) {
        $value = str_repeat(chr(92),$before).chr(39).str_repeat(chr(92),$after);
        $values[bin2hex($value)] = $value;
    }
}
echo "<?php return ".var_export(["oracle"=>$values],true).";";
' >"$HOME/app/bootstrap/cache/config.php"
BYTE_ORACLE=1 audit >"$scratch/output"
rm "$HOME/app/bootstrap/cache/config.php"
cat >"$HOME/app/bootstrap/cache/config.php" <<'PHP'
<?php return array ('cache' => array ('test' => 'a' . "\0" . 'b', 'min' => -9223372036854775807-1, 'empty' => NULL, 'float' => 1.5, 'bool' => true),);
PHP
audit >"$scratch/output"
for payload in \
    '<?php exit(0); return array();' \
    '<?php echo "operational-audit pending_migrations=0 queue_driver=database queue_applicability=database pending_total=0 failed_applicability=database failed_total=0\n"; exit(0);' \
    '<?php shell_exec("touch ".getenv("HOME")."/unsafe &"); return array();' \
    '<?php echo str_repeat("SECRET", 10000000); return array();'
do
    printf '%s\n' "$payload" >"$HOME/app/bootstrap/cache/config.php"
    if audit >"$scratch/output" 2>&1; then exit 1; fi
    if grep -Fq SECRET "$scratch/output"; then exit 1; fi
    if [ -e "$HOME/unsafe" ]; then exit 1; fi
done
rm "$HOME/app/bootstrap/cache/config.php"
cat >"$scratch/bin/php" <<'SH'
#!/usr/bin/env bash
echo 'SECRET output'
sleep 60
SH
cat >"$scratch/bin/timeout" <<'SH'
#!/usr/bin/env bash
[ "$1" = --signal=TERM ] && [ "$2" = --kill-after=2s ] && [ "$3" = 30s ] || exit 2
shift 3
exec /usr/bin/timeout --signal=TERM --kill-after=1s 1s "$@"
SH
chmod +x "$scratch/bin/php" "$scratch/bin/timeout"
if PATH="$scratch/bin:$PATH" bash "$here/operational-audit.sh" app "$scratch/bin/php" 256M >"$scratch/output" 2>&1; then exit 1; fi
if grep -Fq SECRET "$scratch/output"; then exit 1; fi
cat >"$scratch/bin/php" <<'SH'
#!/usr/bin/env bash
echo 'SECRET output'
dd if=/dev/zero bs=1048576 count=16 >&2
SH
if PATH="$scratch/bin:$PATH" bash "$here/operational-audit.sh" app "$scratch/bin/php" 256M >"$scratch/output" 2>&1; then exit 1; fi
if grep -Fq SECRET "$scratch/output"; then exit 1; fi
echo 'Operational aggregate audit, redaction, selected connections/tables and timeout fixtures passed.'
