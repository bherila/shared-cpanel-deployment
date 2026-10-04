#!/usr/bin/env bash
# Read-only aggregate Laravel audit. Never relay framework output or exceptions.
set -euo pipefail
[[ "$#" -eq 3 || "$#" -eq 7 ]] || { echo '::error::Operational audit arguments invalid.' >&2; exit 2; }
app_dir=$1 php=$2 memory=${3:-256M}
release=${4:-} commit=${5:-} persistent=${6:-} phase=${7:-}
if [ "$#" -eq 7 ]; then
    [[ "$app_dir" != */* && "$release" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$commit" =~ ^[a-fA-F0-9]{40,64}$ ]] || exit 2
    [[ "$phase" = selected || "$phase" = finalized || "$phase" = generation ]] || exit 2
fi
case "$memory" in ''|-1) memory=256M ;; esac
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
# The durable generation changes under the lock at every begin, including
# transactions that later fail and restore the prior release. It distinguishes
# supersession even after the newer transaction has removed its lock/state.
generation_state() {
    local root="$HOME/.deployments/$app_dir" value directory
    for directory in "$HOME" "$HOME/.deployments" "$root"; do
        [[ -d "$directory" && ! -L "$directory" && "$(readlink -f "$directory")" = "$directory" ]] || return 1
    done
    [[ -f "$root/generation" && ! -L "$root/generation" && "$(wc -c <"$root/generation")" -le 128 ]] || return 1
    value=$(cat "$root/generation")
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    # A new owner's lock proves supersession even in the narrow interval before
    # its atomic generation rename. An ambiguous/unfinished owner fails closed.
    if [[ -e "$root/deploy.lock" || -L "$root/deploy.lock" ]]; then
        [[ -d "$root/deploy.lock" && ! -L "$root/deploy.lock" && -f "$root/deploy.lock/owner" && ! -L "$root/deploy.lock/owner" \
            && "$(wc -c <"$root/deploy.lock/owner")" -le 128 ]] || return 1
        local lock_owner
        lock_owner=$(cat "$root/deploy.lock/owner")
        [[ "$lock_owner" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
        if [ "$lock_owner" != "$release" ]; then echo superseded; return; fi
    fi
    if [ "$value" = "$release" ]; then echo current; else echo superseded; fi
}
check_generation() {
    local observed
    observed=$(generation_state) || { echo '::error::Deployment generation proof failed; diagnostics redacted.' >&2; return 1; }
    if [ "$observed" = superseded ]; then
        echo 'runtime-audit generation=superseded'
        return 10
    fi
}
if [[ "$phase" = finalized || "$phase" = generation ]]; then
    generation_status=0
    check_generation || generation_status=$?
    if [ "$generation_status" = 10 ]; then exit 0; fi
    [ "$generation_status" = 0 ] || exit 1
    if [ "$phase" = generation ]; then echo 'runtime-audit generation=current'; exit 0; fi
fi
if ! cd "$HOME/$app_dir" 2>/dev/null; then
    if [ "$phase" = finalized ] && [ "$(generation_state || true)" = superseded ]; then echo 'runtime-audit generation=superseded'; exit 0; fi
    echo '::error::Audit application directory unavailable; diagnostics redacted.' >&2; exit 1
fi
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
    $runtime = ($argv[1] ?? '') !== '';
    $key = 'config.cache'; $rootType = 'stable'; $kind = 'file'; $reason = 'invalid';
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
    if ($runtime) {
        $fail = static function (string $k, string $r, string $t, string $why) use (&$key, &$rootType, &$kind, &$reason): never {
            $key = $k; $rootType = $r; $kind = $t; $reason = $why;
            throw new RuntimeException('runtime audit');
        };
        $home = rtrim((string) getenv('HOME'), '/');
        $stable = $home.'/'.$argv[4];
        $control = $home.'/.deployments/'.$argv[4];
        $shared = $control.'/shared';
        $realDirectory = static function (string $path, string $k) use ($fail): void {
            if (!is_dir($path) || is_link($path) || realpath($path) !== $path) {
                $fail($k, 'managed', 'directory', 'noncanonical');
            }
        };
        foreach ([$home, $home.'/.deployments', $control, $shared, $control.'/releases', $control.'/state', $stable] as $path) {
            $realDirectory($path, 'deployment.root');
        }
        if (getcwd() !== $stable) { $fail('deployment.stable', 'stable', 'directory', 'identity'); }
        $metadataPath = $stable.'/.deploy-release';
        if (!is_file($metadataPath) || is_link($metadataPath) || filesize($metadataPath) > 4096) {
            $fail('deployment.metadata', 'stable', 'file', 'type');
        }
        $metadata = file_get_contents($metadataPath);
        if (!is_string($metadata) || substr_count($metadata, "release=") !== 1 || substr_count($metadata, "commit=") !== 1
            || !preg_match('/^release='.preg_quote($argv[1], '/').'$/m', $metadata)
            || !preg_match('/^commit='.preg_quote($argv[2], '/').'$/m', $metadata)) {
            $fail('deployment.metadata', 'stable', 'file', 'identity');
        }
        $links = preg_split('/\s+/', trim($argv[3]), -1, PREG_SPLIT_NO_EMPTY);
        if (!is_array($links) || $links === [] || count($links) > 64) { $fail('deployment.persistence', 'shared', 'link', 'bound'); }
        foreach ($links as $link) {
            if (!preg_match('~\A[A-Za-z0-9_-]+(?:[./][A-Za-z0-9_-]+)*\z~', $link) || str_contains($link, '..')) {
                $fail('deployment.persistence', 'shared', 'link', 'invalid');
            }
            $target = $shared.'/'.$link;
            $selected = $stable.'/'.$link;
            if (!is_link($selected) || realpath($selected) !== $target || realpath($target) !== $target
                || (!is_dir($target) && !is_file($target)) || realpath(dirname($selected)) !== dirname($selected)) {
                $fail('deployment.persistence', 'shared', 'link', 'target');
            }
        }
        if (!isset($config) || $cache !== $stable.'/bootstrap/cache/config.php' || is_link($cache)
            || realpath($cache) !== $cache || !is_file($cache)) {
            $fail('config.cache', 'stable', 'file', 'identity');
        }
        $contains = static fn (string $path, string $root): bool => $path === $root || str_starts_with($path, $root.'/');
        $directory = static function ($path, string $k, bool $writable) use ($stable, $shared, $contains, $fail): string {
            if (!is_string($path) || $path === '' || strlen($path) > 4096 || str_contains($path, "\0") || $path[0] !== '/') {
                $fail($k, 'managed', 'directory', 'type');
            }
            // Accept the exact selected persistent link, then forbid nested symlinks,
            // traversal and cached aliases into old releases, even when they resolve.
            $lexical = $contains($path, $stable) ? 'stable' : ($contains($path, $shared) ? 'shared' : 'outside');
            $real = realpath($path);
            if ($lexical === 'outside' || !is_string($real) || !is_dir($path)) { $fail($k, $lexical, 'directory', 'missing-or-outside'); }
            if (!$contains($real, $stable) && !$contains($real, $shared)) { $fail($k, $lexical, 'directory', 'escape'); }
            $expected = $path;
            foreach (preg_split('/\s+/', trim($GLOBALS['argv'][3]), -1, PREG_SPLIT_NO_EMPTY) as $link) {
                if ($contains($path, $stable.'/'.$link)) { $expected = $shared.substr($path, strlen($stable)); break; }
            }
            if ($real !== $expected) { $fail($k, $lexical, 'directory', 'noncanonical'); }
            if ($writable && !is_writable($path)) { $fail($k, $lexical, 'directory', 'unwritable'); }
            return $real;
        };
        $views = $config['view']['paths'] ?? null;
        if (!is_array($views) || $views === [] || count($views) > 64) { $fail('view.paths', 'stable', 'directory', 'type'); }
        foreach ($views as $path) { $directory($path, 'view.paths', false); }
        $directory($config['view']['compiled'] ?? null, 'view.compiled', true);
        $directory($config['session']['files'] ?? null, 'session.files', true);
        $stores = $config['cache']['stores'] ?? null;
        if (!is_array($stores) || count($stores) > 64) { $fail('cache.stores', 'managed', 'directory', 'type'); }
        $activeStores = [];
        $activate = static function ($name, int $depth = 0) use (&$activate, &$activeStores, $stores, $fail): void {
            if (!is_string($name) || !isset($stores[$name]) || $depth > 16) { $fail('cache.default', 'managed', 'store', 'type'); }
            if (isset($activeStores[$name])) { return; }
            $activeStores[$name] = true;
            if (($stores[$name]['driver'] ?? null) === 'failover') {
                $children = $stores[$name]['stores'] ?? null;
                if (!is_array($children) || count($children) > 64) { $fail('cache.failover', 'managed', 'store', 'type'); }
                foreach ($children as $child) { $activate($child, $depth + 1); }
            }
        };
        $activate($config['cache']['default'] ?? null);
        foreach ($stores as $storeName => $store) {
            if (!is_array($store)) { $fail('cache.store', 'managed', 'directory', 'type'); }
            if (($store['driver'] ?? null) === 'file') {
                $directory($store['path'] ?? null, 'cache.file.path', true);
                $directory($store['lock_path'] ?? $store['path'] ?? null, 'cache.file.lock_path', true);
            } elseif (($store['driver'] ?? null) === 'storage') {
                $relative = $store['path'] ?? '';
                if (!is_string($relative) || strlen($relative) > 4096
                    || !preg_match('~\A[A-Za-z0-9_-]+(?:[./][A-Za-z0-9_-]+)*\z~', $relative) || str_contains($relative, '..')) {
                    $fail('cache.storage.path', 'disk-relative', 'relative', 'traversal-or-type');
                }
                $diskName = $store['disk'] ?? $config['filesystems']['default'] ?? null;
                $disk = is_string($diskName) ? ($config['filesystems']['disks'][$diskName] ?? null) : null;
                if (!is_array($disk)) { $fail('cache.storage.disk', 'disk-relative', 'relative', 'type'); }
                if (($disk['driver'] ?? null) === 'local' && isset($activeStores[$storeName])) {
                    $diskRoot = $directory($disk['root'] ?? null, 'cache.storage.root', true);
                    $directory($diskRoot.'/'.$relative, 'cache.storage.path', true);
                }
            }
        }
        $channels = $config['logging']['channels'] ?? null;
        if (!is_array($channels) || count($channels) > 64) { $fail('logging.channels', 'managed', 'file', 'type'); }
        foreach ($channels as $channel) {
            if (!is_array($channel)) { $fail('logging.channel', 'managed', 'file', 'type'); }
            $path = $channel['path'] ?? null;
            $stream = $channel['handler_with']['stream'] ?? $channel['with']['stream'] ?? null;
            if ($stream !== null) {
                if (($channel['driver'] ?? null) !== 'monolog' || ($channel['handler'] ?? null) !== 'Monolog\\Handler\\StreamHandler') {
                    $fail('logging.stream', 'managed', 'stream', 'type');
                }
                if (!in_array($stream, ['php://stderr', 'php://stdout', 'php://output', '/dev/null'], true)) { $path = $stream; }
            }
            if ($path === null) { continue; }
            if (!is_string($path) || $path === '' || strlen($path) > 4096 || str_contains($path, "\0")
                || $path[0] !== '/' || str_ends_with($path, '/')) { $fail('logging.path', 'managed', 'file', 'type'); }
            $directory(dirname($path), 'logging.parent', true);
            $declaredFile = false;
            foreach ($links as $link) {
                if ($path === $stable.'/'.$link && is_link($path) && is_file($shared.'/'.$link)
                    && realpath($path) === $shared.'/'.$link) { $declaredFile = true; break; }
            }
            if ((is_link($path) && !$declaredFile) || (file_exists($path) && (!is_file($path) || !is_writable($path))) || basename($path) === '.' || basename($path) === '..') {
                $fail('logging.path', 'managed', 'file', 'type-or-unwritable');
            }
        }
        if (($argv[5] ?? '') === 'finalized') {
            if (file_exists($control.'/deploy.lock') || is_link($control.'/deploy.lock')) { $fail('deployment.lock', 'control', 'absent', 'present'); }
            $inventory = scandir($control.'/state');
            if ($inventory !== ['.', '..']) { $fail('deployment.transactions', 'control', 'empty', 'present'); }
        }
    }
    // Freeze absence too: a cache appearing at the original path after inspection
    // must never become executable input to Laravel's configuration bootstrap.
    putenv('APP_CONFIG_CACHE='.$snapshot);
    $_ENV['APP_CONFIG_CACHE'] = $_SERVER['APP_CONFIG_CACHE'] = $snapshot;
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    if ($runtime && $argv[5] === 'finalized' && $app->isDownForMaintenance()) { $fail('deployment.serving', 'stable', 'serving', 'maintenance'); }
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
    if ($runtime) {
        $databaseName = config('database.default');
        $database = is_string($databaseName) ? config('database.connections.'.$databaseName) : null;
        if (!is_array($database)) { $fail('database.default', 'managed', 'database', 'type'); }
        $dbDriver = $database['driver'] ?? null;
        if (!in_array($dbDriver, ['sqlite', 'mysql', 'mariadb', 'pgsql', 'sqlsrv'], true)) { $fail('database.driver', 'managed', 'database', 'type'); }
        if ($dbDriver === 'sqlite') {
            $dbPath = $database['database'] ?? null;
            if (!is_string($dbPath) || $dbPath === '' || strlen($dbPath) > 4096 || str_contains($dbPath, "\0")) {
                $fail('database.location', 'shared', 'file', 'type');
            }
            $dbPath = str_starts_with($dbPath, '/') ? $dbPath : $stable.'/'.$dbPath;
            $parent = $directory(dirname($dbPath), 'database.parent', true);
            if (!str_starts_with($parent, $shared.'/') || realpath($dbPath) !== $parent.'/'.basename($dbPath)
                || !is_file($dbPath) || !is_writable($dbPath)) {
                $fail('database.location', 'shared', 'file', 'nonpersistent');
            }
        } elseif (!is_string($database['database'] ?? null) || $database['database'] === '') { $fail('database.location', 'external', 'database', 'missing'); }
    }
    ob_end_clean();
    if ($runtime) { echo 'runtime-audit identity=exact paths=canonical writable=yes database=persistent phase='.$argv[5]."\n"; }
    echo 'operational-audit pending_migrations=0 queue_driver='.$driver.
        ' queue_applicability='.($driver === 'database' ? 'database' : (in_array($driver, ['sync', 'null'], true) ? 'no-persistent-queue' : 'external')).
        ' pending_total='.($pendingJobs ?? 'not-counted').
        ' failed_applicability='.$failedState.' failed_total='.($failedJobs ?? 'not-counted')."\n";
} catch (Throwable $error) {
    while (ob_get_level() > 0) { ob_end_clean(); }
    if (($runtime ?? false) && isset($key, $rootType, $kind, $reason)) {
        echo 'runtime-audit key='.$key.' root='.$rootType.' type='.$kind.' reason='.$reason."\n";
    }
    exit(1);
}
PHP
if ! (ulimit -f 8192; exec "$timeout_binary" --signal=TERM --kill-after=2s 30s "$php" -d "memory_limit=$memory" "$scratch/audit.php" "$release" "$commit" "$persistent" "$app_dir" "$phase") </dev/null >"$scratch/output" 2>"$scratch/error"; then
    if [ "$phase" = finalized ] && [ "$(generation_state || true)" = superseded ]; then
        echo 'runtime-audit generation=superseded'; exit 0
    fi
    if [ -n "$release" ] && [ "$(wc -c <"$scratch/output")" -le 512 ] && LC_ALL=C grep -Eq '^runtime-audit key=[a-z.]+ root=[a-z-]+ type=[a-z-]+ reason=[a-z-]+$' "$scratch/output"; then
        cat "$scratch/output" >&2
    fi
    echo '::error::Operational audit failed or exceeded its bound; diagnostics redacted.' >&2
    exit 1
fi
if [ "$phase" = finalized ] && [ "$(generation_state || true)" = superseded ]; then
    echo 'runtime-audit generation=superseded'; exit 0
fi
if [ -n "$release" ]; then
    expected="runtime-audit identity=exact paths=canonical writable=yes database=persistent phase=$phase"
    if [ "$(head -1 "$scratch/output")" != "$expected" ]; then
        echo '::error::Runtime audit output rejected; diagnostics redacted.' >&2
        exit 1
    fi
    head -1 "$scratch/output"
    sed -i '1d' "$scratch/output"
fi
if [ "$(wc -c <"$scratch/output")" -gt 512 ] || ! LC_ALL=C grep -Eq '^operational-audit pending_migrations=0 queue_driver=(sync|null|database|redis|sqs|beanstalkd|deferred|background|failover) queue_applicability=(database|no-persistent-queue|external) pending_total=([0-9]+|not-counted) failed_applicability=(database|disabled|external) failed_total=([0-9]+|not-counted)$' "$scratch/output" || [ "$(wc -l <"$scratch/output")" -ne 1 ]; then
    echo '::error::Operational audit output rejected; diagnostics redacted.' >&2
    exit 1
fi
cat "$scratch/output"
