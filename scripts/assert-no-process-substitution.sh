#!/usr/bin/env bash
# Runner-side portability contract for scripts executed inside cPanel/CageFS.
# ShellCheck's parser distinguishes substitutions from arithmetic, quoted data,
# comments and ordinary redirects; SC3001 identifies both input and output forms.
set -euo pipefail

delimiter=''
if [ "${1:-}" = --heredoc ]; then
    [ "$#" -ge 3 ] || exit 2
    delimiter=$2
    [[ $delimiter =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 2
    shift 2
fi
if [ "$#" -eq 0 ]; then
    echo "usage: assert-no-process-substitution.sh [--heredoc <delimiter>] <script> [...]" >&2
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

    input=$script
    if [ -n "$delimiter" ]; then
        # The listed runner helpers send named shell heredocs to `ssh bash -s`.
        # Parse every body separately; the outer shell sees these as quoted data.
        # A renamed, absent or unterminated delimiter fails the explicit contract.
        if ! awk -v delimiter="$delimiter" -v directory="$scratch" '
            BEGIN { quoted="<<\047" delimiter "\047"; doubleQuoted="<<\042" delimiter "\042" }
            active && $0 == delimiter { close(output); active=0; next }
            active { print > output; next }
            index($0,quoted) || index($0,doubleQuoted) {
                count++; output=directory "/heredoc-" count ".sh"; active=1
            }
            END { if (!count || active) exit 1; print count }
        ' "$script" >"$scratch/count"; then
            echo "Cannot verify named remote heredocs: $script" >&2
            status=1
            continue
        fi
        count=$(cat "$scratch/count")
        for ((index=1; index<=count; index++)); do
            if ! bash "$0" "$scratch/heredoc-$index.sh"; then status=1; fi
        done
        continue
    fi
    # Ignore annotations and user/runner configuration: a future suppression of
    # SC3001 must not disable this host-portability contract. Preserve line numbers.
    sed '/^[[:space:]]*#[[:space:]]*shellcheck\([[:space:]]\|$\)/s/.*//' "$input" >"$scratch/input.sh"
    if ! SHELLCHECK_OPTS='' shellcheck --norc --shell=sh --include=SC3001 \
        --format=gcc "$scratch/input.sh" >"$scratch/diagnostics" 2>&1; then
        echo "Remote script requires process substitution or could not be parsed: $script" >&2
        cat "$scratch/diagnostics" >&2
        status=1
    fi
done
exit "$status"
