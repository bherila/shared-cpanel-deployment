#!/usr/bin/env bash
# Keep or create one complete Laravel Passport signing-key pair; never rotate a partial pair.
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: ensure-passport-keys.sh <app-dir> <php> <key-directory> [managed-shared-root]" >&2
    exit 2
fi

app_dir=$1
php=$2
key_directory=$3
managed_shared_root=${4:-}

case $app_dir in
    '' | . | .. | /* | *..* | *[!A-Za-z0-9._/-]*) echo "::error::The application path is unsafe." >&2; exit 2 ;;
    .deployments/*/releases/*)
        IFS=/ read -r prefix managed_app releases_component managed_release extra <<<"$app_dir"
        [ "$prefix" = .deployments ] && [ "$releases_component" = releases ] && [ -z "$extra" ] \
            || { echo "::error::The managed release path is malformed." >&2; exit 2; }
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
install -d -m 700 "$current"

private="$current/oauth-private.key"
public="$current/oauth-public.key"
private_ok=false
public_ok=false
[ -f "$private" ] && [ ! -L "$private" ] && [ -s "$private" ] && private_ok=true
[ -f "$public" ] && [ ! -L "$public" ] && [ -s "$public" ] && public_ok=true

if [ "$private_ok" = true ] && [ "$public_ok" = true ]; then
    chmod 600 "$private" "$public"
    echo "Passport signing key pair is complete."
elif [ ! -e "$private" ] && [ ! -e "$public" ]; then
    (cd "$app" && "$php" artisan passport:keys --force)
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
