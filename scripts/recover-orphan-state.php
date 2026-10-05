<?php
// Filesystem-only ownership, durable evidence and rollback. Never bootstrap Laravel.
declare(strict_types=1);

final class OrphanRecoveryState
{
    private const RECORD_BOUND = 1024 * 1024;
    public readonly string $stable;
    public readonly string $control;
    public readonly string $lock;
    public readonly string $record;
    public readonly string $storage;
    public readonly string $home;

    public function __construct(
        public readonly string $app,
        public readonly string $release,
        public readonly string $commit,
        public readonly string $token,
        public readonly string $persistent,
    ) {
        if (!preg_match('/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/', $app)
            || !preg_match('/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/', $release) || str_contains($release, '..')
            || !preg_match('/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/', $commit)
            || !preg_match('/\Aorphan-[a-f0-9]{32}\z/', $token)) {
            throw new RuntimeException;
        }
        if (in_array($app, ['public_html', 'www', 'web', 'mail', 'etc', 'logs', 'tmp', 'ssl', 'cache', 'bin', 'lib', 'perl5', 'access-logs', 'lscache', 'backups'], true)) {
            throw new RuntimeException;
        }
        $this->home = rtrim((string) getenv('HOME'), '/');
        $this->stable = $this->home.'/'.$app;
        $this->control = $this->home.'/.deployments/'.$app;
        $this->lock = $this->control.'/deploy.lock';
        $this->record = $this->control.'/recovery/'.$token;
        $this->storage = $this->control.'/shared/storage';
    }

    public static function directory(string $path): array
    {
        clearstatcache(true, $path);
        if (!is_dir($path) || is_link($path) || realpath($path) !== $path) {
            throw new RuntimeException;
        }
        $stat = stat($path);
        return [$stat['dev'], $stat['ino']];
    }

    public static function bytes(string $path, int $bound): string
    {
        clearstatcache(true, $path);
        if (!is_file($path) || is_link($path) || realpath($path) !== $path || filesize($path) > $bound) {
            throw new RuntimeException;
        }
        $bytes = file_get_contents($path, false, null, 0, $bound + 1);
        if (!is_string($bytes) || strlen($bytes) > $bound) {
            throw new RuntimeException;
        }
        return $bytes;
    }

    private function roots(): array
    {
        $roots = [];
        foreach ([$this->home, $this->home.'/.deployments', $this->control,
            $this->control.'/releases', $this->control.'/state', $this->control.'/shared',
            $this->storage, $this->storage.'/framework', $this->storage.'/framework/cache', $this->stable,
            $this->stable.'/bootstrap', $this->stable.'/bootstrap/cache'] as $path) {
            $roots[$path] = self::directory($path);
        }
        if (scandir($this->control.'/state') !== ['.', '..']) {
            throw new RuntimeException;
        }
        foreach ([$this->control, $this->control.'/releases'] as $parent) {
            $entries = scandir($parent);
            if (!is_array($entries) || count($entries) > 10000) { throw new RuntimeException; }
            foreach ($entries as $entry) {
                if (str_starts_with($entry, '.begin-cleanup-')) { throw new RuntimeException; }
            }
        }
        $paths = preg_split('/\s+/', trim($this->persistent), -1, PREG_SPLIT_NO_EMPTY);
        if (!$paths || count($paths) > 32 || !in_array('storage', $paths, true) || count(array_unique($paths)) !== count($paths)) {
            throw new RuntimeException;
        }
        foreach ($paths as $path) {
            if (!preg_match('~\A[A-Za-z0-9_-]+(?:[./][A-Za-z0-9_-]+)*\z~', $path)
                || str_contains($path, '..') || !is_link($this->stable.'/'.$path)
                || preg_match('~\A(?:artisan|composer\.(?:json|lock)|package(?:-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|vite\.config\.[^/]+|webpack\.mix\.js|phpunit\.xml(?:\.dist)?)\z|\A(?:app|bootstrap|config|routes|resources|vendor)(?:/|\z)|\Apublic(?:\z|/(?:index\.php|\.htaccess)\z|/build(?:/|\z))|\Adatabase(?:\z|/(?:migrations|seeders|factories)(?:/|\z))|\.sqlite(?:-journal|-wal|-shm)?\z~', $path)) {
                throw new RuntimeException;
            }
            $parent = dirname($this->stable.'/'.$path);
            self::directory($parent);
            $target = $this->control.'/shared/'.$path;
            if (realpath($this->stable.'/'.$path) !== $target || realpath($target) !== $target
                || (!is_dir($target) && !is_file($target))) {
                throw new RuntimeException;
            }
            $stat = stat($target);
            $roots[$target] = [$stat['dev'], $stat['ino']];
        }
        return $roots;
    }

