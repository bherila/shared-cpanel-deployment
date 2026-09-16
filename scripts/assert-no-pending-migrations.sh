#!/usr/bin/env bash
#
# Fail unless Laravel reports that every discovered migration has run.
#
# Runs ON THE HOST after `artisan migrate --force`:
#
#   bash -s -- <app-dir> <php> <memory-limit> < scripts/assert-no-pending-migrations.sh
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: assert-no-pending-migrations.sh <app-dir> <php> <memory-limit>" >&2
    exit 2
fi

app_dir=$1
php=$2
memory_limit=$3
deploy_home=${DEPLOY_HOME:-$HOME}

case $app_dir in
    '' | . | .. | /* | *..* | *[!A-Za-z0-9._/-]*) echo "::error::The application path is unsafe." >&2; exit 2 ;;
    .deployments/*/releases/*)
        IFS=/ read -r prefix managed_app releases_component managed_release extra <<<"$app_dir"
        [ "$prefix" = .deployments ] && [ "$releases_component" = releases ] && [ -z "$extra" ] \
            || { echo "::error::The managed release path is malformed." >&2; exit 2; }
        case "$managed_app:$managed_release" in *[!A-Za-z0-9._:-]* | :* | *:) echo "::error::The managed release path is malformed." >&2; exit 2 ;; esac ;;
    .* | */*) echo "::error::The application path must be a plain account-home name or a managed release." >&2; exit 2 ;;
esac

case $php in
    /*) ;;
    *)
        echo "::error::PHP binary must be an absolute path, not '$php'." >&2
        exit 2 ;;
esac
if [[ ! $memory_limit =~ ^([1-9][0-9]*[KMGkmg]|-1)?$ ]]; then
    echo "::error::PHP memory limit must be empty, -1, or a positive K/M/G value." >&2
    exit 2
fi

if [ ! -x "$php" ]; then
    echo "::error::PHP binary '$php' is not executable on this host." >&2
    exit 1
fi

cd "$deploy_home/$app_dir"

if [ ! -f artisan ]; then
    echo "::error::~/$app_dir has no artisan file." >&2
    exit 1
fi

if [ -n "$memory_limit" ]; then
    status=$("$php" -d "memory_limit=$memory_limit" artisan migrate:status --pending --no-ansi 2>&1) || result=$?
else
    status=$("$php" artisan migrate:status --pending --no-ansi 2>&1) || result=$?
fi
if [ "${result:-0}" -ne 0 ]; then
    printf '%s\n' "$status" >&2
    echo "::error::Could not read migration status after migrate completed." >&2
    exit 1
fi

if printf '%s\n' "$status" | grep -Eq '(^|[[:space:]])Pending[[:space:]]*$'; then
    printf '%s\n' "$status" >&2
    echo "::error::Migrations remain pending after migrate completed." >&2
    exit 1
fi

echo "No pending migrations remain."
