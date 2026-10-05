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
command=${*: -1}
case $command in
    'umask 022 && cat > '*) cat >"$PROBE_FIXTURE/remote-probe" ;;
    'rm -f '*) rm -f "$PROBE_FIXTURE/remote-probe"; touch "$PROBE_FIXTURE/cleaned" ;;
    # The origin fetch: run the real origin-fetch.sh from stdin, as the host would.
    'bash -s -- '*) [[ ${PROBE_SSH_STALL:-0} != 1 ]] || { sleep 30; exit 1; }; printf '%s\n' "$command" >>"$PROBE_FIXTURE/origin-commands"; eval "set -- ${command#bash -s -- }"; exec bash -s -- "$@" ;;
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
    if [ "$1" = --resolve ]; then resolve=$2; printf '%s\n' "$2" >"$PROBE_FIXTURE/resolve"; shift; fi
    case $1 in https://*) printf '%s\n' "$1" >"$PROBE_FIXTURE/url" ;; esac
    shift
done
printf '%s' "$output" >"$PROBE_FIXTURE/response-path"
response=$(sed -n "${count}p" "$PROBE_FIXTURE/responses")
if [[ ${PROBE_MULTIPLE_IPS:-0} == 1 && $resolve == *:192.0.2.1 ]]; then response=html; fi
case $response in
    html) printf '<!DOCTYPE html>\nPRIVATE_ERROR_DETAIL\n' >"$output"; printf '200|text/html; charset=UTF-8' ;;
    nul) printf '8.5\0|1024M|litespeed' >"$output"; printf '200|text/plain' ;;
    newline) printf '8.5|1024M|litespeed\n' >"$output"; printf '200|text/plain' ;;
    blanklines) printf '8.5|1024M|litespeed\n\n' >"$output"; printf '200|text/plain' ;;
    multiline) printf '8.5|1024M|litespeed\nPRIVATE_ERROR_DETAIL\n' >"$output"; printf '200|text/plain' ;;
    longtitle) { printf '<html><title>'; head -c 300000 /dev/zero | tr '\0' 'a'; printf '</title></html>\n'; } >"$output"; printf '200|text/html' ;;
    titled) printf '<html><head>\n<title>Service "Unavailable" | 8.5|1G|x</title></head><body>PRIVATE_ERROR_DETAIL</body></html>\n' >"$output"; printf '200|text/html' ;;
    transport) : >"$output"; printf '000|'; exit 7 ;;
    notfound) printf '<html><title>Not Found</title></html>' >"$output"; printf '404|text/html' ;;
    *) printf '%s' "$response" >"$output"; printf '200|text/plain' ;;
esac
MOCK
# The host has no addresses of its own in the fixture, so origin-fetch.sh tries loopback once.
cat >"$probe_fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[[ ${PROBE_MULTIPLE_IPS:-0} != 1 ]] || printf '192.0.2.1 192.0.2.2\n'
exit 0
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
    local command=(bash "$here/verify-web-php.sh" fake-host app "${site_url:-https://example.invalid}" 8.5 "${minimum_memory:-1024M}")
    [[ ${PROBE_LONG_ZERO:-0} != 1 ]] || command=(/usr/bin/timeout --signal=KILL 5s "${command[@]}")
    "${command[@]}" >"$probe_fixture/log" 2>&1 || status=$?
    local requests=0
    [ ! -f "$probe_fixture/count" ] || requests=$(<"$probe_fixture/count")
    if [ "$status" -ne "$expected_status" ] || [ "$requests" -ne "$expected_requests" ]; then
        printf 'FAIL - %s (status %s, requests %s)\n' "$label" "$status" "$requests"
        cat "$probe_fixture/log"
        exit 1
    fi
    if [ "$expected_requests" -eq 0 ]; then
        [ ! -e "$probe_fixture/remote-probe" ]
        printf 'ok - %s; no remote probe remains\n' "$label"
        return
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
# 2026-10-05: a proxy rule challenging non-US visitors answered the runner's own requests with an
# HTML 200. The probe is fetched from the host's web server under the site's name instead.
grep -Eq '^example\.invalid:443:127\.0\.0\.1$' "$probe_fixture/resolve"
grep -Eq '^https://example\.invalid/_deploy-php-check-[0-9a-f]{32}\.php$' "$probe_fixture/url"
site_url=https://example.invalid:443 run_case 'a site URL with an explicit port is accepted' 0 1 '8.5|1024M|litespeed'
grep -Eq '^example\.invalid:443:127\.0\.0\.1$' "$probe_fixture/resolve"
run_case 'a non-2xx origin answer is retried as a failed fetch' 0 2 notfound '8.5|1024M|litespeed'
run_case 'HTTP 200 HTML retries and recovers' 0 2 html '8.5|1G|litespeed'
run_case 'transport failure retries and recovers' 0 2 transport '8.5|-1|fpm-fcgi'
# 2026-10-05: on LiteSpeed the requests after a change under public/ were answered with an
# HTML 200 for longer than three tries two seconds apart; the window now lasts about a minute.
run_case 'HTML for five attempts still recovers' 0 6 html html html html html '8.5|1024M|litespeed'
run_case 'persistent HTML fails after eight attempts' 1 8 html html html html html html html html
grep -q 'HTTP 200, content-type text/html' "$probe_fixture/log"
grep -q 'after 8 attempts in ' "$probe_fixture/log"
grep -q 'does not establish a PHP version' "$probe_fixture/log"
run_case 'an HTML title is reported only as a fingerprint' 1 8 titled titled titled titled titled titled titled titled
grep -Eq 'title sha256 [0-9a-f]{12}\)' "$probe_fixture/log"
if grep -q 'Service\|Unavailable\|title>' "$probe_fixture/log"; then
    echo 'FAIL - the text of an HTML title was disclosed'
    exit 1
