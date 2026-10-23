#!/usr/bin/env bash
# Keep or create one complete Laravel Passport signing-key pair; never rotate a partial pair.
# Mode "ensure" never boots the application except to create a missing pair. Mode "verify"
# changes nothing: it boots the application and proves Passport loads the pair it uses.
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 6 ]; then
    echo "usage: ensure-passport-keys.sh <app-dir> <php> <key-directory> [managed-shared-root] [memory-limit] [ensure|verify]" >&2
    exit 2
fi

app_dir=$1
php=$2
key_directory=$3
managed_shared_root=${4:-}
memory_limit=${5:-}
mode=${6:-ensure}
case $mode in
    ensure | verify) ;;
    *) echo "::error::Passport key mode must be ensure or verify." >&2; exit 2 ;;
esac
if [[ ! $memory_limit =~ ^([1-9][0-9]*[KMGkmg]|-1)?$ ]]; then
    echo "::error::PHP memory limit must be empty, -1, or a positive K/M/G value." >&2
    exit 2
fi

case $app_dir in
    '' | . | .. | /* | *..* | *[!A-Za-z0-9._/-]*) echo "::error::The application path is unsafe." >&2; exit 2 ;;
    .deployments/*/releases/*)
        IFS=/ read -r prefix managed_app releases_component managed_release extra <<<"$app_dir"
        if [ "$prefix" != .deployments ] || [ "$releases_component" != releases ] || [ -n "$extra" ]; then
            echo "::error::The managed release path is malformed." >&2; exit 2
        fi
        case "$managed_app:$managed_release" in *[!A-Za-z0-9._:-]* | :* | *:) echo "::error::The managed release path is malformed." >&2; exit 2 ;; esac ;;
    .* | */*) echo "::error::The application path must be a plain account-home name or a managed release." >&2; exit 2 ;;
esac
if [ -n "$managed_shared_root" ]; then
    case $managed_shared_root in
        .deployments/*/shared)
            case $managed_shared_root in *..* | *[!A-Za-z0-9._/-]*) echo "::error::The managed shared root is unsafe." >&2; exit 2 ;; esac ;;
        *) echo "::error::The managed shared root is malformed." >&2; exit 2 ;;
    esac
fi
case $php in
    /*) ;;
    *) echo "::error::PHP binary must be an absolute path." >&2; exit 2 ;;
esac
case $key_directory in
    '' | /* | .* | *'/.'* | *..* | *[!A-Za-z0-9._/-]*)
        echo "::error::Passport key directory must be a non-hidden relative path inside the application." >&2
        exit 2 ;;
esac
[ -x "$php" ] || { echo "::error::PHP binary is not executable on this host." >&2; exit 1; }

app="$HOME/$app_dir"
if [ ! -d "$app" ] || [ -L "$app" ]; then
    echo "::error::~/$app_dir is missing or aliased." >&2
    exit 1
fi
[ -f "$app/artisan" ] || { echo "::error::~/$app_dir has no artisan file." >&2; exit 1; }

current=$app
IFS=/ read -r -a components <<<"$key_directory"
for component in "${components[@]}"; do
    current="$current/$component"
    if [ -L "$current" ]; then
        resolved=$(readlink -f "$current")
        if [ -z "$managed_shared_root" ] || [[ "$resolved/" != "$HOME/$managed_shared_root/"* ]]; then
            echo "::error::Passport key path must not traverse an unmanaged symlink." >&2
            exit 1
        fi
    fi
    if [ -e "$current" ] && [ ! -d "$current" ]; then
        echo "::error::Passport key path contains a non-directory component." >&2
        exit 1
    fi
done
[ "$mode" = verify ] || install -d -m 700 "$current"

private="$current/oauth-private.key"
public="$current/oauth-public.key"
private_ok=false
public_ok=false
[ -f "$private" ] && [ ! -L "$private" ] && [ -s "$private" ] && private_ok=true
[ -f "$public" ] && [ ! -L "$public" ] && [ -s "$public" ] && public_ok=true

if [ "$private_ok" = true ] && [ "$public_ok" = true ]; then
    [ "$mode" = verify ] || chmod 600 "$private" "$public"
    echo "Passport signing key pair is complete."
elif [ "$mode" = verify ]; then
    echo "::error::Passport signing key pair is missing or incomplete." >&2
    exit 1
elif [ ! -e "$private" ] && [ ! -e "$public" ]; then
    if [ -n "$memory_limit" ]; then
        (cd "$app" && "$php" -d "memory_limit=$memory_limit" artisan passport:keys --force)
    else
        (cd "$app" && "$php" artisan passport:keys --force)
    fi
    if [ ! -f "$private" ] || [ -L "$private" ] || [ ! -s "$private" ] \
        || [ ! -f "$public" ] || [ -L "$public" ] || [ ! -s "$public" ]; then
        echo "::error::passport:keys did not create the expected complete key pair." >&2
        exit 1
    fi
    chmod 600 "$private" "$public"
    echo "Created Passport signing key pair."
else
    echo "::error::Passport signing key pair is incomplete; refusing automatic rotation." >&2
    exit 1
fi

[ "$mode" = verify ] || exit 0

# A complete pair is not necessarily one Passport will load. It refuses a key file other
# users can read, and an application may load its keys from somewhere other than this
# directory, so the chmod in ensure mode proves nothing about the files it actually reads.
# Build both servers the way the web runtime does: an unusable pair otherwise surfaces only
# on the first token request, after activation. Booting runs the application's providers,
# so the action calls this mode only after config caching, inside the atomic risk boundary.
# Only a fixed reason or the exception class is printed, never the message, which can
# carry host paths into the Actions log.
php_args=()
[ -z "$memory_limit" ] || php_args=(-d "memory_limit=$memory_limit")
# shellcheck disable=SC2016 # PHP source, not shell expansions.
if ! (cd "$app" && "$php" ${php_args[@]+"${php_args[@]}"} -d display_errors=0 -d log_errors=0 -r '
    try {
        require "vendor/autoload.php";
        $app = require "bootstrap/app.php";
        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
        $app->make(League\OAuth2\Server\AuthorizationServer::class);
        $app->make(League\OAuth2\Server\ResourceServer::class);
    } catch (Throwable $error) {
        // An anonymous class name embeds a NUL byte and its defining file path.
        $class = get_class($error);
        $named = $class !== "" && strspn($class, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_\\") === strlen($class);
        fwrite(STDERR, str_contains($error->getMessage(), "permissions are not correct")
            ? "A Passport key file is readable by other users; Passport requires mode 0600 or 0660.\n"
            : "Passport could not be built: ".($named ? $class : "an anonymous exception")."\n");
        exit(1);
    }
'); then
    echo "::error::Passport cannot load its signing keys, so every token request would fail." >&2
    exit 1
fi
echo "Passport loads the signing key pair."
