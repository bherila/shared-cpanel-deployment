#!/usr/bin/env bash
# Real-framework adversarial guards in a separate copy of the isolated app.
# shellcheck disable=SC2016
set -euo pipefail
[[ $# == 2 && $1 == "$HOME/app" && $2 == /* ]] || exit 2
source_app=$1 php=$2
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
step=setup
cleanup() {
    local status=$?
    if [[ $status != 0 ]]; then echo "Real orphan guard fixture failed at $step" >&2; fi
    rm -rf -- "$work"
}
trap cleanup EXIT
case_home="$work/home"
stable="$case_home/app"
control="$case_home/.deployments/app"
mkdir -p "$case_home" "$control"/{releases,state,shared}
[[ -L $source_app/storage && -d $source_app/vendor && ! -L $source_app/vendor ]]
cp -a "$source_app" "$stable"
cp -a "$source_app/storage/" "$control/shared/storage"
rm -- "$stable/storage"
ln -s "$control/shared/storage" "$stable/storage"
# The copied source may use an absolute original fixture database path. Select
# only this independent copy, even if a trusted provider connects during boot.
sed -i '/^DB_DATABASE=/d' "$stable/.env"
printf '\nDB_DATABASE=%s\n' "$control/shared/storage/app/database.sqlite" >>"$stable/.env"
[[ $("$php" -r 'require $argv[1]."/vendor/autoload.php"; echo (new ReflectionClass("App\\Models\\User"))->getFileName();' "$stable") == "$stable/app/Models/User.php" ]]
release=$(sed -n 's/^release=//p' "$stable/.deploy-release")
commit=$(sed -n 's/^commit=//p' "$stable/.deploy-release")
cp -a "$stable/bootstrap/cache" "$work/original-cache"
cp -p "$stable/bootstrap/app.php" "$work/original-bootstrap.php"
cp -p "$stable/storage/framework/down" "$work/original-down"
source_down=$(sha256sum "$source_app/storage/framework/down")
source_env=$(sha256sum "$source_app/.env")
source_bootstrap=$(sha256sum "$source_app/bootstrap/app.php")
checks=0

new_case() {
    step=$1
    rm -f -- "$case_home/guard-kernel-resolved"
    cp -p "$work/original-bootstrap.php" "$stable/bootstrap/app.php"
    rm -rf -- "$stable/bootstrap/cache"
    cp -a "$work/original-cache" "$stable/bootstrap/cache"
    bundle=$(mktemp -d "$work/bundle.XXXXXX")
    cp "$here"/{recover-orphan-state.php,recover-orphan-framework.php} "$bundle/"
    token=orphan-$("$php" -r 'echo bin2hex(random_bytes(16));')
    record="$control/recovery/$token"
    sentinel="$case_home/unsafe-orphan-native-cache"
    [[ ! -e $control/deploy.lock && ! -e $sentinel ]]
    cmp -s "$stable/storage/framework/down" "$work/original-down"
}

framework() {
    env HOME="$case_home" timeout --kill-after=2s 45s "$php" -d memory_limit=256M \
        "$bundle/recover-orphan-framework.php" "$1" app "$release" "$commit" "$token" storage \
        >"$work/output" 2>"$work/error"
}

state() {
    env HOME="$case_home" timeout --kill-after=2s 10s "$php" -d memory_limit=256M \
        "$bundle/recover-orphan-state.php" "$1" app "$release" "$commit" "$token" storage "${2:-}" \
        >"$work/output" 2>"$work/error"
}

expect_refusal() {
    local status
    if "$@"; then echo "Unexpected native guard success at $step" >&2; exit 1; else status=$?; fi
    if [[ $status != 1 ]]; then echo "Unexpected guard exit $status at $step" >&2; exit 1; fi
    [[ ! -e $sentinel ]]
    cmp -s "$stable/storage/framework/down" "$work/original-down"
}

prepare() {
    state inspect "$bundle/preflight-record.json"
    state initialize "$bundle/preflight-record.json"
    framework preflight
    framework prepare
    state owned-down
}

unlock_unchanged_down() {
    # After undoing this fixture's injected change, actual filesystem-only
    # recovery proves the original markers and releases only its owned lock.
    state restore
    state release-down
    [[ ! -e $control/deploy.lock && ! -e $sentinel ]]
    cmp -s "$stable/storage/framework/down" "$work/original-down"
    checks=$((checks + 1))
}

poison() {
    printf '<?php file_put_contents(getenv("HOME")."/unsafe-orphan-native-cache", "executed"); return [];' >"$1"
}

for kind in Config Services Packages Routes Events; do
    new_case "custom-$kind-getter"
    leaf=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
    [[ $kind != Routes ]] || leaf=routes-v7
    poison "$stable/bootstrap/cache/$leaf.php"
    # A real Application subclass ignores APP_*_CACHE, reproducing source
    # overrides which an environment-only freeze cannot protect against.
    "$php" -r '
        $path=$argv[1]; $kind=$argv[2]; $leaf=$argv[3];
        $source=file_get_contents($path);
        $class="class OrphanGuardApplication extends \\Illuminate\\Foundation\\Application { public function getCached".$kind."Path(): string { return \$this->bootstrapPath(".var_export("cache/".$leaf.".php",true)."); } }\n";
        $source=str_replace("return Application::configure(",$class."return OrphanGuardApplication::configure(",$source,$count);
        if ($count!==1 || file_put_contents($path,$source)!==strlen($source)) { exit(1); }
    ' "$stable/bootstrap/app.php" "$kind" "$leaf"
    "$php" -l "$stable/bootstrap/app.php" >"$work/lint"
    state inspect "$bundle/preflight-record.json"
    state initialize "$bundle/preflight-record.json"
    expect_refusal framework preflight
    [[ $(cat "$control/deploy.lock/owner") == "$token" ]]
    unlock_unchanged_down
done

cat >"$work/override-bootstrap.php" <<'PHP_WRITER'
<?php
        $path=$argv[1]; $kind=$argv[2]; $external=$argv[3];
        $source=file_get_contents($path);
        $source=str_replace("return Application::configure(","\$app = Application::configure(",$source,$count);
        if ($count!==1) { exit(1); }
        $extra=match($kind) {
            "bound-configuration" => <<<'PHP'
$app->instance(\Illuminate\Foundation\Bootstrap\LoadConfiguration::class, new class extends \Illuminate\Foundation\Bootstrap\LoadConfiguration {
    public function bootstrap($app): void { require __DIR__."/cache/config.php"; }
});
PHP,
            "custom-kernel" => <<<'PHP'
class OrphanGuardBootstrap { public function bootstrap($app): void { require __DIR__."/cache/config.php"; } }
$app->singleton(\Illuminate\Contracts\Console\Kernel::class, static function($app) {
    return new class($app, $app["events"]) extends \Illuminate\Foundation\Console\Kernel {
        protected function bootstrappers(): array { return [OrphanGuardBootstrap::class]; }
    };
});
PHP,
            "already-bootstrapped" => <<<'PHP'
$app->instance("config", new \Illuminate\Config\Repository(["app"=>["key"=>str_repeat("k",32),"cipher"=>"AES-256-CBC","maintenance"=>["driver"=>"file"]]]));
$app->instance(\Illuminate\Contracts\Foundation\MaintenanceMode::class, new \Illuminate\Foundation\FileBasedMaintenanceMode($app->storagePath()));
$app->bootstrapWith([]);
PHP,
            "external-environment" => "\$app->useEnvironmentPath(".var_export($external,true).");",
            "untracked-environment" => "\$app->loadEnvironmentFrom(\"other.env\");",
            "external-config" => "\$app->useConfigPath(".var_export($external,true).");",
            "external-storage" => "\$app->useStoragePath(".var_export($external,true).");",
            "external-base" => "\$app->setBasePath(".var_export($external,true).");",
            "resolved-environment-loader" => <<<'PHP'
$app->afterResolving(\Illuminate\Contracts\Console\Kernel::class, static function($kernel, $app) {
    file_put_contents(getenv("HOME")."/guard-kernel-resolved", "resolved");
    $app->instance(\Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables::class, new class extends \Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables {
        public function bootstrap($app): void { require __DIR__."/cache/config.php"; }
    });
});
PHP,
            "resolved-config-environment" => <<<'PHP'
$app->afterResolving(\Illuminate\Contracts\Console\Kernel::class, static function($kernel, $app) {
    file_put_contents(getenv("HOME")."/guard-kernel-resolved", "resolved");
    $name = "APP_CONFIG_CACHE";
    $path = $app->bootstrapPath("cache/config.php");
    \Illuminate\Support\Env::getRepository()->clear($name);
    putenv($name."=".$path);
    $_ENV[$name] = $_SERVER[$name] = $path;
});
PHP,
            "resolved-config-path" => "\$app->afterResolving(\\Illuminate\\Contracts\\Console\\Kernel::class, static function(\$kernel, \$app) { file_put_contents(getenv(\"HOME\").\"/guard-kernel-resolved\", \"resolved\"); \$app->useConfigPath(".var_export($external,true)."); });",
            "resolved-static-configuration" => <<<'PHP'
$app->afterResolving(\Illuminate\Contracts\Console\Kernel::class, static function($kernel, $app) {
    file_put_contents(getenv("HOME")."/guard-kernel-resolved", "resolved");
    \Illuminate\Foundation\Bootstrap\LoadConfiguration::alwaysUse(static function() { return require __DIR__."/cache/config.php"; });
});
PHP,
            "static-configuration" => <<<'PHP'
\Illuminate\Foundation\Bootstrap\LoadConfiguration::alwaysUse(static function() { return require __DIR__."/cache/config.php"; });
PHP,
        };
        $source.="\n".$extra."\nreturn \$app;\n";
        if (file_put_contents($path,$source)!==strlen($source)) { exit(1); }
PHP_WRITER

for override in bound-configuration custom-kernel already-bootstrapped external-environment untracked-environment external-config external-storage external-base static-configuration resolved-environment-loader resolved-config-environment resolved-config-path resolved-static-configuration; do
    new_case "$override"
    if [[ $override == static-configuration || $override == resolved-static-configuration ]] && ! "$php" -r 'require $argv[1]."/vendor/autoload.php"; exit(method_exists(Illuminate\Foundation\Bootstrap\LoadConfiguration::class,"alwaysUse") ? 0 : 1);' "$stable"; then
        continue
    fi
    poison "$stable/bootstrap/cache/config.php"
    mkdir -p "$work/external-environment"
    cp -p "$stable/.env" "$work/external-environment/.env"
    cp -p "$stable/.env" "$stable/other.env"
    poison "$work/external-environment/app.php"
    "$php" "$work/override-bootstrap.php" "$stable/bootstrap/app.php" "$override" "$work/external-environment"
    "$php" -l "$stable/bootstrap/app.php" >"$work/lint"
    state inspect "$bundle/preflight-record.json"
    state initialize "$bundle/preflight-record.json"
    expect_refusal framework preflight
    if [[ $override == resolved-* ]]; then [[ $(cat "$case_home/guard-kernel-resolved") == resolved ]]; fi
    [[ $(cat "$control/deploy.lock/owner") == "$token" ]]
    # Keep the exact unsupported source captured by initialization: restore is
    # filesystem-only and must not require bootstrapping that source.
    unlock_unchanged_down
done

new_case newer-preflight-marker
state inspect "$bundle/preflight-record.json"
mv "$stable/storage/framework/down" "$work/held-down"
cp -p "$work/held-down" "$stable/storage/framework/down"
expect_refusal state initialize "$bundle/preflight-record.json"
[[ ! -e $control/deploy.lock && ! -e $record ]]
rm "$stable/storage/framework/down"
mv "$work/held-down" "$stable/storage/framework/down"
checks=$((checks + 1))

new_case newer-owned-marker
prepare
mv "$stable/storage/framework/down" "$work/held-down"
cp -p "$work/held-down" "$stable/storage/framework/down"
expect_refusal state up-armed
expect_refusal framework up
[[ $(cat "$control/deploy.lock/owner") == "$token" ]]
rm "$stable/storage/framework/down"
mv "$work/held-down" "$stable/storage/framework/down"
unlock_unchanged_down

for kind in packages services; do
    new_case "private-$kind-content"
    prepare
    state up-armed
    private="$record/framework"
    cp -p "$private/$kind.php" "$work/private-original.php"
    poison "$private/$kind.php"
    expect_refusal framework up
    [[ $(cat "$control/deploy.lock/owner") == "$token" ]]
    # Preserve the attested original inode while restoring its exact bytes.
    cat "$work/private-original.php" >"$private/$kind.php"
    unlock_unchanged_down
done

new_case private-file-replacement
prepare
state up-armed
private="$record/framework"
mv "$private/packages.php" "$work/held-packages.php"
poison "$private/packages.php"
expect_refusal framework up
[[ $(cat "$control/deploy.lock/owner") == "$token" ]]
rm "$private/packages.php"
mv "$work/held-packages.php" "$private/packages.php"
unlock_unchanged_down

new_case private-directory-replacement
prepare
state up-armed
private="$record/framework"
mv "$private" "$work/held-private"
cp -a "$work/held-private" "$private"
poison "$private/services.php"
expect_refusal framework up
[[ $(cat "$control/deploy.lock/owner") == "$token" ]]
rm -rf -- "$private"
mv "$work/held-private" "$private"
unlock_unchanged_down

[[ $(sha256sum "$source_app/storage/framework/down") == "$source_down" \
    && $(sha256sum "$source_app/.env") == "$source_env" \
    && $(sha256sum "$source_app/bootstrap/app.php") == "$source_bootstrap" ]]
[[ ! -e $HOME/.deployments/app/deploy.lock ]]
echo "Real Laravel orphan guards passed $checks cases: custom cache/bootstrap/environment paths, newer identical markers and private cache substitutions refused before execution."
