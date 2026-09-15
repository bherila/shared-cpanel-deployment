#!/usr/bin/env bash
# Upload candidate Laravel migrations to an existing application before the main code upload.
set -euo pipefail

error() { echo "::error::$*" >&2; }

target=${DEPLOY_TARGET:-}
dir=${DEPLOY_DIR:-}
migrations=${DEPLOY_MIGRATIONS_PATH:-database/migrations}

if [ -z "$target" ]; then
    error "DEPLOY_TARGET is not set."
    exit 2
fi

case $dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        error "The deploy directory '$dir' must be a plain, non-hidden directory name under the account home."
        exit 2 ;;
esac

case $dir in
    public_html | www | web | mail | etc | logs | tmp | ssl | cache | bin | lib | perl5 | access-logs | lscache | backups)
        error "The deploy directory '$dir' belongs to cPanel or is a webroot, not an application directory."
        exit 2 ;;
esac

case $migrations in
    '' | /* | -* | .. | ../* | */.. | */../*)
        error "The migrations path must be relative to the checkout and must not contain '..'."
        exit 2 ;;
esac

if [ ! -d "$migrations" ]; then
    error "The migrations path '$migrations' is not a directory in the checkout."
    exit 2
fi

# shellcheck disable=SC2016,SC2029 # The script expands on the host; arguments are quoted on the runner.
state=$(ssh "$target" "bash -s -- $(printf '%q ' "$dir")" <<'REMOTE'
app="$HOME/$1"
if [ -L "$app" ]; then echo symlink
elif [ ! -d "$app" ]; then echo absent
elif [ ! -f "$app/artisan" ]; then echo not-an-app
elif [ -L "$app/database" ] || [ -L "$app/database/migrations" ]; then echo migration-alias
elif [ ! -d "$app/database/migrations" ]; then echo no-migration-dir
else echo app
fi
REMOTE
)

if [ "$state" != app ]; then
    error "Migration-first deploy requires an existing application at ~/$dir; destination state is '$state'."
    exit 1
fi

echo "Uploading candidate migrations to the existing application at ~/$dir."
rsync -av -e ssh "$migrations/" "$target:~/$dir/database/migrations/"