    private function identity(): array
    {
        $metadata = self::bytes($this->stable.'/.deploy-release', 4096);
        preg_match_all('/^release=(.*)$/m', $metadata, $releases);
        preg_match_all('/^commit=(.*)$/m', $metadata, $commits);
        if ($releases[1] !== [$this->release] || $commits[1] !== [$this->commit]
            || substr_count($metadata, 'release=') !== 1 || substr_count($metadata, 'commit=') !== 1) {
            throw new RuntimeException;
        }
        $hashes = [];
        foreach (['.deploy-release', '.env', 'artisan', 'bootstrap/app.php', 'vendor/autoload.php'] as $path) {
            $hashes[$path] = hash('sha256', self::bytes($this->stable.'/'.$path, 4 * 1024 * 1024));
        }
        $environmentFiles = glob($this->stable.'/.env.*');
        if (!is_array($environmentFiles) || count($environmentFiles) > 32) { throw new RuntimeException; }
        foreach ($environmentFiles as $path) {
            $hashes[basename($path)] = hash('sha256', self::bytes($path, 4 * 1024 * 1024));
        }
        return $hashes;
    }

    public function cacheDestinations(): void
    {
        self::directory($this->stable.'/bootstrap/cache');
        foreach (['config.php', 'services.php', 'packages.php', 'routes-v7.php', 'events.php'] as $file) {
            $path = $this->stable.'/bootstrap/cache/'.$file;
            if (is_link($path) || (file_exists($path) && (!is_file($path) || realpath($path) !== $path))) {
                throw new RuntimeException;
            }
        }
        self::directory($this->storage.'/framework/cache');
        $facades = glob($this->storage.'/framework/cache/facade-*.php');
        if (!is_array($facades) || count($facades) > 1000) { throw new RuntimeException; }
        foreach ($facades as $path) {
            if (!preg_match('/\Afacade-[a-f0-9]{40}\.php\z/', basename($path))) { throw new RuntimeException; }
            self::bytes($path, 65536);
        }
    }

    private function marker(string $name, bool $optional = false): ?array
    {
        $path = $this->storage.'/framework/'.$name;
        if ($optional && !file_exists($path) && !is_link($path)) {
            return null;
        }
        $bytes = self::bytes($path, 32768);
        if ($name === 'down') {
            $data = json_decode($bytes, true, 16, JSON_THROW_ON_ERROR);
            if (!is_array($data) || array_is_list($data) || !isset($data['status'])
                || !is_int($data['status']) || $data['status'] < 400 || $data['status'] > 599) {
                throw new RuntimeException;
            }
        }
        $stat = stat($path);
        return ['bytes' => base64_encode($bytes), 'hash' => hash('sha256', $bytes), 'mode' => $stat['mode'] & 0777,
            'id' => [$stat['dev'], $stat['ino']], 'mtime' => $stat['mtime']];
    }

    public function inspect(): array
    {
        $roots = $this->roots();
        $identity = $this->identity();
        $this->cacheDestinations();
        if (file_exists($this->lock) || is_link($this->lock)) {
            throw new RuntimeException;
        }
        return ['version' => 1, 'app' => $this->app, 'release' => $this->release,
            'commit' => $this->commit, 'token' => $this->token, 'persistent' => $this->persistent,
            'roots' => $roots, 'identity' => $identity, 'down' => $this->marker('down'),
            'rendered' => $this->marker('maintenance.php', true), 'phase' => 'prepared', 'lock' => null];
    }

