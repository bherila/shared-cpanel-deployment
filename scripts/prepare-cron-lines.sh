#!/usr/bin/env bash
# Build the managed crontab lines before install-cron.sh writes them.
#
# Usage:
#   prepare-cron-lines.sh <deploy-dir> <php> <memory-limit> <scheduler-log> <cron-lines> <extra-cron-lines>
#
# Caller-supplied Artisan lines inherit <memory-limit> when they do not already
# set one. This keeps queue workers and custom scheduler wrappers from silently
# falling back to cPanel's 128M CLI default.
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: prepare-cron-lines.sh <deploy-dir> <php> <memory-limit> <scheduler-log> <cron-lines> <extra-cron-lines>" >&2
    exit 2
fi

deploy_dir=$1
php=$2
memory_limit=$3
scheduler_log=$4
cron_lines=$5
extra_cron_lines=$6

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    printf '%s' "${value%"${value##*[![:space:]]}"}"
}

case $memory_limit in
    [1-9]*[0-9][GgMm] | [1-9][GgMm]) ;;
    *)
        echo "cron-memory-limit must look like 1G or 512M, not '$memory_limit'." >&2
        exit 2
        ;;
esac

if [ "$scheduler_log" = /dev/null ]; then
    redirect='> /dev/null 2>&1'
else
    case $scheduler_log in
        '' | /* | *..* | *[!A-Za-z0-9._/-]*)
            echo "scheduler-log must be /dev/null or a plain path inside the application directory." >&2
            exit 2
            ;;
    esac
    redirect=">> $scheduler_log 2>&1"
fi

normalize_artisan_memory() {
    local line=$1
    local after_php
    local php_options
    local replacement="$php -d memory_limit=$memory_limit "

    if [[ $line != *' artisan '* ]]; then
        printf '%s\n' "$line"
        return
    fi

    if [[ $line == *"$php "* ]]; then
        after_php=${line#*"$php "}
        if [[ $after_php == artisan\ * || $after_php == *' artisan '* ]]; then
            if [[ $after_php == artisan\ * ]]; then
                php_options=''
            else
                php_options=${after_php%% artisan *}
            fi
            if [[ " $php_options " == *' -d memory_limit='* ]]; then
                printf '%s\n' "$line"
            else
                printf '%s\n' "${line/"$php "/$replacement}"
            fi
            return
        fi
    fi

    echo "Managed Artisan cron lines must invoke the configured PHP binary before 'artisan'." >&2
    echo "Refused line: $line" >&2
    exit 2
}

lines=()
while IFS= read -r raw || [ -n "$raw" ]; do
    line=$(trim "$raw")
    [ -n "$line" ] && lines+=("$line")
done <<<"$cron_lines"

if [ "${#lines[@]}" -eq 0 ]; then
    # shellcheck disable=SC2016 # $HOME is for cron to expand on the host.
    lines=("* * * * * cd \"\$HOME/$deploy_dir\" && $php artisan schedule:run $redirect # JOB:$deploy_dir-scheduler")
fi

while IFS= read -r raw || [ -n "$raw" ]; do
    line=$(trim "$raw")
    [ -n "$line" ] && lines+=("$line")
done <<<"$extra_cron_lines"

for line in "${lines[@]}"; do
    normalize_artisan_memory "$line"
done
