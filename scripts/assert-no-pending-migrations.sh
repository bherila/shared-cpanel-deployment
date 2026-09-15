#!/usr/bin/env bash
#
# Fail unless Laravel reports that every discovered migration has run.
#
# Runs ON THE HOST after `artisan migrate --force`:
#
#   bash -s -- <app-dir> <php> < scripts/assert-no-pending-migrations.sh
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: assert-no-pending-migrations.sh <app-dir> <php>" >&2
    exit 2
fi

app_dir=$1
php=$2
deploy_home=${DEPLOY_HOME:-$HOME}

case $app_dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain, non-hidden name under the account home." >&2
        exit 2 ;;
esac

case $php in
    /*) ;;
    *)
        echo "::error::PHP binary must be an absolute path, not '$php'." >&2
        exit 2 ;;
esac

if [ ! -x "$php" ]; then
    echo "::error::PHP binary '$php' is not executable on this host." >&2
    exit 1
fi

cd "$deploy_home/$app_dir"

if [ ! -f artisan ]; then
    echo "::error::~/$app_dir has no artisan file." >&2
    exit 1
fi

if ! status=$("$php" artisan migrate:status --pending --no-ansi 2>&1); then
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