fi
# The whole window is bounded, not just its sleeps: with no time left, no further attempt starts.
WEB_PHP_PROBE_WINDOW=0 run_case 'an exhausted window starts no fetch' 1 0 html html '8.5|1024M|litespeed'
grep -Eq 'after 0 attempts in [0-9]+s' "$probe_fixture/log"
WEB_PHP_PROBE_WINDOW=soon run_case 'a malformed window is refused' 2 0 '8.5|1024M|litespeed'
run_case 'a title longer than a pipe buffer keeps retrying' 0 3 longtitle longtitle '8.5|1024M|litespeed'
run_case 'well-formed wrong PHP fails immediately and definitively' 3 1 '8.4|1024M|litespeed' '8.5|1024M|litespeed'
run_case 'insufficient memory fails immediately and definitively' 3 1 '8.5|128M|litespeed' '8.5|1024M|litespeed'
run_case 'raw byte overflow is an unreadable definitive runtime' 3 1 '8.5|18446744073709551616|litespeed'
run_case 'scaled runtime overflow is unreadable and definitive' 3 1 '8.5|8589934592G|litespeed'
run_case 'leading zero runtime memory is decimal' 0 1 '8.5|01024M|litespeed'
long_zeros=$(printf '%020000d' 0)
PROBE_LONG_ZERO=1 WEB_PHP_PROBE_WINDOW=1 run_case 'overlong zero runtime field is bounded and inconclusive' 1 1 "8.5|${long_zeros}1024M|litespeed"
short_zeros=$(printf '%0300d' 0)
run_case 'bounded leading zeros normalize without a per-character loop' 0 1 "8.5|${short_zeros}1024M|litespeed"
run_case 'zero actual memory remains definitively below minimum'  3 1 '8.5|0|litespeed'
minimum_memory=0 run_case 'zero requested minimum is refused before SSH' 2 0
minimum_memory=18446744073709551616 run_case 'overflow requested bytes are refused before SSH' 2 0
minimum_memory=8589934592G run_case 'overflow requested units are refused before SSH' 2 0
run_case 'one terminal runtime newline preserves metadata framing' 0 1 newline
run_case 'NUL runtime fields fail closed before shell decoding' 1 8 nul nul nul nul nul nul nul nul
run_case 'extra runtime blank lines fail closed' 1 8 blanklines blanklines blanklines blanklines blanklines blanklines blanklines blanklines
run_case 'extra fields and multiline content fail closed' 1 8 '8.5|1024M|litespeed|extra' multiline '8.5|bogus|litespeed'

PROBE_MULTIPLE_IPS=1 run_case 'wrong-vhost HTML tries the later correct runtime' 0 2 html '8.5|1024M|litespeed'
PROBE_MULTIPLE_IPS=1 run_case 'later wrong runtime remains definitive' 3 2 html '8.4|128M|litespeed'
# Preserve actual sleep for the stalled SSH command; other retry fixture sleeps
# remain synthetic. The real timeout must terminate the entire SSH invocation.
cat >"$probe_fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
command=${*: -1}
case $command in
    'umask 022 && cat > '*) cat >"$PROBE_FIXTURE/remote-probe" ;;
    'rm -f '*) rm -f "$PROBE_FIXTURE/remote-probe"; touch "$PROBE_FIXTURE/cleaned" ;;
    'bash -s -- '*) /usr/bin/sleep 30 ;;
    *) exit 99 ;;
esac
MOCK
started=$SECONDS
WEB_PHP_PROBE_WINDOW=1 run_case 'stalled SSH fetch cannot exceed the whole retry budget' 1 0
(( SECONDS - started < 4 )) || { echo 'SSH fetch exceeded window'; exit 1; }
[[ -f $probe_fixture/cleaned ]]
grep -Eq 'after 1 attempts in [0-9]+s' "$probe_fixture/log"