    public function preflight(string $snapshot): void
    {
        if ($snapshot !== __DIR__.'/preflight-record.json') { throw new RuntimeException; }
        self::directory(dirname($snapshot));
        $bytes = json_encode($this->inspect(), JSON_THROW_ON_ERROR);
        if (strlen($bytes) > self::RECORD_BOUND) { throw new RuntimeException; }
        self::write($snapshot, $bytes);
    }

    private static function write(string $path, string $bytes, int $mode = 0600): void
    {
        $temporary = dirname($path).'/.orphan-'.bin2hex(random_bytes(16));
        $handle = fopen($temporary, 'x');
        if (!$handle) {
            throw new RuntimeException;
        }
        try {
            if (!chmod($temporary, $mode) || fwrite($handle, $bytes) !== strlen($bytes)
                || !fflush($handle) || !fsync($handle)) {
                throw new RuntimeException;
            }
            fclose($handle);
            $handle = null;
            if (is_link($path) || (file_exists($path) && !is_file($path)) || !rename($temporary, $path)) {
                throw new RuntimeException;
            }
        } finally {
            if (is_resource($handle)) {
                fclose($handle);
            }
            if (is_file($temporary)) {
                unlink($temporary);
            }
        }
    }

    public function save(array $record): void
    {
        self::directory($this->record);
        $bytes = json_encode($record, JSON_THROW_ON_ERROR);
        if (strlen($bytes) > self::RECORD_BOUND) { throw new RuntimeException; }
        self::write($this->record.'/record.json', $bytes);
    }

    public function load(): array
    {
        self::directory($this->control.'/recovery');
        self::directory($this->record);
        if ((fileperms($this->record) & 0777) !== 0700 || (fileperms($this->record.'/record.json') & 0777) !== 0600) {
            throw new RuntimeException;
        }
        $record = json_decode(self::bytes($this->record.'/record.json', self::RECORD_BOUND), true, 32, JSON_THROW_ON_ERROR);
        foreach (['app', 'release', 'commit', 'token', 'persistent'] as $key) {
            if (($record[$key] ?? null) !== $this->$key) {
                throw new RuntimeException;
            }
        }
        if (($record['version'] ?? null) !== 1 || !is_array($record['lock'] ?? null)) {
            throw new RuntimeException;
        }
        return $record;
    }

    public function owned(string $maintenance = 'either'): array
    {
        $record = $this->load();
        if ($record['roots'] !== $this->roots() || $record['identity'] !== $this->identity()
            || $record['lock'] !== self::directory($this->lock)) {
            throw new RuntimeException;
        }
        $inventory = scandir($this->lock);
        if (in_array($record['phase'], ['acquired', 'release-armed-up', 'release-armed-down'], true) && $inventory === ['.', '..']) {
            // A persisted inode proves this exact empty partial initialization.
        } elseif ($inventory !== ['.', '..', 'owner'] || self::bytes($this->lock.'/owner', 128) !== $this->token."\n") {
            throw new RuntimeException;
        }
        foreach (['down' => 'down', 'rendered' => 'maintenance.php'] as $key => $name) {
            $now = $this->marker($name, true);
            $expected = $record['pendingMarkers'][$key] ?? $record['restoredMarkers'][$key] ?? $record[$key];
            if ($now !== null && $now !== $expected) {
                throw new RuntimeException;
            }
            if ($now === null && $record[$key] !== null
                && !in_array($record['phase'], ['up-armed', 'serving', 'verifying', 'restoring', 'restored', 'release-armed-up'], true)) {
                throw new RuntimeException;
            }
            if ($key === 'down' && (($maintenance === 'present' && $now === null)
                || ($maintenance === 'absent' && $now !== null))) {
                throw new RuntimeException;
            }
        }
        if (isset($record['private'])) {
            if ($record['private'] !== $this->privateSnapshot()) { throw new RuntimeException; }
        }
        if (isset($record['configHash']) && hash('sha256', self::bytes($this->stable.'/bootstrap/cache/config.php', 4 * 1024 * 1024)) !== $record['configHash']) {
            throw new RuntimeException;
        }
        if (isset($record['cacheHashes'])) {
            foreach ($record['cacheHashes'] as $leaf => $expected) {
                if (!in_array($leaf, ['config.php', 'services.php', 'packages.php', 'routes-v7.php', 'events.php'], true)) { throw new RuntimeException; }
                $path = $this->stable.'/bootstrap/cache/'.$leaf;
                if ($expected === null) {
                    if (file_exists($path) || is_link($path)) { throw new RuntimeException; }
                } elseif (hash('sha256', self::bytes($path, 4 * 1024 * 1024)) !== $expected) { throw new RuntimeException; }
            }
        }
        return $record;
    }

