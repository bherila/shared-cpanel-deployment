#!/usr/bin/env bash
#
# Run artisan commands in one application's directory.
#
# Runs ON THE HOST, fed over SSH by the remote-artisan action:
#
#   ssh <target> "bash -s -- $(printf '%q ' <app-dir> <php> <command>...)" < scripts/remote-artisan.sh
#
#   <app-dir>    The application's directory under $HOME.
#   <php>        The PHP CLI binary. cPanel's default `php` is often older than the site's handler.
#   <command>... One artisan invocation each, e.g. "config:cache". Split on whitespace; no shell
#                quoting, globbing or chaining is interpreted.
#
# Stops at the first command that fails.
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: remote-artisan.sh <app-dir> <php> <command>..." >&2
    exit 2
fi

app_dir=$1
php=$2
shift 2

case $app_dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain directory name under the account home." >&2
        exit 2 ;;
esac

if [ ! -x "$php" ]; then
    echo "::error::PHP binary '$php' is not executable on this host." >&2
    exit 1
fi

cd "$HOME/$app_dir"

if [ ! -f artisan ]; then
    echo "::error::~/$app_dir has no artisan file." >&2
    exit 1
fi

for command in "$@"; do
    read -r -a argv <<<"$command"
    [ "${#argv[@]}" -eq 0 ] && continue
    echo "::group::artisan $command"
    "$php" artisan "${argv[@]}"
    echo "::endgroup::"
done
