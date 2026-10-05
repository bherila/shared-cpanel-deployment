#!/usr/bin/env bash
# Exercise origin-fetch.sh: own-address fallback, output framing and input validation.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bash "$here/assert-no-process-substitution.sh" "$here/origin-fetch.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export FIXTURE="$fixture"
actual_curl=$(command -v curl)
mkdir "$fixture/bin"
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -I ] && printf '192.0.2.10 fe80::1 198.51.100.7 \n'
MOCK
cat >"$fixture/bin/uapi" <<'MOCK'
#!/usr/bin/env bash
[ -f "$FIXTURE/vhost-ip" ] || exit 1
printf -- '---\nresult:\n  data:\n    ip: %s\n    ipv6: ~\n' "$(cat "$FIXTURE/vhost-ip")"
MOCK
cat >"$fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
    case $1 in
        https://*) printf '%s\n' "$1" >>"$FIXTURE/urls" ;;
        --output) output=$2; shift ;;
        --resolve) resolve=$2; printf '%s\n' "$2" >>"$FIXTURE/resolves"; shift ;;
        --insecure) touch "$FIXTURE/insecure" ;;
        --noproxy) [ "$2" = '*' ] && touch "$FIXTURE/noproxy"; shift ;;
    esac
    shift
done
case $resolve in
    *:192.0.2.10) printf '000|'; exit 7 ;;
    *:203.0.113.5) printf 'Application up, then the transfer stalled' >"$output"; printf '200|text/html'; exit 28 ;;
    *:203.0.113.9) printf 'default vhost' >"$output"; printf '200|text/html' ;;
    *:203.0.113.21) printf '8.5|1024M|litespeed' >"$output"; printf '200|text/plain' ;;
    *:203.0.113.22) printf '8.4|128M|litespeed' >"$output"; printf '200|text/plain' ;;
    *:203.0.113.20) printf 'Application up' >"$output"; printf '200|text/html' ;;
    *:203.0.113.30) sleep 2; printf '000|'; exit 28 ;;
    *:198.51.100.7) printf 'line one\nline two' >"$output"; printf '200|text/plain' ;;
    *) printf 'loopback' >"$output"; printf '200|text/plain' ;;
esac
MOCK
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"

fail() { echo "FAIL - $1"; exit 1; }

out=$(bash "$here/origin-fetch.sh" site.example.test /up 5)
[ "$(tail -n1 <<<"$out")" = 'ORIGIN-META 200|text/plain' ] || fail 'the final line carries status and type'
[ "$(sed '$d' <<<"$out")" = $'line one\nline two' ] || fail 'the body precedes the metadata line intact'
[ "$(cat "$fixture/resolves")" = $'site.example.test:443:192.0.2.10\nsite.example.test:443:198.51.100.7' ] \
    || fail 'own IPv4 addresses are tried in order and the first answer wins'
[ -f "$fixture/insecure" ] || fail 'the host talking to itself does not verify TLS'
[ -f "$fixture/noproxy" ] || fail 'no configured proxy is used for the origin request'
echo 'ok - the first own address that answers is used, IPv6 skipped'

# A 2xx header followed by a timeout is no answer: the next address is tried instead.
: >"$fixture/resolves"
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -I ] && printf '203.0.113.5 198.51.100.7\n'
MOCK
out=$(bash "$here/origin-fetch.sh" site.example.test /up 5)
if [ "$(tail -n1 <<<"$out")" != 'ORIGIN-META 200|text/plain' ] || [ "$(sed '$d' <<<"$out")" != $'line one\nline two' ]; then
    fail 'a transfer curl reports as failed is not accepted on its status'
fi
echo 'ok - a 2xx header followed by a failed transfer is no answer'

# On a multi-IP host another address can serve a different vhost: cPanel's own binding for the
# site is tried first, and an answer lacking the expected text moves on to the next address.
: >"$fixture/resolves"
printf '203.0.113.20' >"$fixture/vhost-ip"
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -I ] && printf '203.0.113.9 203.0.113.20\n'
MOCK
out=$(bash "$here/origin-fetch.sh" site.example.test /up 5 'Application up')
[ "$(head -n1 "$fixture/resolves")" = site.example.test:443:203.0.113.20 ] || fail "cPanel's vhost address is tried first"
[ "$(sed '$d' <<<"$out")" = 'Application up' ] || fail 'the vhost address answers'
rm -f "$fixture/vhost-ip"; : >"$fixture/resolves"
out=$(bash "$here/origin-fetch.sh" site.example.test /up 5 'Application up')
[ "$(cat "$fixture/resolves")" = $'site.example.test:443:203.0.113.9\nsite.example.test:443:203.0.113.20' ] \
    || fail 'an answer without the expected text moves on to the next address'
[ "$(sed '$d' <<<"$out")" = 'Application up' ] || fail 'the address with the expected text wins'
out=$(bash "$here/origin-fetch.sh" site.example.test /up 5 'never present')
[ "$(tail -n1 <<<"$out")" = 'ORIGIN-META 200|text/plain' ] || fail 'with no match, the last answer is reported'
echo 'ok - the vhost binding comes first and a wrong vhost is skipped'

# The time limit covers the whole call: once an address has used it up, no other is tried.
: >"$fixture/resolves"
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -I ] && printf '203.0.113.30 203.0.113.20\n'
MOCK
out=$(bash "$here/origin-fetch.sh" site.example.test /up 2 'Application up')
[ "$(cat "$fixture/resolves")" = site.example.test:443:203.0.113.30 ] || fail 'no address is tried after the time limit is spent'
[ "$(tail -n1 <<<"$out")" = 'ORIGIN-META 000|' ] || fail 'a spent time limit reports no answer'
echo 'ok - one time limit covers every address'