    public function initialize(string $preflight): void
    {
        umask(0077);
        $record = $this->inspect();
        $expected = json_decode(self::bytes($preflight, self::RECORD_BOUND), true, 32, JSON_THROW_ON_ERROR);
        if ($expected !== $record) { throw new RuntimeException; }
        $root = $this->control.'/recovery';
        if (!file_exists($root) && !is_link($root) && !mkdir($root, 0700)) {
            throw new RuntimeException;
        }
        self::directory($root);
        if (!mkdir($this->record, 0700)) {
            throw new RuntimeException;
        }
        $this->save($record);
        if (!mkdir($this->lock, 0700)) {
            throw new RuntimeException;
        }
        $record['lock'] = self::directory($this->lock);
        $record['phase'] = 'acquired';
        $this->save($record);
        $owner = fopen($this->lock.'/owner', 'x');
        if (!$owner || fwrite($owner, $this->token."\n") !== strlen($this->token) + 1 || !fflush($owner) || !fsync($owner)) {
            throw new RuntimeException;
        }
        fclose($owner);
        $record['phase'] = 'owned';
        $this->save($record);
        $this->owned('present');
        // Recovery supersedes earlier post-finalizer observations even if it rolls back.
        if (is_link($this->control.'/generation')) {
            throw new RuntimeException;
        }
        self::write($this->control.'/generation', $this->token."\n");
    }

    public function phase(string $phase): void
    {
        if (!in_array($phase, ['prepared-cache', 'up-armed', 'serving', 'verifying'], true)) {
            throw new RuntimeException;
        }
        $record = $this->owned(in_array($phase, ['prepared-cache', 'up-armed'], true) ? 'present' : 'absent');
        $previous = ['prepared-cache' => 'owned', 'up-armed' => 'prepared-cache', 'serving' => 'up-armed', 'verifying' => 'serving'];
        if ($record['phase'] !== $previous[$phase]) {
            throw new RuntimeException;
        }
        $record['phase'] = $phase;
        if ($phase === 'prepared-cache') {
            $record['configHash'] = hash('sha256', self::bytes($this->stable.'/bootstrap/cache/config.php', 4 * 1024 * 1024));
            foreach (['config.php', 'services.php', 'packages.php', 'routes-v7.php', 'events.php'] as $leaf) {
                $path = $this->stable.'/bootstrap/cache/'.$leaf;
                $record['cacheHashes'][$leaf] = file_exists($path) || is_link($path)
                    ? hash('sha256', self::bytes($path, 4 * 1024 * 1024)) : null;
            }
            $record['private'] = $this->privateSnapshot();
        }
        $this->save($record);
    }

