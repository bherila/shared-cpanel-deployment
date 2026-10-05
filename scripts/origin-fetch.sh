#!/usr/bin/env bash
#
# Fetch one path of a site from its own web server, bypassing any proxy or CDN in front of it.
#
# Runs ON THE HOST, piped over SSH:
#
#   ssh <target> "bash -s -- <host> <path> <max-seconds>" <origin-fetch.sh
#
# Deploy checks used to fetch through the public URL from the runner. A zone rule that challenges
# visitors by country (Cloudflare "I'm Under Attack" for non-US traffic) answered those requests
# itself, with an HTML 200, whenever the runner happened to be outside that country: the PHP probe
# then failed and a health check passed without reaching the application. Asking the host's own
# web server for the same name tests the vhost, its handler and the application directly, wherever
# the runner is.
#
# Each of the host's own addresses is tried with `--resolve`, then the loopback address, and the
# first that answers at all is used. TLS is not verified: this is the host talking to itself, and
# an origin certificate may be self-signed or issued for the proxy's use only.
#
# Prints the response body, then one final line `ORIGIN-META <status>|<content-type>`. The status
# is 000 when no address answered. Exits 0 whenever it printed that line.
set -uo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: origin-fetch.sh <host> <path> <max-seconds>" >&2
    exit 2
fi

host=$1
path=$2
limit=$3

[[ $host =~ ^[A-Za-z0-9.-]+$ ]] || { echo "origin-fetch: invalid host" >&2; exit 2; }
[[ $path =~ ^/[A-Za-z0-9._~/%-]*$ ]] || { echo "origin-fetch: invalid path" >&2; exit 2; }
if ! [[ $limit =~ ^[0-9]+$ ]] || [ "$limit" -eq 0 ]; then
    echo "origin-fetch: invalid time limit" >&2
    exit 2
fi

body=$(mktemp)
trap 'rm -f "$body"' EXIT

addresses=()
for address in $(hostname -I 2>/dev/null); do
    [[ $address =~ ^[0-9.]+$ ]] && addresses+=("$address")
done
addresses+=(127.0.0.1)

meta='000|'
for address in "${addresses[@]}"; do
    : >"$body"
    # A transfer curl reports as failed (timed out or cut off after a 2xx header) is no answer,
    # whatever status --write-out printed: a partial body must never pass a check.
    if ! meta=$(curl --silent --insecure --max-time "$limit" \
        --resolve "$host:443:$address" \
        --header 'Cache-Control: no-cache' \
        --output "$body" --write-out '%{http_code}|%{content_type}' \
        "https://$host$path" 2>/dev/null); then
        meta='000|'
    fi
    [ "${meta%%|*}" = 000 ] || break
done

cat "$body"
printf '\nORIGIN-META %s\n' "$meta"
