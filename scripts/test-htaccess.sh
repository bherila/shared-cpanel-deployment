#!/usr/bin/env bash
# Local harness for htaccess.sh.
# Usage: test-htaccess.sh
# shellcheck disable=SC2016,SC2034,SC2317,SC2329 # Checks are eval'd strings; what they call looks unused (SC2317 on older shellcheck).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/htaccess.sh"
fails=0

setup() {
    root=$(mktemp -d)
    mkdir -p "$root/public"
    printf '<IfModule mod_rewrite.c>\n    RewriteEngine On\n</IfModule>\n' >"$root/public/.htaccess"
    export PHP_VERSION_WANTED=8.5 SET_HANDLER=true WEB_MEMORY_LIMIT=1024M HTACCESS_FILE=public/.htaccess
}
run() { (cd "$root" && bash "$script" >/dev/null 2>&1); }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
count() { grep -c -- "$1" "$root/public/.htaccess" || true; }

# 1. A plain file gets the handler and the LiteSpeed memory block, and keeps its own content.
setup
run; status=$?
check "a plain file is updated" '[ "$status" -eq 0 ]'
check "the ea-php85 handler is added" '[ "$(count "AddHandler application/x-httpd-ea-php85")" = 1 ]'
check "the memory limit is added" '[ "$(count "php_value memory_limit 1024M")" = 1 ]'
check "existing rules are kept" '[ "$(count "RewriteEngine On")" = 1 ]'

# 2. Running again adds nothing.
before=$(cat "$root/public/.htaccess")
run; status=$?
check "a second run succeeds and changes nothing" '[ "$status" -eq 0 ] && [ "$(cat "$root/public/.htaccess")" = "$before" ]'

# 3. An existing matching handler and memory_limit (indented, as repositories write it) are left alone.
setup
printf '<IfModule LiteSpeed>\n    php_value memory_limit 2048M\n</IfModule>\n<IfModule mime_module>\n  AddHandler application/x-httpd-ea-php85 .php\n</IfModule>\n' >>"$root/public/.htaccess"
before=$(cat "$root/public/.htaccess")
run; status=$?
check "existing handler and memory_limit are left alone" '[ "$status" -eq 0 ] && [ "$(cat "$root/public/.htaccess")" = "$before" ]'

# 4. A handler for another PHP is an error, not a second handler.
setup
printf 'AddHandler application/x-httpd-ea-php81 .php\n' >>"$root/public/.htaccess"
run; status=$?
check "a different existing handler fails" '[ "$status" -eq 1 ] && [ "$(count "ea-php85")" = 0 ]'

# 5. Switches and validation.
setup
SET_HANDLER=false WEB_MEMORY_LIMIT='' run; status=$?
check "with both off the file is unchanged" '[ "$status" -eq 0 ] && [ "$(count "AddHandler")" = 0 ] && [ "$(count "php_value")" = 0 ]'
setup
PHP_VERSION_WANTED=8 run; v=$?
WEB_MEMORY_LIMIT=lots run; m=$?
check "an invalid version or memory limit is refused" '[ "$v" -eq 2 ] && [ "$m" -eq 2 ] && [ "$(count "AddHandler")" = 0 ]'
setup
rm "$root/public/.htaccess"
run; status=$?
check "a missing .htaccess is refused" '[ "$status" -eq 2 ]'

echo "failures: $fails"
exit "$fails"
