#!/usr/bin/env bash
#
# Fetch one path of a site from its own web server, bypassing any proxy or CDN in front of it.
#
# Runs ON THE HOST, piped over SSH:
#
#   ssh <target> "bash -s -- <host[:port]> <path> <max-seconds> [expected-text]" <origin-fetch.sh
#
# Deploy checks used to fetch through the public URL from the runner. A zone rule that challenges
# visitors by country (Cloudflare "I'm Under Attack" for non-US traffic) answered those requests
# itself, with an HTML 200, whenever the runner happened to be outside that country: the PHP probe
# then failed and a health check passed without reaching the application. Asking the host's own
# web server for the same name tests the vhost, its handler and the application directly, wherever
# the runner is.
#
# Candidate addresses, in order: the one cPanel binds this vhost to (uapi DomainInfo), the host's
# other IPv4 addresses, then loopback. On a multi-IP host a different address can serve another
# vhost, so an address is accepted only for a complete 2xx response that contains
# [expected-text] when one is given; otherwise the next is tried. When none is accepted, the last
# answer that did arrive is reported, so the caller can say what it got. TLS is not verified: this
# is the host talking to itself, and an origin certificate may be self-signed or issued for the
# proxy's use only.
#
# Prints the response body, then one final line `ORIGIN-META <status>|<content-type>`. The status
# is 000 when no address answered. Exits 0 whenever it printed that line.
set -uo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: origin-fetch.sh <host[:port]> <path> <max-seconds> [expected-text]" >&2
    exit 2
fi

authority=$1
path=$2
limit=$3
expect=${4:-}

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

body=$(mktemp)
kept=$(mktemp)
trap 'rm -f "$body" "$kept"' EXIT

addresses=()
add_address() {
    local candidate=$1 existing
    [[ $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    for existing in ${addresses[@]+"${addresses[@]}"}; do [ "$existing" != "$candidate" ] || return 0; done
    addresses+=("$candidate")
}
if command -v uapi >/dev/null 2>&1; then
    vhost_ip=$(uapi DomainInfo single_domain_data domain="$host" 2>/dev/null | sed -n 's/^ *ip: *//p' | head -n1)
    add_address "${vhost_ip:-}"
fi
for address in $(hostname -I 2>/dev/null); do add_address "$address"; done
add_address 127.0.0.1

meta='000|'
kept_meta='000|'
# <max-seconds> bounds the whole call, not each address: several addresses that accept and then
# stall must not multiply it.
deadline=$(( SECONDS + limit ))
for address in "${addresses[@]}"; do
    remaining=$(( deadline - SECONDS ))
    [ "$remaining" -gt 0 ] || break
    : >"$body"
    # A transfer curl reports as failed (timed out or cut off after a 2xx header) is no answer,
    # whatever status --write-out printed: a partial body must never pass a check.
    if ! meta=$(curl --silent --insecure --max-time "$remaining" \
        --resolve "$host:$port:$address" \
        --header 'Cache-Control: no-cache' \
        --output "$body" --write-out '%{http_code}|%{content_type}' \
        "https://$authority$path" 2>/dev/null); then
        meta='000|'
    fi
    [ "${meta%%|*}" != 000 ] || continue
    if [[ ${meta%%|*} =~ ^2[0-9][0-9]$ ]] && { [ -z "$expect" ] || grep -Fq -- "$expect" "$body"; }; then
        cp "$body" "$kept"
        kept_meta=$meta
        break
    fi
    cp "$body" "$kept"
    kept_meta=$meta
done

cat "$kept"
printf '\nORIGIN-META %s\n' "$kept_meta"
