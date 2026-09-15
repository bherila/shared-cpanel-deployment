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
    remote_ssh "rm -f \"\$HOME/$remote\"" <&- || echo "::warning::Could not delete ~/$remote; remove it by hand." >&2
}
trap cleanup EXIT

remote_ssh "umask 022 && cat > \"\$HOME/$remote\"" <<'PHP'
<?php
header('Content-Type: text/plain');
header('Cache-Control: no-store');
echo PHP_MAJOR_VERSION, '.', PHP_MINOR_VERSION, '|', ini_get('memory_limit'), '|', PHP_SAPI;
PHP

answer=$(curl --fail --silent --show-error --retry 3 --retry-all-errors --max-time 20 "$site_url/$name")
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
