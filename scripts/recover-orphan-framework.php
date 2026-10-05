<?php
// Trusted source bootstrap with private generated caches; never load old cached PHP.
declare(strict_types=1);

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Encryption\Encrypter;
use Illuminate\Foundation\AliasLoader;
use Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables;
use Illuminate\Foundation\Bootstrap\LoadConfiguration;
use Illuminate\Support\Env;

require __DIR__.'/recover-orphan-state.php';

try {
    umask(0077);
    [, $mode, $appName, $release, $commit, $token, $persistent] = $argv;
    if (!in_array($mode, ['preflight', 'prepare', 'up', 'prove-up'], true)) {
        throw new RuntimeException;
    }
    ob_start();
    $state = new OrphanRecoveryState($appName, $release, $commit, $token, $persistent);
    if ($mode === 'preflight') {
        $preflight = $state->inspect();
        $private = __DIR__.'/preflight';
    } else {
        $record = $state->owned($mode === 'prove-up' ? 'absent' : 'present');
        $private = $state->record.'/framework';
    }
    if (!is_dir($private) && !mkdir($private, 0700)) {
        throw new RuntimeException;
    }
    OrphanRecoveryState::directory($private);
    if (!chdir($state->stable)) {
        throw new RuntimeException;
    }
    require $state->stable.'/vendor/autoload.php';
    foreach (['CONFIG', 'SERVICES', 'PACKAGES', 'ROUTES', 'EVENTS'] as $kind) {
        if (Env::getRepository()->has('APP_'.$kind.'_CACHE')) { throw new RuntimeException; }
    }
    // Replace registered real-time facade loaders before trusted application creation.
    class OrphanAliasLoader extends AliasLoader
    {
        public function __construct(array $aliases, private string $private, private bool $readOnly) { $this->aliases = $aliases; }
        protected function ensureFacadeExists($alias)
        {
            if (!is_string($alias) || !preg_match('/\A[A-Za-z_][A-Za-z0-9_]*(?:\\\\[A-Za-z_][A-Za-z0-9_]*)+\z/', $alias)
                || !preg_match('/\A(?:[A-Za-z_][A-Za-z0-9_]*\\\\)+\z/', static::$facadeNamespace)) {
                throw new RuntimeException;
            }
            $framework = (new ReflectionClass(AliasLoader::class))->getFileName();
            $stub = file_get_contents(dirname($framework).'/stubs/facade.stub', false, null, 0, 65537);
            if (!is_string($stub) || strlen($stub) > 65536) {
                throw new RuntimeException;
            }
            $stub = $this->formatFacadeStub($alias, $stub);
            $path = $this->private.'/facade-'.sha1($alias).'.php';
            if ($this->readOnly) {
                if (OrphanRecoveryState::bytes($path, 65536) !== $stub) { throw new RuntimeException; }
                return $path;
            }
            if (file_put_contents($path, $stub) !== strlen($stub)) {
                throw new RuntimeException;
            }
            return $path;
        }
    }
    $old = AliasLoader::getInstance();
    foreach (spl_autoload_functions() ?: [] as $loader) {
        if ((is_array($loader) && ($loader[0] ?? null) === $old && ($loader[1] ?? null) === 'load')
            || ($loader instanceof Closure && (new ReflectionFunction($loader))->getClosureThis() === $old)) {
            if (!spl_autoload_unregister($loader)) {
                throw new RuntimeException;
            }
        }
    }
    AliasLoader::setInstance(new OrphanAliasLoader($old->getAliases(), $private, in_array($mode, ['up', 'prove-up'], true)));
    $override = static function (string $kind) use ($private): void {
        $name = 'APP_'.$kind.'_CACHE';
        $path = $private.'/'.strtolower($kind).'.php';
        Env::getRepository()->clear($name);
        putenv($name.'='.$path);
        $_ENV[$name] = $_SERVER[$name] = $path;
    };
    foreach (['SERVICES', 'PACKAGES', 'ROUTES', 'EVENTS'] as $kind) {
        $override($kind);
    }
    $app = require $state->stable.'/bootstrap/app.php';
    // Only native bootstrapping is supported: path overrides and injected loaders
    // could read the original generated PHP despite private cache getters.
    $defaultPaths = static function () use ($app, $state): void {
        if ($app->basePath() !== $state->stable || $app->bootstrapPath() !== $state->stable.'/bootstrap'
            || $app->configPath() !== $state->stable.'/config' || $app->storagePath() !== $state->stable.'/storage'
            || $app->environmentPath() !== $state->stable) { throw new RuntimeException; }
    };
    if (get_class($app) !== \Illuminate\Foundation\Application::class || $app->hasBeenBootstrapped()
        || $app->basePath() !== $state->stable || $app->bootstrapPath() !== $state->stable.'/bootstrap'
        || $app->configPath() !== $state->stable.'/config' || $app->storagePath() !== $state->stable.'/storage'
        || $app->environmentPath() !== $state->stable || $app->environmentFile() !== '.env') {
        throw new RuntimeException;
    }
    $bootstrappers = [LoadEnvironmentVariables::class, LoadConfiguration::class,
        \Illuminate\Foundation\Bootstrap\HandleExceptions::class, \Illuminate\Foundation\Bootstrap\RegisterFacades::class,
        \Illuminate\Foundation\Bootstrap\SetRequestForConsole::class, \Illuminate\Foundation\Bootstrap\RegisterProviders::class,
        \Illuminate\Foundation\Bootstrap\BootProviders::class];
    foreach ($bootstrappers as $bootstrapper) {
        if ($app->bound($bootstrapper)) { throw new RuntimeException; }
    }
    $defaultConfigurationLoader = static function (): void {
        if (property_exists(LoadConfiguration::class, 'alwaysUseConfig')
            && (new ReflectionProperty(LoadConfiguration::class, 'alwaysUseConfig'))->getValue() !== null) {
            throw new RuntimeException;
        }
    };
    $defaultConfigurationLoader();
    $binding = $app->getBindings()[Kernel::class]['concrete'] ?? null;
    if (!$binding instanceof Closure || $app->resolved(Kernel::class) || $app->getAlias(Kernel::class) !== Kernel::class) {
        throw new RuntimeException;
    }
    $bindingReflection = new ReflectionFunction($binding);
    if ($bindingReflection->getClosureScopeClass()?->getName() !== \Illuminate\Container\Container::class
        || ($bindingReflection->getStaticVariables()['concrete'] ?? null) !== \Illuminate\Foundation\Console\Kernel::class) {
        throw new RuntimeException;
    }
    // Always resolve source dotenv before selecting the private configuration.
    // Unsupported custom destinations fail without executing their original PHP.
    class OrphanEnvironmentLoader extends LoadEnvironmentVariables
    {
        public function loadSource($app, string $stable, array $identity): void
        {
            $this->checkForSpecificEnvironmentFile($app);
            $file = $app->environmentFile();
            $path = $app->environmentFilePath();
            if ($app->environmentPath() !== $stable || $path !== $stable.'/'.$file
                || !isset($identity[$file]) || ($file !== '.env' && !str_starts_with($file, '.env.'))
                || hash('sha256', OrphanRecoveryState::bytes($path, 4 * 1024 * 1024)) !== $identity[$file]) {
                throw new RuntimeException;
            }
            $this->createDotenv($app)->safeLoad();
        }
    }
    $original = $app->getCachedConfigPath();
    (new OrphanEnvironmentLoader)->loadSource($app, $state->stable, ($mode === 'preflight' ? $preflight : $record)['identity']);
    $defaultPaths();
    $sourceEnvironment = \Dotenv\Dotenv::parse(OrphanRecoveryState::bytes($app->environmentFilePath(), 4 * 1024 * 1024));
    foreach (['CONFIG', 'SERVICES', 'PACKAGES', 'ROUTES', 'EVENTS'] as $kind) {
        if (array_key_exists('APP_'.$kind.'_CACHE', $sourceEnvironment)) { throw new RuntimeException; }
    }
    if ($original !== $state->stable.'/bootstrap/cache/config.php'
        || $app->getCachedConfigPath() !== $state->stable.'/bootstrap/cache/config.php') {
        throw new RuntimeException;
    }
    $override('CONFIG');
    foreach (['SERVICES', 'PACKAGES', 'ROUTES', 'EVENTS'] as $kind) {
        $override($kind);
    }
    $environmentLoader = new class extends LoadEnvironmentVariables {
        public function bootstrap($app) { /* Source dotenv was selected exactly once above. */ }
    };
    $app->instance(LoadEnvironmentVariables::class, $environmentLoader);
    $privateCachePaths = static function () use ($app, $private): void {
        foreach (['CONFIG' => 'getCachedConfigPath', 'SERVICES' => 'getCachedServicesPath', 'PACKAGES' => 'getCachedPackagesPath',
            'ROUTES' => 'getCachedRoutesPath', 'EVENTS' => 'getCachedEventsPath'] as $kind => $getter) {
            if ($app->$getter() !== $private.'/'.strtolower($kind).'.php') { throw new RuntimeException; }
        }
    };
    $privateCachePaths();
    if ($mode === 'prepare' || $mode === 'preflight') {
        if (file_exists($private.'/config.php') || is_link($private.'/config.php')) {
            throw new RuntimeException;
        }
    } elseif (!isset($record['configHash'])
        || hash('sha256', OrphanRecoveryState::bytes($private.'/config.php', 4 * 1024 * 1024)) !== $record['configHash']) {
        throw new RuntimeException;
    }
    $kernel = $app->make(Kernel::class);
    foreach ($bootstrappers as $bootstrapper) {
        if ($bootstrapper !== LoadEnvironmentVariables::class && $app->bound($bootstrapper)) { throw new RuntimeException; }
    }
    if (get_class($kernel) !== \Illuminate\Foundation\Console\Kernel::class
        || (new ReflectionProperty($kernel, 'bootstrappers'))->getValue($kernel) !== $bootstrappers) {
        throw new RuntimeException;
    }
    $defaultPaths();
    $defaultConfigurationLoader();
    $privateCachePaths();
    $instances = (new ReflectionProperty(\Illuminate\Container\Container::class, 'instances'))->getValue($app);
    if ($app->hasBeenBootstrapped() || $app->getAlias(LoadEnvironmentVariables::class) !== LoadEnvironmentVariables::class
        || ($instances[LoadEnvironmentVariables::class] ?? null) !== $environmentLoader) { throw new RuntimeException; }
    $kernel->bootstrap();
    $config = $app['config'];
    $key = $config->get('app.key');
    $key = is_string($key) && str_starts_with($key, 'base64:') ? base64_decode(substr($key, 7), true) : $key;
    if ($config->get('app.maintenance.driver', 'file') !== 'file' || !is_string($key)
        || !Encrypter::supported($key, $config->get('app.cipher'))
        || $app->isDownForMaintenance() !== ($mode !== 'prove-up')) {
        throw new RuntimeException;
    }
    if ($mode === 'prepare') {
        // This app was bootstrapped uncached from the final path. Generate the
        // native cache format directly, avoiding config:cache's second bootstrap
        // and a second dotenv selection/provider invocation.
        $nodes = 0;
        $scalar = static function ($value, int $depth = 0) use (&$scalar, &$nodes): void {
            if ($depth > 64 || ++$nodes > 50000) { throw new RuntimeException; }
            if (is_array($value)) {
                foreach ($value as $item) { $scalar($item, $depth + 1); }
            } elseif (!is_null($value) && !is_bool($value) && !is_int($value) && !is_string($value)
                && !(is_float($value) && is_finite($value))) { throw new RuntimeException; }
        };
        $configuration = $config->all();
        $scalar($configuration);
        $bytes = '<?php return '.var_export($configuration, true).';';
        if (strlen($bytes) > 4 * 1024 * 1024 || file_put_contents($private.'/config.php', $bytes, LOCK_EX) !== strlen($bytes)
            || !chmod($private.'/config.php', 0600)) { throw new RuntimeException; }
        $state->owned('present');
        $state->cacheDestinations();
        // Publish trusted regenerated provider manifests and remove the default
        // route/event caches, so ordinary web bootstrap uses the selected source.
        // Never copy back or execute the original generated PHP.
        foreach (['packages', 'services'] as $kind) {
            $generated = $private.'/'.$kind.'.php';
            OrphanRecoveryState::bytes($generated, 4 * 1024 * 1024);
            $manifest = require $generated;
            if (!is_array($manifest)) { throw new RuntimeException; }
            $scalar($manifest);
            $manifestBytes = '<?php return '.var_export($manifest, true).';';
            if (strlen($manifestBytes) > 4 * 1024 * 1024) { throw new RuntimeException; }
            $state->owned('present');
            $state->cacheDestinations();
            $manifestTemporary = $state->stable.'/bootstrap/cache/.orphan-'.$kind.'-'.bin2hex(random_bytes(16));
            $handle = fopen($manifestTemporary, 'x');
            if (!$handle || fwrite($handle, $manifestBytes) !== strlen($manifestBytes) || !fflush($handle) || !fsync($handle)
                || !chmod($manifestTemporary, 0600)) { throw new RuntimeException; }
            fclose($handle);
            $state->owned('present');
            if (!rename($manifestTemporary, $state->stable.'/bootstrap/cache/'.$kind.'.php')) { throw new RuntimeException; }
        }
        foreach (['routes-v7.php', 'events.php'] as $leaf) {
            $state->owned('present');
            $state->cacheDestinations();
            $path = $state->stable.'/bootstrap/cache/'.$leaf;
            if (file_exists($path) && !unlink($path)) { throw new RuntimeException; }
        }
        foreach (glob($state->storage.'/framework/cache/facade-*.php') as $facade) {
            $state->owned('present');
            $state->cacheDestinations();
            if (!unlink($facade)) { throw new RuntimeException; }
        }
        $path = $state->stable.'/bootstrap/cache/config.php';
        if (is_link($path) || (file_exists($path) && (!is_file($path) || realpath($path) !== $path))) {
            throw new RuntimeException;
        }
        $temporary = dirname($path).'/.orphan-config-'.bin2hex(random_bytes(16));
        $handle = fopen($temporary, 'x');
        if (!$handle || fwrite($handle, $bytes) !== strlen($bytes) || !fflush($handle) || !fsync($handle) || !chmod($temporary, 0600)) {
            throw new RuntimeException;
        }
        fclose($handle);
        $state->owned('present');
        if (!rename($temporary, $path)) {
            throw new RuntimeException;
        }
        $state->phase('prepared-cache');
    } elseif ($mode === 'up') {
        $state->owned('present');
        if ($record['phase'] !== 'up-armed' || $kernel->call('up', ['--no-interaction' => true]) !== 0
            || $app->isDownForMaintenance()) {
            throw new RuntimeException;
        }
    }
    if ($mode === 'preflight') {
        if ($state->inspect() !== $preflight || file_put_contents(__DIR__.'/preflight-record.json', json_encode($preflight, JSON_THROW_ON_ERROR), LOCK_EX) === false
            || !chmod(__DIR__.'/preflight-record.json', 0600)) { throw new RuntimeException; }
    }
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    echo 'orphan-recovery framework='.(in_array($mode, ['up', 'prove-up'], true) ? 'serving' : 'maintenance')."\n";
} catch (Throwable) {
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    exit(1);
}