# Unexpected SSH output is bounded independently of the trusted host helper.
cat >"$probe_fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
command=${*: -1}
case $command in
    'umask 022 && cat > '*) cat >"$PROBE_FIXTURE/remote-probe" ;;
    'rm -f '*) rm -f "$PROBE_FIXTURE/remote-probe"; touch "$PROBE_FIXTURE/cleaned" ;;
    'bash -s -- '*) head -c 1048576 /dev/zero | tr '\0' x; printf '\nORIGIN-META 200|text/plain\n' ;;
    *) exit 99 ;;
esac
MOCK
WEB_PHP_PROBE_WINDOW=1 run_case 'oversized SSH response fails before buffering or runtime decoding' 1 0
if grep -Fq 'xxxxxxxxxxxxxxxx' "$probe_fixture/log"; then echo 'Oversized SSH body leaked'; exit 1; fi

# The final metadata record is validated as bytes before shell substitution
# can remove a NUL from its status or accept a second metadata line.
cat >"$probe_fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
command=${*: -1}
case $command in
    'umask 022 && cat > '*) cat >"$PROBE_FIXTURE/remote-probe" ;;
    'rm -f '*) rm -f "$PROBE_FIXTURE/remote-probe"; touch "$PROBE_FIXTURE/cleaned" ;;
    'bash -s -- '*)
        case ${PROBE_METADATA_KIND:-nul} in
            nul) printf '8.5|1024M|litespeed\nORIGIN-META 2\00000|text/plain\n' ;;
            secret) printf '8.5|1024M|litespeed\nORIGIN-META SECRET_TOKEN|text/plain\n' ;;
            unterminated) printf '8.5|1024M|litespeed\nORIGIN-META 200|text/plain' ;;
        esac ;;

    *) exit 99 ;;
esac
MOCK
WEB_PHP_PROBE_WINDOW=1 run_case 'NUL in raw SSH metadata is refused before shell decoding' 1 0
PROBE_METADATA_KIND=secret WEB_PHP_PROBE_WINDOW=1 run_case 'raw metadata status payload is never logged' 1 0
if grep -Fq SECRET "$probe_fixture/log"; then echo 'Metadata status payload leaked'; exit 1; fi
PROBE_METADATA_KIND=unterminated WEB_PHP_PROBE_WINDOW=1 run_case 'missing terminal metadata newline fails closed' 1 0
if grep -Fq 'ignored null byte'  "$probe_fixture/log"; then echo 'Malformed metadata reached shell decode'; exit 1; fi

# Creation and cleanup have independent finite budgets. Scale those fixed budgets
# to one second only in this fixture, while asserting the actual caller supplies
# 20s and testing the real timeout's process termination.
cat >"$probe_fixture/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
[[ $1 == --signal=KILL && $2 == 20s && $3 == ssh ]] || exec /usr/bin/timeout "$@"
printf '%s\n' "20s ${*: -1}" >>"$PROBE_FIXTURE/timeout-budgets"
shift 2
exec /usr/bin/timeout --signal=KILL 1s "$@"
MOCK
chmod +x "$probe_fixture/bin/timeout"
cat >"$probe_fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
command=${*: -1}
case $command in
    'umask 022 && cat > '*)
        [[ ${PROBE_STAGE_STALL:-} != create ]] || /usr/bin/sleep 30
        cat >"$PROBE_FIXTURE/remote-probe" ;;
    'rm -f '*)
        [[ ${PROBE_STAGE_STALL:-} != cleanup ]] || /usr/bin/sleep 30
        rm -f "$PROBE_FIXTURE/remote-probe"; touch "$PROBE_FIXTURE/cleaned" ;;
    'bash -s -- '*) eval "set -- ${command#bash -s -- }"; exec bash -s -- "$@" ;;
    *) exit 99 ;;
esac
MOCK
started=$SECONDS
PROBE_STAGE_STALL=create run_case 'stalled probe creation has a separate finite SSH budget' 137 0
(( SECONDS - started < 4 )) || { echo 'SSH creation exceeded fixture budget'; exit 1; }
grep -Fq '20s umask 022 && cat > ' "$probe_fixture/timeout-budgets"
started=$SECONDS
printf '8.5|1024M|litespeed\n' >"$probe_fixture/responses"
rm -f "$probe_fixture/count"
status=0
PROBE_STAGE_STALL=cleanup bash "$here/verify-web-php.sh" fake-host app https://example.invalid 8.5 1024M >"$probe_fixture/cleanup-log" 2>&1 || status=$?
[[ $status == 0 && -e $probe_fixture/remote-probe ]] || { cat "$probe_fixture/cleanup-log"; exit 1; }
(( SECONDS - started < 6 )) || { echo 'SSH cleanup exceeded fixture budget'; exit 1; }
grep -Fq '20s rm -f ' "$probe_fixture/timeout-budgets"
grep -Fq 'Could not delete' "$probe_fixture/cleanup-log"
rm -f "$probe_fixture/remote-probe"
echo 'ok - stalled cleanup is bounded and reports the undeleted probe'