    public function restore(): void
    {
        $record = $this->owned();
        if (scandir($this->lock) === ['.', '..']) {
            $owner = fopen($this->lock.'/owner', 'x');
            if (!$owner || fwrite($owner, $this->token."\n") !== strlen($this->token) + 1) {
                throw new RuntimeException;
            }
            fclose($owner);
        }
        $record['phase'] = 'restoring';
        $this->save($record);
        // Re-prove immediately before each write. No Artisan or application bootstrap.
        foreach (['rendered' => 'maintenance.php', 'down' => 'down'] as $key => $name) {
            $this->owned();
            if (isset($record['pendingTemporary'][$key]) && !isset($record['pendingMarkers'][$key])
                && $this->marker($name, true) !== null) { throw new RuntimeException; }
            if ($record[$key] !== null && $this->marker($name, true) === null) {
                if (!isset($record['pendingMarkers'][$key])) {
                    $bytes = base64_decode($record[$key]['bytes'], true);
                    if (!is_string($bytes) || hash('sha256', $bytes) !== $record[$key]['hash']) { throw new RuntimeException; }
                    if (!isset($record['pendingTemporary'][$key])) {
                        $record['pendingTemporary'][$key] = '.orphan-restore-'.bin2hex(random_bytes(16));
                        $this->save($record); // Durable intent before even an empty file exists.
                    }
                    $temporaryName = $record['pendingTemporary'][$key];
                    if (!is_string($temporaryName) || !preg_match('/\A\.orphan-restore-[a-f0-9]{32}\z/', $temporaryName)) { throw new RuntimeException; }
                    $temporary = $this->storage.'/framework/'.$temporaryName;
                    $this->owned();
                    if (!isset($record['temporaryIds'][$key])) {
                        // A kill before inode persistence leaves a referenced empty
                        // private file. Its ownership is unprovable: retain, never adopt.
                        if (file_exists($temporary) || is_link($temporary)) { throw new RuntimeException; }
                        $handle = fopen($temporary, 'x');
                        if (!$handle || !chmod($temporary, 0600)) { throw new RuntimeException; }
                        $stat = fstat($handle);
                        $record['temporaryIds'][$key] = [$stat['dev'], $stat['ino']];
                        $this->save($record); // Persist the inode before writing secrets.
                    } else {
                        self::bytes($temporary, 32768);
                        $handle = fopen($temporary, 'r+');
                        if (!$handle) { throw new RuntimeException; }
                    }
                    try {
                        $stat = fstat($handle);
                        if ([$stat['dev'], $stat['ino']] !== $record['temporaryIds'][$key]) { throw new RuntimeException; }
                        $this->owned();
                        self::bytes($temporary, 32768);
                        $stat = stat($temporary);
                        if ([$stat['dev'], $stat['ino']] !== $record['temporaryIds'][$key] || !chmod($temporary, 0600)) { throw new RuntimeException; }
                        if (!ftruncate($handle, 0) || !rewind($handle) || fwrite($handle, $bytes) !== strlen($bytes)
                            || !fflush($handle) || !fsync($handle)) { throw new RuntimeException; }
                    } finally {
                        fclose($handle);
                    }
                    $this->owned();
                    self::bytes($temporary, 32768);
                    $stat = stat($temporary);
                    if ([$stat['dev'], $stat['ino']] !== $record['temporaryIds'][$key]
                        || !chmod($temporary, $record[$key]['mode']) || !touch($temporary, $record[$key]['mtime'])) { throw new RuntimeException; }
                    $record['pendingMarkers'][$key] = array_replace($record[$key], ['id' => $record['temporaryIds'][$key]]);
                    if ($this->marker($temporaryName, true) !== $record['pendingMarkers'][$key]) { throw new RuntimeException; }
                    $this->save($record);
                }
                $temporaryName = $record['pendingTemporary'][$key] ?? '';
                if (!is_string($temporaryName) || !preg_match('/\A\.orphan-restore-[a-f0-9]{32}\z/', $temporaryName)
                    || $this->marker($temporaryName, true) !== $record['pendingMarkers'][$key]) { throw new RuntimeException; }
                $temporary = $this->storage.'/framework/'.$temporaryName;
                $this->owned();
                // link is exclusive: a later operator marker is never overwritten.
                if (!link($temporary, $this->storage.'/framework/'.$name)) { throw new RuntimeException; }
            }
            if (isset($record['pendingMarkers'][$key])) {
                $this->owned();
                $temporaryName = $record['pendingTemporary'][$key] ?? '';
                if (!is_string($temporaryName) || !preg_match('/\A\.orphan-restore-[a-f0-9]{32}\z/', $temporaryName)) { throw new RuntimeException; }
                $temporary = $this->storage.'/framework/'.$temporaryName;
                if (file_exists($temporary) || is_link($temporary)) {
                    if ($this->marker($temporaryName, true) !== $record['pendingMarkers'][$key] || !unlink($temporary)) { throw new RuntimeException; }
                }
                $record['restoredMarkers'][$key] = $record['pendingMarkers'][$key];
                unset($record['pendingMarkers'][$key], $record['pendingTemporary'][$key], $record['temporaryIds'][$key]);
                $this->save($record);
            }
        }
        $this->owned('present');
        $record['phase'] = 'restored';
        $this->save($record);
    }

