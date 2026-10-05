#!/usr/bin/env bash
# Runner-side portability contract for scripts executed inside cPanel/CageFS.
# ShellCheck's parser distinguishes substitutions from arithmetic, quoted data,
# comments and ordinary redirects; SC3001 identifies both input and output forms.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: assert-no-process-substitution.sh <remote-script> [...]" >&2
    exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
status=0
for script in "$@"; do
    if [ ! -f "$script" ] || [ ! -r "$script" ] || ! bash -n "$script"; then
        echo "Cannot verify remote shell syntax: $script" >&2
        status=1
        continue
    fi

    # Ignore annotations and user/runner configuration: a future suppression of
    # SC3001 must not disable this host-portability contract. Preserve line numbers.
    sed '/^[[:space:]]*#[[:space:]]*shellcheck\([[:space:]]\|$\)/s/.*//' "$script" >"$scratch/input.sh"
    if ! SHELLCHECK_OPTS='' shellcheck --norc --shell=sh --include=SC3001 \
        --format=gcc "$scratch/input.sh" >"$scratch/diagnostics" 2>&1; then
        echo "Remote script requires process substitution or could not be parsed: $script" >&2
        cat "$scratch/diagnostics" >&2
        status=1
    fi
done
exit "$status"
