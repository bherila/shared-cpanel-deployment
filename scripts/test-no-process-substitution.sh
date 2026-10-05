#!/usr/bin/env bash
# Parse fixtures without executing their shell code or requiring /dev/fd.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

check() {
    local name=$1
    shift
    if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails + 1)); fi
}

accepts() {
    printf '#!/usr/bin/env bash\n%s\n' "$1" >"$scratch/fixture.sh"
    bash "$here/assert-no-process-substitution.sh" "$scratch/fixture.sh" >"$scratch/result" 2>&1
}

rejects() {
    ! accepts "$1" && grep -q '\[SC3001\]' "$scratch/result"
}

if [ "${1:-}" = --environment-fixture ]; then
    rejects 'cat <(printf input)'
    exit "$?"
fi

check "input argument substitution is rejected" rejects 'cmp expected <(printf actual)'
check "output argument substitution is rejected" rejects 'tee >(cat > output)'
check "read-loop input substitution is rejected" rejects 'while IFS= read -r row; do printf "%s\n" "$row"; done < <(printf row)'
check "adjacent input redirect is rejected" rejects 'cat < <(printf input)'
check "output redirect substitution is rejected" rejects 'printf output > >(cat)'
check "substitution inside command substitution is rejected" rejects 'result=$(cat <(printf input))'
check "input/output substitutions inside functions are rejected" rejects 'work() { diff <(printf left) <(printf right); tee >(cat); }'
check "ShellCheck disable directives cannot suppress the contract" rejects $'# shellcheck disable=SC3001\ncat <(printf input)'
check "ShellCheck shell directives cannot change the contract dialect" rejects $'# shellcheck shell=bash\ncat <(printf input)'
check "ShellCheck environment exclusions cannot suppress the contract" env SHELLCHECK_OPTS='--exclude=SC3001' \
    bash "$0" --environment-fixture 2>/dev/null

check "ordinary comparisons and redirects remain accepted" accepts $'[[ a < b && b > a ]]\ncat < input > output\nprintf data >> output\ncat <<< data\nexec 3<input 4>output\ncat <&3 >&4'
check "compact arithmetic comparisons remain accepted" accepts '(( a<(b) && b>(a) ))'
check "quoted substitution-shaped data and comments remain accepted" accepts $'printf "%s\n" "<(input)" ">(output)"\n# cat <(input) >(output)'
check "invalid shell syntax fails closed" bash -c \
    'printf "%s\n" "cat <(" >"$2"; ! bash "$1" "$2" >/dev/null 2>&1' sh \
    "$here/assert-no-process-substitution.sh" "$scratch/invalid.sh"
check "missing scripts fail closed" bash -c '! bash "$1" "$2" >/dev/null 2>&1' sh \
    "$here/assert-no-process-substitution.sh" "$scratch/missing.sh"

# Invoked indirectly through check inside the helper loop.
# shellcheck disable=SC2317,SC2329
remote_rejects() {
    local helper=$1 injection=$2
    # Mutate the actual SSH payload, without running any upload or SSH command.
    awk -v injection="$injection" '
        { print }
        index($0, "<<\047REMOTE\047") { print injection }
    ' "$here/$helper" >"$scratch/remote-fixture.sh"
    ! bash "$here/assert-no-process-substitution.sh" --heredoc REMOTE "$scratch/remote-fixture.sh" \
        >"$scratch/result" 2>&1 && grep -q '\[SC3001\]' "$scratch/result"
}
for helper in rsync-deploy.sh rsync-migrations.sh rsync-atomic-release.sh; do
    check "$helper remote input argument substitution is rejected" remote_rejects "$helper" 'cat <(printf input)'
    check "$helper remote output argument substitution is rejected" remote_rejects "$helper" 'tee >(cat)'
    check "$helper remote read-loop substitution is rejected" remote_rejects "$helper" \
        'while read -r row; do printf "%s" "$row"; done < <(printf input)'
done
cat >"$scratch/multiple.sh" <<'FIXTURE'
#!/usr/bin/env bash
runner=<(printf local)
ssh host 'bash -s' <<'REMOTE'
printf '<(quoted data)'
REMOTE
ssh host 'bash -s' <<'REMOTE'
tee >(cat)
REMOTE
FIXTURE
check "every remote heredoc is inspected" bash -c \
    '! bash "$1" --heredoc REMOTE "$2" >"$3" 2>&1 && grep -q "\[SC3001\]" "$3"' sh \
    "$here/assert-no-process-substitution.sh" "$scratch/multiple.sh" "$scratch/multiple-result"
sed 's/tee >(cat)/cat < input > output/' "$scratch/multiple.sh" >"$scratch/allowed-heredocs.sh"
check "runner substitutions and quoted remote data remain accepted" bash \
    "$here/assert-no-process-substitution.sh" --heredoc REMOTE "$scratch/allowed-heredocs.sh"
check "a missing named remote heredoc fails closed" bash -c \
    '! bash "$1" --heredoc DIFFERENT "$2" >/dev/null 2>&1' sh \
    "$here/assert-no-process-substitution.sh" "$scratch/allowed-heredocs.sh"

echo "failures: $fails"
exit "$fails"
