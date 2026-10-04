#!/usr/bin/env bash
# Exercise runtime probe retries and cleanup without connecting to a production host.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
probe_fixture=$(mktemp -d)
trap 'rm -rf "$probe_fixture"' EXIT
export PROBE_FIXTURE="$probe_fixture"
mkdir "$probe_fixture/bin"

cat >"$probe_fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case ${*: -1} in
    'umask 022 && cat > '*) cat >"$PROBE_FIXTURE/remote-probe" ;;
    'rm -f '*) rm -f "$PROBE_FIXTURE/remote-probe"; touch "$PROBE_FIXTURE/cleaned" ;;
    *) exit 99 ;;
esac
MOCK

cat >"$probe_fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count=0
[ ! -f "$PROBE_FIXTURE/count" ] || count=$(<"$PROBE_FIXTURE/count")
count=$((count + 1))
printf '%s' "$count" >"$PROBE_FIXTURE/count"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then output=$2; shift; fi
    shift
done
printf '%s' "$output" >"$PROBE_FIXTURE/response-path"
response=$(sed -n "${count}p" "$PROBE_FIXTURE/responses")
case $response in
    html) printf '<!DOCTYPE html>\nPRIVATE_ERROR_DETAIL\n' >"$output"; printf '200|text/html; charset=UTF-8' ;;
    multiline) printf '8.5|1024M|litespeed\nPRIVATE_ERROR_DETAIL\n' >"$output"; printf '200|text/plain' ;;
    transport) : >"$output"; printf '000|'; exit 7 ;;
    *) printf '%s' "$response" >"$output"; printf '200|text/plain' ;;
esac
MOCK
cat >"$probe_fixture/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$probe_fixture/bin/"*
export PATH="$probe_fixture/bin:$PATH"

run_case() {
    local label=$1 expected_status=$2 expected_requests=$3
    shift 3
    rm -f "$probe_fixture/count" "$probe_fixture/cleaned"
    printf '%s\n' "$@" >"$probe_fixture/responses"
    local status=0
    bash "$here/verify-web-php.sh" fake-host app https://example.invalid 8.5 1024M \
        >"$probe_fixture/log" 2>&1 || status=$?
    if [ "$status" -ne "$expected_status" ] || [ "$(<"$probe_fixture/count")" -ne "$expected_requests" ]; then
        printf 'FAIL - %s (status %s, requests %s)\n' "$label" "$status" "$(<"$probe_fixture/count")"
        cat "$probe_fixture/log"
        exit 1
    fi
    [ -f "$probe_fixture/cleaned" ] && [ ! -e "$probe_fixture/remote-probe" ]
    [ ! -e "$(<"$probe_fixture/response-path")" ]
    if grep -q 'PRIVATE_ERROR_DETAIL\|PHP <!DOCTYPE' "$probe_fixture/log"; then
        echo 'FAIL - an invalid body was disclosed or interpreted as a PHP version'
        exit 1
    fi
    printf 'ok - %s; remote and local probe files cleaned\n' "$label"
}

run_case 'valid runtime passes' 0 1 '8.5|1024M|litespeed'
run_case 'HTTP 200 HTML retries and recovers' 0 2 html '8.5|1G|litespeed'
run_case 'transport failure retries and recovers' 0 2 transport '8.5|-1|fpm-fcgi'
run_case 'persistent HTML fails after three attempts' 1 3 html html html
grep -q 'HTTP 200, content-type text/html' "$probe_fixture/log"
grep -q 'does not establish a PHP version' "$probe_fixture/log"
run_case 'well-formed wrong PHP fails immediately' 1 1 '8.4|1024M|litespeed' '8.5|1024M|litespeed'
run_case 'insufficient memory fails immediately' 1 1 '8.5|128M|litespeed' '8.5|1024M|litespeed'
run_case 'extra fields and multiline content fail closed' 1 3 '8.5|1024M|litespeed|extra' multiline '8.5|bogus|litespeed'
