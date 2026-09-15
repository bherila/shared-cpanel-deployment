#!/usr/bin/env bash
#
# Pin the site's PHP in public/.htaccess before upload.
#
# Runs ON THE RUNNER, from the checkout root. Environment:
#
#   HTACCESS_FILE        default public/.htaccess
#   PHP_VERSION_WANTED   major.minor, e.g. 8.5
#   SET_HANDLER          "true" appends cPanel's handler block for that version
#   WEB_MEMORY_LIMIT     php_value memory_limit for LiteSpeed, e.g. 1024M; empty leaves it alone
#
# Why this is a deploy step: a vhost without the handler falls back to the account's default PHP and
# returns 500 on every page while the deploy reports success. On LiteSpeed, `.user.ini` is silently
# ignored; only `php_value` inside `<IfModule LiteSpeed>` in .htaccess is honoured.
#
# Idempotent and non-destructive: a handler or memory_limit the file already sets is left as it is
# (with a notice when it names a different PHP), so a repository that still appends its own block does
# not end up with two.
set -euo pipefail

file=${HTACCESS_FILE:-public/.htaccess}
version=${PHP_VERSION_WANTED:-}
set_handler=${SET_HANDLER:-true}
memory=${WEB_MEMORY_LIMIT:-}

case $version in
    [0-9].[0-9] | [0-9].[0-9][0-9]) ;;
    *) echo "::error::PHP version must be major.minor, not '$version'." >&2; exit 2 ;;
esac
case $memory in
    '' | -1 | [1-9]*[0-9][GgMmKk] | [1-9][GgMmKk] | [1-9]*[0-9]) ;;
    *) echo "::error::web-memory-limit '$memory' is not a php.ini size." >&2; exit 2 ;;
esac

if [ ! -f "$file" ]; then
    echo "::error::$file does not exist; a Laravel checkout ships one." >&2
    exit 2
fi

package="ea-php${version//./}"

if [ "$set_handler" = true ]; then
    existing=$(grep -Eo 'application/x-httpd-ea-php[0-9]+' "$file" | head -1 || true)
    if [ -z "$existing" ]; then
        # shellcheck disable=SC1111 # The curly quotes are cPanel's own text for this block.
        cat >>"$file" <<EOF

# php -- BEGIN cPanel-generated handler, do not edit
# Set the “${package}” package as the default “PHP” programming language.
<IfModule mime_module>
  AddHandler application/x-httpd-$package .php .php8 .phtml
</IfModule>
# php -- END cPanel-generated handler, do not edit
EOF
        echo "Set the web handler to $package."
    elif [ "$existing" != "application/x-httpd-$package" ]; then
        echo "::error::$file already sets ${existing#application/x-httpd-}, not $package. Remove the stale handler block." >&2
        exit 1
    else
        echo "$file already sets $package."
    fi
fi

if [ -n "$memory" ]; then
    if grep -Eq '^[[:space:]]*php_value[[:space:]]+memory_limit[[:space:]]' "$file"; then
        echo "$file already sets php_value memory_limit; leaving it."
    else
        cat >>"$file" <<EOF

<IfModule LiteSpeed>
  php_value memory_limit $memory
</IfModule>
EOF
        echo "Set the LiteSpeed memory_limit to $memory."
    fi
fi
