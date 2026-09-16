#!/usr/bin/env bash
# Fixture shell expressions intentionally remain literal until the fake SSH runs.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"

# Fake only the SSH transport: execute the streamed hook with the actual quoted
# remote command so argument integrity and remote failure propagation are tested.
printf '%s\n' '#!/usr/bin/env bash' 'test "$1" = fixture-target' \
    'exec bash -c "$2"' >"$fixture/bin/ssh"
chmod +x "$fixture/bin/ssh"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'test "$#" -eq 3' \
    'test "$1" = "$EXPECTED_CANDIDATE"' \
    'test "$2" = "$EXPECTED_PHP"' \
    'test "$3" = "$EXPECTED_STABLE"' \
    'exit "${HOOK_STATUS:-0}"' >"$fixture/hook.sh"

export PATH="$fixture/bin:$PATH" TARGET=fixture-target
export EXPECTED_CANDIDATE='.deployments/app/releases/candidate with spaces;$(false)'
export EXPECTED_PHP='/path with spaces/php' EXPECTED_STABLE='app;$(false)'
export CANDIDATE_DIR="$EXPECTED_CANDIDATE" PHP_BINARY="$EXPECTED_PHP" STABLE_DIR="$EXPECTED_STABLE"
export SCRIPT="$fixture/hook.sh"

bash "$here/run-preflight-hook.sh"
if HOOK_STATUS=23 bash "$here/run-preflight-hook.sh"; then
    echo 'FAIL: a failing preflight hook was accepted.' >&2
    exit 1
else
    test "$?" -eq 23
fi
if SCRIPT="$fixture/missing.sh" bash "$here/run-preflight-hook.sh" >"$fixture/output" 2>&1; then
    echo 'FAIL: a missing preflight hook was accepted.' >&2
    exit 1
else
    test "$?" -eq 2
fi
echo 'Preflight hook dispatch tests passed.'
