#!/usr/bin/env bash
# Exercise origin-fetch.sh: own-address fallback, output framing and input validation.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export FIXTURE="$fixture"
mkdir "$fixture/bin"
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -I ] && printf '192.0.2.10 fe80::1 198.51.100.7 \n'
MOCK
cat >"$fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
    case $1 in
        --output) output=$2; shift ;;
        --resolve) resolve=$2; printf '%s\n' "$2" >>"$FIXTURE/resolves"; shift ;;
        --insecure) touch "$FIXTURE/insecure" ;;
    esac
    shift
done
case $resolve in
    *:192.0.2.10) printf '000|'; exit 7 ;;
    *:203.0.113.5) printf 'Application up, then the transfer stalled' >"$output"; printf '200|text/html'; exit 28 ;;
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
echo 'ok - the first own address that answers is used, IPv6 skipped'

# A 2xx header followed by a timeout is no answer: the next address is tried instead.
: >"$fixture/resolves"
cat >"$fixture/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -I ] && printf '203.0.113.5 198.51.100.7\n'
MOCK
out=$(bash "$here/origin-fetch.sh" site.example.test /up 5)
[ "$(tail -n1 <<<"$out")" = 'ORIGIN-META 200|text/plain' ] && [ "$(sed '$d' <<<"$out")" = $'line one\nline two' ] \
    || fail 'a transfer curl reports as failed is not accepted on its status'
echo 'ok - a 2xx header followed by a failed transfer is no answer'

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
