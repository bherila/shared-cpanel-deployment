#!/usr/bin/env bash
#
# Verify, through the site's own URL, that the web handler runs the PHP this application needs.
#
# Runs ON THE RUNNER, after the deploy:
#
#   .github/scripts/verify-web-php.sh <ssh-target> <app-dir> <site-url> <php-version> <min-memory-limit> [ssh option...]
#
# The web handler's limits cannot be read from the CLI, and on LiteSpeed they cannot be trusted from a
# file either: `.user.ini` is silently ignored there, and only `php_value` in `public/.htaccess` is
# honoured. So this asks the running vhost. It writes a one-line PHP file with an unguessable name
# into public/, fetches it through <site-url>, and always deletes it again. The file prints the PHP
# version, `memory_limit` and SAPI — nothing else.
#
# Fails the deploy when the web handler runs a different PHP major.minor than <php-version>, or a
# `memory_limit` below <min-memory-limit> (for example 1024M; -1, unlimited, satisfies any minimum).
set -euo pipefail

if [ "$#" -lt 5 ]; then
    echo "usage: verify-web-php.sh <ssh-target> <app-dir> <site-url> <php-version> <min-memory-limit> [ssh option...]" >&2
    exit 2
fi

target=$1
app_dir=$2
site_url=${3%/}
want_php=$4
want_memory=$5
shift 5
ssh_options=("$@")

case $app_dir in
    ''|*[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain directory name under the account home." >&2
        exit 2 ;;
esac

# Bytes for a php.ini size ("1024M", "1G", "536870912"); -1 for unlimited; empty when unparseable.
to_bytes() {
    local value=$1
    case $value in
        -1) echo -1 ;;
        *[0-9][Gg]) echo $(( ${value%[Gg]} * 1073741824 )) ;;
        *[0-9][Mm]) echo $(( ${value%[Mm]} * 1048576 )) ;;
        *[0-9][Kk]) echo $(( ${value%[Kk]} * 1024 )) ;;
        ''|*[!0-9]*) echo '' ;;
        *) echo "$value" ;;
    esac
}

minimum=$(to_bytes "$want_memory")
if [ -z "$minimum" ] || [ "$minimum" = -1 ]; then
    echo "::error::The minimum memory_limit '$want_memory' is not a positive php.ini size." >&2
    exit 2
fi

name="_deploy-php-check-$(openssl rand -hex 16).php"
remote="$app_dir/public/$name"

# "${ssh_options[@]+...}" rather than "${ssh_options[@]}": with no options, older bash treats the
# empty array as unset under `set -u`. $remote is expanded here on purpose; $HOME on the host.
remote_ssh() {
    # shellcheck disable=SC2029
    ssh ${ssh_options[@]+"${ssh_options[@]}"} "$target" "$1"
}

cleanup() {
    [ -z "${response_file:-}" ] || rm -f "$response_file"
    remote_ssh "rm -f \"\$HOME/$remote\"" <&- || echo "::warning::Could not delete ~/$remote; remove it by hand." >&2
}
trap cleanup EXIT

remote_ssh "umask 022 && cat > \"\$HOME/$remote\"" <<'PHP'
<?php
header('Content-Type: text/plain');
header('Cache-Control: no-store');
echo PHP_MAJOR_VERSION, '.', PHP_MINOR_VERSION, '|', ini_get('memory_limit'), '|', PHP_SAPI;
PHP

# A proxy or newly reloaded web handler can return an HTML page with HTTP 200. curl's HTTP
# retries do not catch that. Retry missing/malformed responses, but a real runtime that does
# not meet the application's requirements must fail immediately below.
#
# The window is about a minute, with backoff: on LiteSpeed the request that follows a change
# under public/ (a rewritten .htaccess handler, a swapped stable directory) has been answered
# with an HTML 200 for several seconds, which three tries two seconds apart did not outlast.
response_file=$(mktemp)
runtime_pattern='^[0-9]+\.[0-9]+\|(-1|[0-9]+[KkMmGg]?)\|[A-Za-z0-9_-]+$'
delays=(2 3 5 8 10 12 15)
attempts=$(( ${#delays[@]} + 1 ))
for (( attempt = 1; attempt <= attempts; attempt++ )); do
    if response_meta=$(curl --fail --silent --show-error --max-time 20 \
        --header 'Cache-Control: no-cache' --output "$response_file" \
        --write-out '%{http_code}|%{content_type}' "$site_url/$name"); then
        answer=$(<"$response_file")
        if [[ $answer =~ $runtime_pattern ]]; then
            break
        fi
        reason='did not return the PHP runtime fields'
    else
        reason='could not fetch the PHP runtime fields'
    fi
    IFS='|' read -r http_status content_type <<<"$response_meta"
    # Never print the body: an intermediary/error page might contain unrelated sensitive data.
    # Ignore arbitrary response header text as well; display only a recognizable MIME type, and
    # of an HTML page only its <title>, reduced to plain words, to say what answered instead.
    content_type=${content_type%%;*}
    [[ $content_type =~ ^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$ ]] || content_type=unknown
    # Truncated in the shell, not with head: head closing the pipe early would SIGPIPE sed on a
    # long title, and under pipefail that would end the probe before its retries and diagnostic.
    title=$(tr '\n\r' '  ' <"$response_file" 2>/dev/null | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<.*/\1/p' | tr -cd 'A-Za-z0-9 .,:()-') || title=''
    title=${title:0:80}
    detail="HTTP $http_status, content-type $content_type${title:+, title \"$title\"}"
    if [ "$attempt" -eq "$attempts" ]; then
        echo "::error::The web PHP probe $reason after $attempts attempts ($detail). Check the site's document root, rewrite rules, and proxy/WAF routing; this response does not establish a PHP version." >&2
        exit 1
    fi
    echo "::warning::The web PHP probe $reason ($detail); retrying in ${delays[attempt-1]}s ($attempt/$attempts)." >&2
    sleep "${delays[attempt-1]}"
done
IFS='|' read -r php memory sapi <<<"$answer"

echo "Web handler: PHP $php, memory_limit=$memory, SAPI $sapi."

if [ "$php" != "$want_php" ]; then
    echo "::error::The web handler runs PHP '$php', not $want_php. Check the cPanel handler block appended to public/.htaccess." >&2
    exit 1
fi

actual=$(to_bytes "$memory")
if [ -z "$actual" ]; then
    echo "::error::The web handler reported an unreadable memory_limit '$memory'." >&2
    exit 1
fi

if [ "$actual" != -1 ] && [ "$actual" -lt "$minimum" ]; then
    echo "::error::The web handler's memory_limit is $memory, below the required $want_memory. On LiteSpeed set" \
         "'php_value memory_limit $want_memory' inside '<IfModule LiteSpeed>' in public/.htaccess; .user.ini is ignored there." >&2
    exit 1
fi
