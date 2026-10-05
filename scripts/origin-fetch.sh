#!/usr/bin/env bash
#
# Fetch one path of a site from its own web server, bypassing any proxy or CDN in front of it.
#
# Runs ON THE HOST, piped over SSH:
#
#   ssh <target> "bash -s -- <host[:port]> <path> <max-seconds> [expected-text] [response-kind]" <origin-fetch.sh
#
# Deploy checks used to fetch through the public URL from the runner. A zone rule that challenges
# visitors by country (Cloudflare "I'm Under Attack" for non-US traffic) answered those requests
# itself, with an HTML 200, whenever the runner happened to be outside that country: the PHP probe
# then failed and a health check passed without reaching the application. Asking the host's own
# web server for the same name tests the vhost, its handler and the application directly, wherever
# the runner is.
#
# Candidate addresses, in order: the one cPanel binds this vhost to (uapi DomainInfo), the host's
# other IPv4 addresses, then loopback. Query paths use only the domain binding
# to keep authentication parameters away from other accounts' default vhosts. On a multi-IP host a different address can serve another
# vhost, so an address is accepted only for a complete 2xx response that contains
# [expected-text] when one is given. The php-runtime response kind additionally requires
# one complete runtime record, without filtering the desired version or memory; otherwise
# the next address is tried. When none is accepted, the last
# answer that did arrive is reported, so the caller can say what it got. TLS is not verified: this
# is the host talking to itself, and an origin certificate may be self-signed or issued for the
# proxy's use only.
#
# Prints the response body, then one final line `ORIGIN-META <status>|<content-type>`. The status
# is 000 when no complete bounded response was received. Exits 0 whenever it printed that line.
set -uo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    echo "usage: origin-fetch.sh <host[:port]> <path> <max-seconds> [expected-text] [response-kind]" >&2
    exit 2
fi

authority=$1
path=$2
limit=$3
expect=${4:-}
response_kind=${5:-any}
[[ $response_kind == any || $response_kind == php-runtime ]] || exit 2

[[ $authority =~ ^([A-Za-z0-9.-]+)(:([0-9]{1,5}))?$ ]] || { echo "origin-fetch: invalid host" >&2; exit 2; }
host=${BASH_REMATCH[1]}
port=${BASH_REMATCH[3]:-443}
# Path and optional query, in URL characters only (no quotes, spaces or shell syntax): a health
# path such as /up?token=abc worked when it was part of the runner's URL and still must.
[[ $path =~ ^/[A-Za-z0-9._~/%-]*(\?[A-Za-z0-9._~/%=\&+-]*)?$ ]] || { echo "origin-fetch: invalid path" >&2; exit 2; }
if ! [[ $limit =~ ^[0-9]+$ ]] || [ "$limit" -eq 0 ]; then
    echo "origin-fetch: invalid time limit" >&2
    exit 2
fi

timeout_binary=$(command -v timeout) || exit 2
[[ $timeout_binary == /* && -x $timeout_binary ]] || exit 2
# Discovery and requests share this deadline; a stalled local API must not extend it.
deadline=$(( SECONDS + limit ))

body=$(mktemp)
kept=$(mktemp)
metadata=$(mktemp)
trap 'rm -f "$body" "$kept" "$metadata"' EXIT
response_limit=262144

addresses=()
add_address() {
    local candidate=$1 existing
    [[ $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    for existing in ${addresses[@]+"${addresses[@]}"}; do [ "$existing" != "$candidate" ] || return 0; done
    addresses+=("$candidate")
}
if command -v uapi >/dev/null 2>&1; then
    remaining=$(( deadline - SECONDS ))
    vhost_ip=''
    if (( remaining > 0 )); then
        vhost_ip=$("$timeout_binary" --signal=KILL "${remaining}s" uapi DomainInfo single_domain_data domain="$host" 2>/dev/null | sed -n 's/^ *ip: *//p' | head -n1)
    fi
    add_address "${vhost_ip:-}"
fi
# A query may carry credentials. Send it only to the domain's trusted cPanel
# binding, never to another account's IP-bound default vhost or to loopback.
remaining=$(( deadline - SECONDS ))
if [[ $path != *\?* ]] && (( remaining > 0 )); then
    for address in $("$timeout_binary" --signal=KILL "${remaining}s" hostname -I 2>/dev/null); do add_address "$address"; done
    add_address 127.0.0.1
fi

meta='000|'
kept_meta='000|'
# <max-seconds> bounds the whole call, not each address: several addresses that accept and then
# stall must not multiply it.
for address in "${addresses[@]}"; do
    remaining=$(( deadline - SECONDS ))
    [ "$remaining" -gt 0 ] || break
    : >"$body"
    # A transfer curl reports as failed (timed out or cut off after a 2xx header) is no answer,
    # whatever status --write-out printed: a partial body must never pass a check.
    # --noproxy: an account-level HTTPS_PROXY or ALL_PROXY would carry the request back through the
    # public name, and through the CDN this exists to bypass.
    # max-filesize handles known lengths; RLIMIT_FSIZE also caps streaming
    # bodies on older curl versions that do not enforce unknown-length limits.
    # Metadata is file-backed and checked before any shell buffering.
    if (ulimit -f 256; curl --silent --insecure --noproxy '*' --max-time "$remaining" \
        --max-filesize "$response_limit" --resolve "$host:$port:$address" \
        --header 'Cache-Control: no-cache' \
        --output "$body" --write-out '%{http_code}|%{content_type}' \
        "https://$authority$path") >"$metadata" 2>/dev/null \
        && [[ $(wc -c <"$body") -le $response_limit && $(wc -c <"$metadata") -le 500 ]] \
        && LC_ALL=C awk 'NR != 1 || $0 !~ /^[0-9][0-9][0-9]\|[[:print:]]*$/ { invalid=1 }
            END { if (NR != 1 || invalid) exit 1 }' "$metadata"; then
        meta=$(<"$metadata")
    else
        meta='000|'
    fi
    [ "${meta%%|*}" != 000 ] || continue
    # Match the response shape, never the desired version or memory minimum:
    # a well-formed wrong runtime must reach the caller's definitive classification.
    runtime_valid=true
    if [[ $response_kind == php-runtime ]]; then
        [[ $(wc -c <"$body") -le 512 ]] && LC_ALL=C awk '
            NR != 1 || $0 !~ /^[0-9]+\.[0-9]+\|(-1|[0-9]+[KkMmGg]?)\|[A-Za-z0-9_-]+$/ { invalid=1 }
            END { if (NR != 1 || invalid) exit 1 }
        ' "$body" || runtime_valid=false
    fi
    if [[ ${meta%%|*} =~ ^2[0-9][0-9]$ && $runtime_valid == true ]] && { [ -z "$expect" ] || grep -Fq -- "$expect" "$body"; }; then
        cp "$body" "$kept" || exit 1
        kept_meta=$meta
        break
    fi
    cp "$body" "$kept" || exit 1
    kept_meta=$meta
done

cat "$kept" || exit 1
printf '\nORIGIN-META %s\n' "$kept_meta"
