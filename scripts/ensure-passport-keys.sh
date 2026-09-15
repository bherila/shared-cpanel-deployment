#!/usr/bin/env bash
# Keep or create one complete Laravel Passport signing-key pair; never rotate a partial pair.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: ensure-passport-keys.sh <app-dir> <php> <key-directory>" >&2
    exit 2
fi

app_dir=$1
php=$2
key_directory=$3

case $app_dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain, non-hidden name under the account home." >&2
        exit 2 ;;
esac
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
    [ ! -L "$current" ] || { echo "::error::Passport key path must not traverse a symlink." >&2; exit 1; }
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
