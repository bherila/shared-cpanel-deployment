#!/usr/bin/env bash
# Read-only aggregate Laravel audit. Never relay framework output or exceptions.
set -euo pipefail
[ "$#" -eq 3 ] || { echo '::error::Operational audit arguments invalid.' >&2; exit 2; }
app_dir=$1 php=$2 memory=${3:-256M}
[ -n "$memory" ] || memory=256M
case "$app_dir" in
    ''|.|..|/*|*..*|*[!A-Za-z0-9._/-]*) exit 2 ;;
    .deployments/*/releases/*)
        IFS=/ read -r prefix app component release extra <<<"$app_dir"
        [ "$prefix" = .deployments ] && [ "$component" = releases ] && [ -n "$app" ] && [ -n "$release" ] && [ -z "$extra" ] || exit 2 ;;
    .*|*/*) exit 2 ;;
esac
[[ "$php" = /* && -x "$php" && "$memory" =~ ^[1-9][0-9]*[KMGkmg]$ ]] || exit 2
timeout_binary=$(command -v timeout)
[[ "$timeout_binary" = /* && -x "$timeout_binary" ]] || exit 2
cd "$HOME/$app_dir"
[ -f vendor/autoload.php ] && [ -f bootstrap/app.php ] || exit 1
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
umask 077
# File-backed I/O prevents an orphan descendant keeping an SSH output pipe open.
cat >"$scratch/audit.php" <<'PHP'
<?php
declare(strict_types=1);
ini_set('display_errors', '0');
ini_set('log_errors', '0');
try {
    ob_start();
    foreach (['SERVICES', 'PACKAGES', 'ROUTES', 'EVENTS'] as $kind) {
        $private = __DIR__.'/'.strtolower($kind).'.php';
        putenv('APP_'.$kind.'_CACHE='.$private);
        $_ENV['APP_'.$kind.'_CACHE'] = $_SERVER['APP_'.$kind.'_CACHE'] = $private;
    }
    require getcwd().'/vendor/autoload.php';
    if (class_exists(Illuminate\Foundation\AliasLoader::class)) {
        class PrivateAuditAliasLoader extends Illuminate\Foundation\AliasLoader {
            public function __construct(array $aliases) { $this->aliases = $aliases; }
            protected function ensureFacadeExists($alias) {
                if (!is_string($alias) || !preg_match('/\A[A-Za-z_][A-Za-z0-9_]*(?:\\\\[A-Za-z_][A-Za-z0-9_]*)+\z/', $alias)
                    || !preg_match('/\A(?:[A-Za-z_][A-Za-z0-9_]*\\\\)+\z/', static::$facadeNamespace)) {
                    throw new RuntimeException('invalid facade namespace');
                }
                $framework = (new ReflectionClass(Illuminate\Foundation\AliasLoader::class))->getFileName();
                if (!is_string($framework)) { throw new RuntimeException('framework stub'); }
                $stub = file_get_contents(dirname($framework).'/stubs/facade.stub', false, null, 0, 65537);
                if (!is_string($stub) || strlen($stub) > 65536) { throw new RuntimeException('facade bound'); }
                $stub = $this->formatFacadeStub($alias, $stub);
                $path = __DIR__.'/facade-'.sha1($alias).'.php';
                if (strlen($stub) > 65536 || file_put_contents($path, $stub) !== strlen($stub)) {
                    throw new RuntimeException('facade write');
                }
                return $path;
            }
        }
        $old = Illuminate\Foundation\AliasLoader::getInstance();
        foreach (spl_autoload_functions() ?: [] as $loader) {
            if ((is_array($loader) && ($loader[0] ?? null) === $old && ($loader[1] ?? null) === 'load')
                || ($loader instanceof Closure && (new ReflectionFunction($loader))->getClosureThis() === $old)) {
                if (!spl_autoload_unregister($loader)) { throw new RuntimeException('old alias loader'); }
            }
        }
        Illuminate\Foundation\AliasLoader::setInstance(new PrivateAuditAliasLoader($old->getAliases()));
    }
    $app = require getcwd().'/bootstrap/app.php';
    // Application source is trusted; generated cached PHP is data, not code.
    // Decode first, then give Laravel an immutable regenerated scalar snapshot,
    // preventing validation/re-require races on the original cache file.
    $decode = static function (string $source): array {
        $tokens = array_values(array_filter(token_get_all($source),
            static fn ($token): bool => !is_array($token) || $token[0] !== T_WHITESPACE));
        if (count($tokens) > 200000) { throw new RuntimeException('token bound'); }
        $offset = 0; $nodes = 0;
        $take = static function ($expected) use (&$tokens, &$offset): void {
            $token = $tokens[$offset++] ?? null;
            if ((is_int($expected) ? (is_array($token) ? $token[0] : null) : $token) !== $expected) {
                throw new RuntimeException('data token');
            }
        };
        $value = static function (int $depth) use (&$value, &$tokens, &$offset, &$nodes, $take) {
            if ($depth > 64 || ++$nodes > 50000) { throw new RuntimeException('data bound'); }
            $token = $tokens[$offset] ?? null;
            if (is_array($token) && $token[0] === T_ARRAY) {
                $take(T_ARRAY); $take('('); $result = [];
                while (($tokens[$offset] ?? null) !== ')') {
                    $key = $value($depth + 1);
                    if ((!is_int($key) && !is_string($key)) || array_key_exists($key, $result)) {
                        throw new RuntimeException('array key');
                    }
                    $take(T_DOUBLE_ARROW); $result[$key] = $value($depth + 1);
                    if (($tokens[$offset] ?? null) === ')') { break; }
                    $take(',');
                }
                $take(')'); return $result;
            }
            if (is_array($token) && $token[0] === T_CONSTANT_ENCAPSED_STRING) {
                $string = '';
                do {
                    $token = $tokens[$offset++] ?? null;
                    if (!is_array($token) || $token[0] !== T_CONSTANT_ENCAPSED_STRING) {
                        throw new RuntimeException('string data');
                    }
                    if (str_starts_with($token[1], "'")) {
                        $string .= str_replace(["\\\\", "\\'"], ["\\", "'"], substr($token[1], 1, -1));
                    } elseif ($token[1] === '"\\0"') { $string .= "\0"; }
                    else { throw new RuntimeException('string data'); }
                    if (($tokens[$offset] ?? null) !== '.') { break; }
                    $take('.');
                } while (true);
                return $string;
            }
            if ($token === '-') { $offset++; $token = $tokens[$offset] ?? null; $sign = '-'; }
            else { $sign = ''; }
            if (is_array($token) && in_array($token[0], [T_LNUMBER, T_DNUMBER], true)) {
                $offset++; $number = $sign.$token[1];
                if (!preg_match('/^-?[0-9]+(?:\.[0-9]+)?(?:E[+-]?[0-9]+)?$/i', $number)) {
                    throw new RuntimeException('numeric data');
                }
                $integer = filter_var($number, FILTER_VALIDATE_INT);
                $one = $tokens[$offset + 1] ?? null;
                if ($integer === -PHP_INT_MAX && ($tokens[$offset] ?? null) === '-'
                    && is_array($one) && $one[0] === T_LNUMBER && $one[1] === '1') {
                    $offset += 2; return PHP_INT_MIN;
                }
                if ($integer !== false) { return $integer; }
                $float = (float) $number;
                if (!is_finite($float)) { throw new RuntimeException('nonfinite data'); }
                return $float;
            }
            if ($sign === '' && is_array($token) && $token[0] === T_STRING) {
                $offset++;
                return match (strtolower($token[1])) {
                    'true' => true, 'false' => false, 'null' => null,
                    default => throw new RuntimeException('executable cache'),
                };
            }
            throw new RuntimeException('executable cache');
        };
        $take(T_OPEN_TAG); $take(T_RETURN); $result = $value(0); $take(';');
        if ($offset !== count($tokens) || !is_array($result)) { throw new RuntimeException('cached array'); }
        return $result;
    };
    $cache = $app->getCachedConfigPath();
    $snapshot = __DIR__.'/config.php';
    if (file_exists($cache) || is_link($cache)) {
        if (is_link($cache) || !is_file($cache)) { throw new RuntimeException('cache file'); }
        $source = file_get_contents($cache, false, null, 0, 4 * 1024 * 1024 + 1);
        if (!is_string($source) || strlen($source) > 4 * 1024 * 1024) { throw new RuntimeException('cache bound'); }
        $config = $decode($source);
        if (file_put_contents($snapshot, '<?php return '.var_export($config, true).';') === false) {
            throw new RuntimeException('snapshot');
        }
    }
    // Freeze absence too: a cache appearing at the original path after inspection
    // must never become executable input to Laravel's configuration bootstrap.
    putenv('APP_CONFIG_CACHE='.$snapshot);
    $_ENV['APP_CONFIG_CACHE'] = $_SERVER['APP_CONFIG_CACHE'] = $snapshot;
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    $migrator = $app->make('migrator');
    $paths = array_merge($migrator->paths(), [$app->databasePath('migrations')]);
    $files = $migrator->getMigrationFiles($paths);
    $repository = $migrator->getRepository();
    $ran = $repository->repositoryExists() ? $repository->getRan() : [];
    if ($ran === []) {
        $connection = $migrator->resolveConnection(null);
        $dump = $app->databasePath('schema/'.$connection->getName().'-schema.dump');
        $schema = file_exists($dump) ? $dump : $app->databasePath('schema/'.$connection->getName().'-schema.sql');
        if (!$connection instanceof Illuminate\Database\SqlServerConnection && is_file($schema)) {
            throw new RuntimeException('unapplied stored schema');
        }
    }
    $pending = count(array_diff(array_keys($files), $ran));
    if ($pending !== 0) { throw new RuntimeException('pending migrations'); }
    $connectionName = config('queue.default');
    if (!is_string($connectionName)) { throw new RuntimeException('queue configuration'); }
    $queue = config('queue.connections.'.$connectionName);
    if (!is_array($queue)) { throw new RuntimeException('queue configuration'); }
    $driver = $queue['driver'] ?? null;
    $drivers = ['sync', 'null', 'database', 'redis', 'sqs', 'beanstalkd', 'deferred', 'background', 'failover'];
    if (!in_array($driver, $drivers, true)) { throw new RuntimeException('unsupported queue'); }
    $count = static function ($connection, $table) use ($app): int {
        if ((!is_string($connection) && $connection !== null) || !is_string($table) || !preg_match('/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/', $table)) {
            throw new RuntimeException('database configuration');
        }
        return (int) $app->make('db')->connection($connection)->table($table)->count();
    };
    $pendingJobs = $driver === 'database' ? $count($queue['connection'] ?? null, $queue['table'] ?? 'jobs') : null;
    $failed = config('queue.failed');
    if (!is_array($failed)) { throw new RuntimeException('failed queue configuration'); }
    $failedDriver = $failed['driver'] ?? null;
    if (in_array($failedDriver, ['database', 'database-uuids'], true)) {
        $failedJobs = $count($failed['database'] ?? null, $failed['table'] ?? 'failed_jobs');
        $failedState = 'database';
    } elseif ($failedDriver === null || $failedDriver === 'null') {
        $failedJobs = null;
        $failedState = 'disabled';
    } elseif ($failedDriver === 'dynamodb') {
        $failedJobs = null;
        $failedState = 'external';
    } else { throw new RuntimeException('unsupported failed queue'); }
    ob_end_clean();
    echo 'operational-audit pending_migrations=0 queue_driver='.$driver.
        ' queue_applicability='.($driver === 'database' ? 'database' : (in_array($driver, ['sync', 'null'], true) ? 'no-persistent-queue' : 'external')).
        ' pending_total='.($pendingJobs ?? 'not-counted').
        ' failed_applicability='.$failedState.' failed_total='.($failedJobs ?? 'not-counted')."\n";
} catch (Throwable $error) {
    while (ob_get_level() > 0) { ob_end_clean(); }
    exit(1);
}
PHP
if ! (ulimit -f 8192; exec "$timeout_binary" --signal=TERM --kill-after=2s 30s "$php" -d "memory_limit=$memory" "$scratch/audit.php") </dev/null >"$scratch/output" 2>"$scratch/error"; then
    echo '::error::Operational audit failed or exceeded its bound; diagnostics redacted.' >&2
    exit 1
fi
if [ "$(wc -c <"$scratch/output")" -gt 512 ] || ! LC_ALL=C grep -Eq '^operational-audit pending_migrations=0 queue_driver=(sync|null|database|redis|sqs|beanstalkd|deferred|background|failover) queue_applicability=(database|no-persistent-queue|external) pending_total=([0-9]+|not-counted) failed_applicability=(database|disabled|external) failed_total=([0-9]+|not-counted)$' "$scratch/output" || [ "$(wc -l <"$scratch/output")" -ne 1 ]; then
    echo '::error::Operational audit output rejected; diagnostics redacted.' >&2
    exit 1
fi
cat "$scratch/output"
