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
    local rest=$line
    local probe=$line
    local result=''
    local before
    local after_php
    local matched
    local leading_space
    local php_options
    local trailing_boundary
    local php_artisan_count=0
    local normalized_count=0
    local php_artisan_re='(^|[[:space:];|&()])[^[:space:];|&()]*php[0-9.-]*[[:space:]]+([^;|&()]*[[:space:]])?artisan([[:space:];|&()]|$)'
    local shell_boundary_re='[[:space:];|&()]'
    local invocation_re='^([[:space:]]+)([^;|&()]*[[:space:]])?artisan([[:space:];|&()]|$)'
    local memory_option_re='(^|[[:space:]])-d[[:space:]]*memory_limit='

    while [[ $probe =~ $php_artisan_re ]]; do
        matched=${BASH_REMATCH[0]}
        php_artisan_count=$((php_artisan_count + 1))
        probe=${probe#*"$matched"}
    done

    if [ "$php_artisan_count" -eq 0 ] && [[ $line != *"$php"* ]]; then
        printf '%s\n' "$line"
        return
    fi

    while [[ $rest == *"$php"* ]]; do
        before=${rest%%"$php"*}
        after_php=${rest#*"$php"}
        result+="$before$php"
        rest=$after_php

        # A textual occurrence such as `[ -x /path/to/php ]` is not an
        # executable token. Keep scanning for the PHP command that follows it.
        if [[ -n $before && ! ${before: -1} =~ $shell_boundary_re ]]; then
            continue
        fi

        # Support ordinary PHP CLI options while stopping at shell control
        # operators. This ties `artisan` to this PHP token without attempting
        # to parse arbitrary shell syntax.
        if [[ $after_php =~ $invocation_re ]]; then
            matched=${BASH_REMATCH[0]}
            leading_space=${BASH_REMATCH[1]}
            php_options=${BASH_REMATCH[2]-}
            trailing_boundary=${BASH_REMATCH[3]}

            if [[ $php_options =~ $memory_option_re ]]; then
                result+="$matched"
            else
                result+="${leading_space}-d memory_limit=$memory_limit ${php_options}artisan${trailing_boundary}"
            fi

            rest=${after_php#"$matched"}
            normalized_count=$((normalized_count + 1))
        fi
    done

    result+="$rest"

    if [ "$normalized_count" -lt "$php_artisan_count" ]; then
        echo "Every Artisan invocation in a managed cron line must use the configured PHP binary and ordinary PHP CLI options." >&2
        echo "Refused line: $line" >&2
        exit 2
    fi

    printf '%s\n' "$result"
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
