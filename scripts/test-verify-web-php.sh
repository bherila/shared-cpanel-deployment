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
    'bash -s -- '*) printf '%s\n' "$command" >>"$PROBE_FIXTURE/origin-commands"; eval "set -- ${command#bash -s -- }"; exec bash -s -- "$@" ;;
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
    if [ "$1" = --resolve ]; then printf '%s\n' "$2" >"$PROBE_FIXTURE/resolve"; shift; fi
    case $1 in https://*) printf '%s\n' "$1" >"$PROBE_FIXTURE/url" ;; esac
    shift
done
printf '%s' "$output" >"$PROBE_FIXTURE/response-path"
response=$(sed -n "${count}p" "$PROBE_FIXTURE/responses")
case $response in
    html) printf '<!DOCTYPE html>\nPRIVATE_ERROR_DETAIL\n' >"$output"; printf '200|text/html; charset=UTF-8' ;;
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
    bash "$here/verify-web-php.sh" fake-host app "${site_url:-https://example.invalid}" 8.5 1024M \
        >"$probe_fixture/log" 2>&1 || status=$?
    local requests=0
    [ ! -f "$probe_fixture/count" ] || requests=$(<"$probe_fixture/count")
    if [ "$status" -ne "$expected_status" ] || [ "$requests" -ne "$expected_requests" ]; then
        printf 'FAIL - %s (status %s, requests %s)\n' "$label" "$status" "$requests"
        cat "$probe_fixture/log"
        exit 1
    fi
    if [ "$expected_requests" -eq 0 ]; then
        [ ! -e "$probe_fixture/remote-probe" ]
        printf 'ok - %s; nothing was written to the host\n' "$label"
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
WEB_PHP_PROBE_WINDOW=0 run_case 'an exhausted window stops retrying' 1 1 html html '8.5|1024M|litespeed'
grep -Eq 'after 1 attempts in [0-9]+s' "$probe_fixture/log"
WEB_PHP_PROBE_WINDOW=soon run_case 'a malformed window is refused' 2 0 '8.5|1024M|litespeed'
run_case 'a title longer than a pipe buffer keeps retrying' 0 3 longtitle longtitle '8.5|1024M|litespeed'
run_case 'well-formed wrong PHP fails immediately and definitively' 3 1 '8.4|1024M|litespeed' '8.5|1024M|litespeed'
run_case 'insufficient memory fails immediately and definitively' 3 1 '8.5|128M|litespeed' '8.5|1024M|litespeed'
run_case 'extra fields and multiline content fail closed' 1 8 '8.5|1024M|litespeed|extra' multiline '8.5|bogus|litespeed'