    public function cronPaused(string $file): void
    {
        $rows = self::bytes($file, 1024 * 1024);
        $home = preg_quote($this->home, '~');
        $app = preg_quote($this->app, '~');
        if (preg_match('~(?:\$HOME|\$\{HOME\}|'. $home .'|\\~)["\x27]?/'.$app.'(?=/|[\s"\x27;]|\z)|#\s*JOB:'.$app.'(?:-|\s|\z)~', $rows)) {
            throw new RuntimeException;
        }
    }

    public function privateSnapshot(): array
    {
        $private = $this->record.'/framework';
        $snapshot = ['root' => self::directory($private), 'files' => []];
        $files = scandir($private);
        if (!is_array($files) || count($files) > 1008) { throw new RuntimeException; }
        foreach ($files as $leaf) {
            if ($leaf === '.' || $leaf === '..') { continue; }
            if (!in_array($leaf, ['config.php', 'services.php', 'packages.php', 'routes.php', 'events.php'], true)
                && !preg_match('/\Afacade-[a-f0-9]{40}\.php\z/', $leaf)) { throw new RuntimeException; }
            $path = $private.'/'.$leaf;
            $bytes = self::bytes($path, str_starts_with($leaf, 'facade-') ? 65536 : 4 * 1024 * 1024);
            $stat = stat($path);
            $snapshot['files'][$leaf] = ['id' => [$stat['dev'], $stat['ino']], 'hash' => hash('sha256', $bytes)];
        }
        return $snapshot;
    }

    public function release(bool $serving): void
    {
        $record = $this->owned($serving ? 'absent' : 'present');
        if (!empty($record['pendingTemporary']) || !empty($record['pendingMarkers']) || !empty($record['temporaryIds'])) {
            throw new RuntimeException;
        }
        if ($serving && $record['phase'] !== 'verifying') {
            throw new RuntimeException;
        }
        if (!$serving && $record['phase'] !== 'restored') {
            throw new RuntimeException;
        }
        $record['phase'] = $serving ? 'release-armed-up' : 'release-armed-down';
        $this->save($record);
        if (file_exists($this->lock.'/owner')) {
            if (!unlink($this->lock.'/owner')) {
                throw new RuntimeException;
            }
        }
        if (self::directory($this->lock) !== $record['lock'] || scandir($this->lock) !== ['.', '..']) {
            throw new RuntimeException;
        }
        if (!rmdir($this->lock)) {
            // Re-establish exact owner only if the original inode is still present.
            if (self::directory($this->lock) === $record['lock'] && !file_exists($this->lock.'/owner') && !is_link($this->lock.'/owner')) {
                $owner = fopen($this->lock.'/owner', 'x');
                if ($owner) {
                    fwrite($owner, $this->token."\n");
                    fclose($owner);
                }
            }
            throw new RuntimeException;
        }
    }
}

if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    try {
        [, $mode, $app, $release, $commit, $token, $persistent] = $argv;
        $state = new OrphanRecoveryState($app, $release, $commit, $token, $persistent);
        match ($mode) {
            'inspect' => empty($argv[7]) ? $state->inspect() : $state->preflight($argv[7]),
            'initialize' => $state->initialize($argv[7]),
            'owned-down' => $state->owned('present'), 'owned-up' => $state->owned('absent'),
            'restore' => $state->restore(), 'release-down' => $state->release(false),
            'release-up' => $state->release(true),
            'cron-paused' => $state->cronPaused($argv[7]),
            default => $state->phase($mode),
        };
        echo "orphan-recovery state=validated\n";
    } catch (Throwable) {
        exit(1);
    }
}
