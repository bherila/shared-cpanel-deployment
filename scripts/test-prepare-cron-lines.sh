#!/usr/bin/env bash
# shellcheck disable=SC2016 # Cron fixtures intentionally preserve literal $HOME for the host.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/prepare-cron-lines.sh"
fails=0

check() {
    local name=$1
    shift
    if "$@"; then
        echo "ok   - $name"
    else
        echo "FAIL - $name"
        fails=$((fails + 1))
    fi
}

PHP=/opt/cpanel/ea-php85/root/usr/bin/php

output=$(bash "$script" app "$PHP" 1G /dev/null '' '')
expected='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G artisan schedule:run > /dev/null 2>&1 # JOB:app-scheduler'
check "the default scheduler gets 1G" test "$output" = "$expected"

custom=$(cat <<'EOF'
*/5 * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php artisan custom:schedule > /dev/null 2>&1 # JOB:app-scheduler
*/5 * * * * cd "$HOME/app" && /usr/bin/flock -n "$HOME/app/storage/framework/worker.lock" /opt/cpanel/ea-php85/root/usr/bin/php artisan queue:work --stop-when-empty > /dev/null 2>&1 # JOB:app-worker
EOF
)
output=$(bash "$script" app "$PHP" 1G /dev/null "$custom" '')
inherited_count=$(grep -Fc -- '-d memory_limit=1G artisan' <<<"$output")
check "custom scheduler and flocked worker inherit 1G" test "$inherited_count" -eq 2

explicit='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=512M artisan queue:work # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null '' "$explicit")
expected_with_explicit=$(printf '%s\n%s' "$expected" "$explicit")
check "an explicit worker limit is preserved" test "$output" = "$expected_with_explicit"

other_option='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d opcache.enable_cli=1 artisan queue:work # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$other_option" '')
expected_other_option='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G -d opcache.enable_cli=1 artisan queue:work # JOB:app-worker'
check "other PHP options are preserved when memory is added" test "$output" = "$expected_other_option"

two_options='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d opcache.enable_cli=1 -d memory_limit=768M artisan queue:work # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$two_options" '')
check "an explicit limit after another PHP option is preserved" test "$output" = "$two_options"

tabbed=$'* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php\tartisan queue:work # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$tabbed" '')
expected_tabbed=$'* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php\t-d memory_limit=1G artisan queue:work # JOB:app-worker'
check "tabs between PHP and Artisan are supported" test "$output" = "$expected_tabbed"

tested_php='* * * * * cd "$HOME/app" && [ -x /opt/cpanel/ea-php85/root/usr/bin/php ] && /opt/cpanel/ea-php85/root/usr/bin/php artisan queue:work # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$tested_php" '')
expected_tested_php='* * * * * cd "$HOME/app" && [ -x /opt/cpanel/ea-php85/root/usr/bin/php ] && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G artisan queue:work # JOB:app-worker'
check "a prior textual PHP path is not modified" test "$output" = "$expected_tested_php"

chained='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php artisan schedule:run && /opt/cpanel/ea-php85/root/usr/bin/php -d opcache.enable_cli=1 artisan queue:work # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$chained" '')
expected_chained='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G artisan schedule:run && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G -d opcache.enable_cli=1 artisan queue:work # JOB:app-worker'
check "every Artisan invocation in a chained line is normalized" test "$output" = "$expected_chained"

mixed_php='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php artisan schedule:run && php artisan queue:work # JOB:app-worker'
bash "$script" app "$PHP" 1G /dev/null "$mixed_php" '' >/dev/null 2>&1
status=$?
check "a chained Artisan invocation through another PHP binary is refused" test "$status" -eq 2

artisan_argument='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php artisan custom:run artisan # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$artisan_argument" '')
expected_artisan_argument='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G artisan custom:run artisan # JOB:app-worker'
check "an Artisan word used as an argument is not counted as another invocation" test "$output" = "$expected_artisan_argument"

artisan_memory_argument='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php artisan custom:run -d memory_limit=64M artisan # JOB:app-worker'
output=$(bash "$script" app "$PHP" 1G /dev/null "$artisan_memory_argument" '')
expected_artisan_memory_argument='* * * * * cd "$HOME/app" && /opt/cpanel/ea-php85/root/usr/bin/php -d memory_limit=1G artisan custom:run -d memory_limit=64M artisan # JOB:app-worker'
check "PHP-looking Artisan arguments do not suppress the process limit" test "$output" = "$expected_artisan_memory_argument"

quoted_php='* * * * * cd "$HOME/app" && "/opt/cpanel/ea-php85/root/usr/bin/php" artisan queue:work # JOB:app-worker'
bash "$script" app "$PHP" 1G /dev/null "$quoted_php" '' >/dev/null 2>&1
status=$?
check "a quoted configured PHP path is refused explicitly" test "$status" -eq 2

CUSTOM_PHP=/usr/local/bin/php-cli
mixed_custom_php='* * * * * cd "$HOME/app" && /usr/local/bin/php-cli artisan schedule:run && php artisan queue:work # JOB:app-worker'
bash "$script" app "$CUSTOM_PHP" 1G /dev/null "$mixed_custom_php" '' >/dev/null 2>&1
status=$?
check "a custom PHP executable cannot hide another PHP binary" test "$status" -eq 2

non_artisan='0 * * * * cd "$HOME/app" && ./scripts/rotate.sh # JOB:app-rotate'
output=$(bash "$script" app "$PHP" 1G /dev/null "$non_artisan" '')
check "non-Artisan managed commands are unchanged" test "$output" = "$non_artisan"

wrong_php='* * * * * cd "$HOME/app" && php artisan queue:work # JOB:app-worker'
bash "$script" app "$PHP" 1G /dev/null "$wrong_php" '' >/dev/null 2>&1
status=$?
check "Artisan through an unconfigured PHP binary is refused" test "$status" -eq 2

bash "$script" app "$PHP" 128 /dev/null '' '' >/dev/null 2>&1
status=$?
check "a unitless memory limit is refused" test "$status" -eq 2

echo "failures: $fails"
exit "$fails"
