#!/usr/bin/env bash
# Runner-side validation; no PHP is executed. Host audits independently enforce
# the same signed 64-bit byte ceiling before starting their PHP process.
set -euo pipefail
[[ $# -eq 2 ]] || exit 2
value=$1 allow_unlimited=$2
[[ $allow_unlimited = true || $allow_unlimited = false ]] || exit 2
if [[ -z $value || ( $value = -1 && $allow_unlimited = true ) ]]; then exit 0; fi
if [[ ! $value =~ ^([1-9][0-9]*)([KMGkmg])$ ]]; then
    echo '::error::artisan-memory-limit must be empty or a positive finite K/M/G value; -1 is allowed only with audits disabled.' >&2
    exit 2
fi
digits=${BASH_REMATCH[1]}
case ${BASH_REMATCH[2]} in
    [Kk]) maximum=9007199254740991 ;;
    [Mm]) maximum=8796093022207 ;;
    [Gg]) maximum=8589934591 ;;
esac
LC_ALL=C
# Compare decimal strings before any arithmetic; multiplying first can wrap a
# syntactically positive PHP setting into zero or an effectively unlimited size.
# shellcheck disable=SC2071
if [[ ${#digits} -gt ${#maximum} || ( ${#digits} -eq ${#maximum} && $digits > $maximum ) ]]; then
    echo '::error::artisan-memory-limit exceeds the signed 64-bit byte ceiling.' >&2
    exit 2
fi
