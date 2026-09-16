#!/usr/bin/env bash
#
# Run artisan commands in one application's directory.
#
# Runs ON THE HOST, fed over SSH by the remote-artisan action:
#
#   ssh <target> "bash -s -- $(printf '%q ' <app-dir> <php> <memory-limit> <command>...)" < scripts/remote-artisan.sh
#
#   <app-dir>    The application's directory under $HOME.
#   <php>        The PHP CLI binary. cPanel's default `php` is often older than the site's handler.
#   <memory-limit> Optional PHP memory_limit such as 1G; an empty string uses the host default.
#   <command>... One artisan invocation each, e.g. "config:cache". Split on whitespace; no shell
#                quoting, globbing or chaining is interpreted.
#
# Stops at the first command that fails.
set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "usage: remote-artisan.sh <app-dir> <php> <memory-limit> <command>..." >&2
    exit 2
fi

app_dir=$1
php=$2
memory_limit=$3
shift 3

case $app_dir in
    '' | . | .. | /* | *..* | *[!A-Za-z0-9._/-]*)
        echo "::error::The application path is unsafe." >&2
        exit 2 ;;
    .deployments/*/releases/*)
        IFS=/ read -r prefix managed_app releases_component managed_release extra <<<"$app_dir"
        if [ "$prefix" != .deployments ] || [ "$releases_component" != releases ] || [ -n "$extra" ]; then
            echo "::error::The managed release path is malformed." >&2; exit 2
        fi
        case "$managed_app:$managed_release" in *[!A-Za-z0-9._:-]* | :* | *:) echo "::error::The managed release path is malformed." >&2; exit 2 ;; esac ;;
    .* | */*)
        echo "::error::The application path must be a plain account-home name or a managed release." >&2
        exit 2 ;;
esac

if [ ! -x "$php" ]; then
    echo "::error::PHP binary '$php' is not executable on this host." >&2
    exit 1
fi
if [[ ! $memory_limit =~ ^([1-9][0-9]*[KMGkmg]|-1)?$ ]]; then
    echo "::error::PHP memory limit must be empty, -1, or a positive K/M/G value." >&2
    exit 2
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
    if [ -n "$memory_limit" ]; then
        "$php" -d "memory_limit=$memory_limit" artisan "${argv[@]}"
    else
        "$php" artisan "${argv[@]}"
    fi
    echo "::endgroup::"
done