# An explicit port in the site URL travels to --resolve and the URL.
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
: >"$fixture/resolves"
bash "$here/origin-fetch.sh" site.example.test:8443 /up 5 >/dev/null
[ "$(cat "$fixture/resolves")" = site.example.test:8443:127.0.0.1 ] || fail 'an explicit port is resolved on that port'
echo 'ok - an explicit port is kept'
printf '203.0.113.20' >"$fixture/vhost-ip"
: >"$fixture/resolves"
bash "$here/origin-fetch.sh" site.example.test '/up?token=abc&x=1' 5 >/dev/null || fail 'a query string in the path is accepted'
[[ $(cat "$fixture/resolves") == site.example.test:443:203.0.113.20 ]] || fail 'query uses only the domain binding'
echo 'ok - a query string is kept only on the trusted cPanel binding'
# Even a wrong response on that binding must not disclose the query to fallback
# vhosts; with no trusted binding, do not send any HTTP request at all.
printf '203.0.113.9' >"$fixture/vhost-ip"
: >"$fixture/resolves"; : >"$fixture/urls"
bash "$here/origin-fetch.sh" site.example.test '/up?token=SECRET_QUERY' 5 'Application up' >/dev/null
[[ $(wc -l <"$fixture/resolves") == 1 && $(cat "$fixture/resolves") == site.example.test:443:203.0.113.9 ]] || fail 'query must never fallback after an unacceptable bound response'
rm "$fixture/vhost-ip"
: >"$fixture/resolves"; : >"$fixture/urls"
out=$(bash "$here/origin-fetch.sh" site.example.test '/up?token=SECRET_QUERY' 5 'Application up')
[[ ! -s $fixture/resolves && ! -s $fixture/urls && $(tail -n1 <<<"$out") == 'ORIGIN-META 000|' ]] || fail 'query without trusted binding must not disclose credentials'
echo 'ok - credential query never reaches unrelated host addresses or loopback'

for bad in 'bad host!' 'site.example.test'; do
    path=/up
    if [ "$bad" = site.example.test ]; then
        # A literal command substitution is the hostile path under test.
        # shellcheck disable=SC2016
        path='/up?x=$(id)'
    fi
    if bash "$here/origin-fetch.sh" "$bad" "$path" 5 >/dev/null 2>&1; then fail "rejects '$bad' '$path'"; fi
done
if bash "$here/origin-fetch.sh" site.example.test /up 0 >/dev/null 2>&1; then fail 'rejects a zero time limit'; fi
echo 'ok - invalid host, path and time limit are refused'

# PHP mode skips complete HTML from the wrong vhost, while preserving a valid
# wrong runtime so the runner can report a definitive failure rather than hide it.
for runtime_address in 203.0.113.21 203.0.113.22; do
    printf '#!/usr/bin/env bash\nprintf "203.0.113.9 %s\\n"\n' "$runtime_address" >"$fixture/bin/hostname"
    : >"$fixture/resolves"
    out=$(bash "$here/origin-fetch.sh" site.example.test /probe.php 5 '' php-runtime)
    [[ $(wc -l <"$fixture/resolves") == 2 ]] || fail 'PHP mode must try the later runtime address'
    expected='8.5|1024M|litespeed'
    [[ $runtime_address != 203.0.113.22 ]] || expected='8.4|128M|litespeed'
    [[ $(sed '$d' <<<"$out") == "$expected" ]] || fail 'complete runtime returned without filtering requirements'
done
echo 'ok - PHP mode skips wrong-vhost HTML and retains well-formed wrong runtime'

# The deadline starts before local discovery. No network fetch starts after a
# hung cPanel API or hostname command consumes the one-second budget.
for discovery in uapi hostname; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/uapi"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/hostname"
    printf '#!/usr/bin/env bash\nsleep 30\n' >"$fixture/bin/$discovery"
    : >"$fixture/resolves"
    started=$SECONDS
    out=$(bash "$here/origin-fetch.sh" site.example.test /up 1 2>"$fixture/discovery-error")
    (( SECONDS - started < 4 )) || fail "$discovery discovery exceeded its deadline"
    [[ ! -s $fixture/resolves && $(tail -n1 <<<"$out") == 'ORIGIN-META 000|' ]] || fail 'expired discovery must not fetch'
done
echo 'ok - stalled cPanel and hostname discovery share the whole call deadline'

# Filesystem/quota failures must not claim a response was retained or emitted.
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/uapi"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/hostname"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fixture/bin/cp"
chmod +x "$fixture/bin/cp"
if bash "$here/origin-fetch.sh" site.example.test /up 5 >"$fixture/copy-failure" 2>/dev/null; then fail 'failed response copy must fail'; fi
if grep -Fq ORIGIN-META "$fixture/copy-failure"; then fail 'failed copy claimed response metadata'; fi
rm "$fixture/bin/cp"
printf '#!/usr/bin/env bash\nprintf PRIVATE_READ_FAILURE\nexit 1\n' >"$fixture/bin/cat"
chmod +x "$fixture/bin/cat"
if bash "$here/origin-fetch.sh" site.example.test /up 5 >"$fixture/read-failure" 2>/dev/null; then fail 'failed response read must fail'; fi
if grep -Fq ORIGIN-META "$fixture/read-failure"; then fail 'failed read claimed response metadata'; fi
rm "$fixture/bin/cat"
echo 'ok - failed response copy or final read never appends a success record'

ORIGIN_REAL_CURL="$actual_curl" python3 "$here/test-origin-response-limits.py"
