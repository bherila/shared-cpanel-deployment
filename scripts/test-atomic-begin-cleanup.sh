#!/usr/bin/env bash
# Fault every initial metadata write without ever bootstrapping an application.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
original_path=$PATH
real_mktemp=$(command -v mktemp)
real_mv=$(command -v mv)
commit=0123456789abcdef0123456789abcdef01234567
checks=0

setup() {
    fixture=$(mktemp -d "$scratch/case.XXXXXX")
    export HOME="$fixture/home" FIXTURE_ROOT="$fixture"
    mkdir -p "$HOME/app/storage" "$fixture/bin"
    touch "$HOME/app/artisan"
    printf 'release=prior\ncommit=%s\n' "$commit" >"$HOME/app/.deploy-release"
    printf 'patient data\n' >"$HOME/app/storage/preserved"
    printf 'foreign cron\n' >"$fixture/crontab"
    export PATH="$fixture/bin:$original_path"
    export REAL_MKTEMP="$real_mktemp" REAL_MV="$real_mv"
    cat >"$fixture/inject.sh" <<'SH'
inject_fault() {
    builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
    case ${REPLACE:-none} in
        lock)
            command mv "$HOME/.deployments/app/deploy.lock" "$FIXTURE_ROOT/original-lock"
            mkdir "$HOME/.deployments/app/deploy.lock"
            builtin printf 'replacement\n' >"$HOME/.deployments/app/deploy.lock/owner" ;;
        same-token)
            command mv "$HOME/.deployments/app/deploy.lock" "$FIXTURE_ROOT/original-lock"
            mkdir "$HOME/.deployments/app/deploy.lock"
            builtin printf 'failed\n' >"$HOME/.deployments/app/deploy.lock/owner" ;;
        owner) builtin printf 'replacement\n' >"$HOME/.deployments/app/deploy.lock/owner" ;;
        malformed) builtin printf 'failed\n\n' >"$HOME/.deployments/app/deploy.lock/owner" ;;
        missing) rm "$HOME/.deployments/app/deploy.lock/owner" ;;
        candidate)
            command mv "$HOME/.deployments/app/releases/failed" "$FIXTURE_ROOT/original-candidate"
            mkdir "$HOME/.deployments/app/releases/failed"
            touch "$HOME/.deployments/app/releases/failed/foreign" ;;
        transaction)
            command mv "$HOME/.deployments/app/state/failed" "$FIXTURE_ROOT/original-transaction"
            mkdir "$HOME/.deployments/app/state/failed"
            touch "$HOME/.deployments/app/state/failed/foreign" ;;
        control|releases|state)
            case $REPLACE in
                control) replaced="$HOME/.deployments/app" ;;
                *) replaced="$HOME/.deployments/app/$REPLACE" ;;
            esac
            command mv "$replaced" "$FIXTURE_ROOT/original-ancestor"
            mkdir "$replaced"
            touch "$replaced/foreign" ;;
    esac
    return 91
}
matches_field() {
    case $1 in
        "$HOME/.deployments/app/state/failed/$FAULT_FIELD"|"$HOME/.deployments/app/state/failed/.$FAULT_FIELD."*|"$HOME/.deployments/app/$FAULT_FIELD"|"$HOME/.deployments/app/.$FAULT_FIELD."*|"$HOME/.deployments/app/deploy.lock/$FAULT_FIELD") return 0 ;;
        *) return 1 ;;
    esac
}
printf() {
    local target
    target=$(readlink "/proc/$$/fd/1" || true)
    if [ "$FAULT_COMMAND" = printf ] && matches_field "$target"; then inject_fault; return 91; fi
    builtin printf "$@"
}
mktemp() {
    if [ "$FAULT_COMMAND" = persistent-mktemp ] && { matches_field "${!#}" || [ -f "$FIXTURE_ROOT/hit" ]; }; then inject_fault; return 91; fi
    if [ "$FAULT_COMMAND" = mktemp ] && matches_field "${!#}"; then inject_fault; return 91; fi
    "$REAL_MKTEMP" "$@"
}
chmod() {
    local target=${!#}
    if [ "$FAULT_COMMAND" = chmod ]; then
        case "$FAULT_FIELD:$target" in
            transaction:"$HOME/.deployments/app/state/failed"|candidate:"$HOME/.deployments/app/releases/failed") inject_fault; return 91 ;;
        esac
    fi
    command chmod "$@"
}
mkdir() {
    local target=${!#}
    if [ "$FAULT_COMMAND" = mkdir-after ]; then
        case "$FAULT_FIELD:$target" in
            transaction:"$HOME/.deployments/app/state/failed"|candidate:"$HOME/.deployments/app/releases/failed") command mkdir "$@"; inject_fault; return 91 ;;
        esac
    fi
    command mkdir "$@"
}
mv() {
    if [ "$FAULT_COMMAND" = cross-parent-quota ] && [ -f "$FIXTURE_ROOT/hit" ]; then
        # A metadata-exhausted control directory must never receive an entry
        # from releases/ or state/. Same-parent renames remain available.
        local source destination
        source=${@: -2:1}; destination=${!#}
        if [ "${source%/*}" != "${destination%/*}" ]; then return 91; fi
    fi
    if [ "$FAULT_COMMAND" = persistent-mv ] && { matches_field "${!#}" || [ -f "$FIXTURE_ROOT/hit" ]; }; then inject_fault; return 91; fi
    if { [ "$FAULT_COMMAND" = mv ] || [ "$FAULT_COMMAND" = cross-parent-quota ]; } && matches_field "${!#}"; then inject_fault; return 91; fi
    case ${REPLACE:-none} in
        detach-*|owner-before-*)
            boundary=${REPLACE#detach-}; boundary=${boundary#owner-before-}
            case ${!#} in
                */.begin-cleanup-*"-$boundary")
                    if [ ! -f "$FIXTURE_ROOT/detach-hit" ]; then
                        touch "$FIXTURE_ROOT/detach-hit"
                        if [[ $REPLACE == detach-* ]]; then
                            path="$HOME/.deployments/app/$boundary"
                            case $boundary in
                                candidate) path="$HOME/.deployments/app/releases/failed" ;;
                                transaction) path="$HOME/.deployments/app/state/failed" ;;
                                lock) path="$HOME/.deployments/app/deploy.lock" ;;
                            esac
                            command mv "$path" "$FIXTURE_ROOT/original-detached"
                            mkdir "$path"
                            touch "$path/foreign"
                            [ "$boundary" != lock ] || builtin printf 'replacement\n' >"$path/owner"
                        else
                            command mv "$HOME/.deployments/app/deploy.lock" "$FIXTURE_ROOT/original-lock"
                            mkdir "$HOME/.deployments/app/deploy.lock"
                            builtin printf 'replacement\n' >"$HOME/.deployments/app/deploy.lock/owner"
                        fi
                    fi ;;
            esac ;;
    esac
    "$REAL_MV" "$@"
}
SH
}

run_fault() {
    if BASH_ENV="$fixture/inject.sh" bash "$here/atomic-release.sh" begin app failed "$commit" 7200 3 maintenance "$commit" stable-directory storage >"$fixture/output" 2>&1; then
        echo "unexpected success: $FAULT_COMMAND $FAULT_FIELD ${REPLACE:-none}" >&2; exit 1
    fi
    test -f "$fixture/hit"
    test "$(cat "$HOME/app/storage/preserved")" = 'patient data'
    test "$(cat "$fixture/crontab")" = 'foreign cron'
    test "$(cat "$HOME/app/.deploy-release")" = "$(printf 'release=prior\ncommit=%s' "$commit")"
}

assert_reacquire() {
    test ! -e "$HOME/.deployments/app/deploy.lock"
    test ! -e "$HOME/.deployments/app/state/failed"
    test ! -e "$HOME/.deployments/app/releases/failed"
    bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null
    test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = retry
    checks=$((checks + 1))
}

fields=(commit retain failure_policy initial_live_commit layout risk_started recovery_required activated committed previous_was_maintenance phase previous_release previous_commit previous_target)
for command in mktemp printf mv; do
    for field in "${fields[@]}"; do
        setup
        export FAULT_COMMAND="$command" FAULT_FIELD="$field" REPLACE=none
        run_fault
        assert_reacquire
    done
done
for field in persistent-paths started requested-timeout; do
    setup
    export FAULT_COMMAND=printf FAULT_FIELD="$field" REPLACE=none
    run_fault
    assert_reacquire
done
# Generation publication and the legacy trusted-commit record also belong to
# initialization, including temporary contents and final renames.
for field in generation legacy-live-commit; do
    for command in mktemp printf mv; do
        setup
        [ "$field" != legacy-live-commit ] || rm "$HOME/app/.deploy-release"
        export FAULT_COMMAND="$command" FAULT_FIELD="$field" REPLACE=none
        if [ "$field" = legacy-live-commit ]; then
            # The app remains exactly legacy; run_fault's managed metadata check
            # is deliberately skipped, while runtime and cron remain untouched.
            if BASH_ENV="$fixture/inject.sh" bash "$here/atomic-release.sh" begin app failed "$commit" 7200 3 maintenance "$commit" stable-directory storage >"$fixture/output" 2>&1; then exit 1; fi
            test -f "$fixture/hit"
            test ! -e "$HOME/app/.deploy-release"
            test "$(cat "$HOME/app/storage/preserved")" = 'patient data'
            test "$(cat "$fixture/crontab")" = 'foreign cron'
        else run_fault; fi
        assert_reacquire
    done
done

for replacement in lock same-token owner malformed missing candidate transaction; do
    setup
    export FAULT_COMMAND=mv FAULT_FIELD=phase REPLACE="$replacement"
    run_fault
    test -d "$HOME/.deployments/app/deploy.lock"
    test -d "$HOME/.deployments/app/state/failed"
    test -d "$HOME/.deployments/app/releases/failed"
    case $replacement in
        lock|owner) test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = replacement ;;
        same-token) test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = failed ;;
        candidate) test -f "$HOME/.deployments/app/releases/failed/foreign" ;;
        transaction) test -f "$HOME/.deployments/app/state/failed/foreign" ;;
    esac
    if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
    checks=$((checks + 1))
done
setup
export FAULT_COMMAND=persistent-mktemp FAULT_FIELD=phase REPLACE=none
run_fault
assert_reacquire
setup
export FAULT_COMMAND=persistent-mv FAULT_FIELD=phase REPLACE=none
run_fault
test -d "$HOME/.deployments/app/deploy.lock"
test -d "$HOME/.deployments/app/state/failed"
test -d "$HOME/.deployments/app/releases/failed"
checks=$((checks + 1))

for field in transaction candidate; do
    setup
    export FAULT_COMMAND=mkdir-after FAULT_FIELD="$field" REPLACE=none
    run_fault
    test -d "$HOME/.deployments/app/deploy.lock"
    test -d "$HOME/.deployments/app/state/failed"
    if [ "$field" = candidate ]; then test -d "$HOME/.deployments/app/releases/failed"; fi
    if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
    checks=$((checks + 1))
    setup
    export FAULT_COMMAND=chmod FAULT_FIELD="$field" REPLACE=none
    run_fault
    assert_reacquire
done
setup
export FAULT_COMMAND=cross-parent-quota FAULT_FIELD=phase REPLACE=none
run_fault
assert_reacquire
for replacement in detach-candidate detach-transaction detach-lock owner-before-candidate owner-before-transaction owner-before-lock; do
    setup
    export FAULT_COMMAND=mv FAULT_FIELD=phase REPLACE="$replacement"
    run_fault
    test -f "$fixture/detach-hit"
    test -d "$HOME/.deployments/app/deploy.lock"
    if [[ $replacement == detach-* ]]; then
        test "$(find "$HOME/.deployments/app" -name foreign -type f | wc -l)" -eq 1
    fi
    case $replacement in
        detach-lock|owner-before-*) test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = replacement ;;
    esac
    if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
    checks=$((checks + 1))
done
for replacement in control releases state; do
    setup
    export FAULT_COMMAND=mv FAULT_FIELD=phase REPLACE="$replacement"
    run_fault
    case $replacement in
        control) test -f "$fixture/original-ancestor/deploy.lock/owner" ;;
        *) test -d "$fixture/original-ancestor/failed" ;;
    esac
    test -f "$HOME/.deployments/app/$(case $replacement in control) echo foreign ;; *) echo "$replacement/foreign" ;; esac)"
    [ "$replacement" = control ] || test -d "$HOME/.deployments/app/deploy.lock"
    checks=$((checks + 1))
done
# The first owner write can leave an empty owner record. An uncertain lock is
# retained rather than claiming an identity which was never durably recorded.
setup
export FAULT_COMMAND=printf FAULT_FIELD=owner REPLACE=none
run_fault
test -d "$HOME/.deployments/app/deploy.lock"
test ! -s "$HOME/.deployments/app/deploy.lock/owner"
checks=$((checks + 1))
for length in 235 255; do
    setup
    long_release=$(printf '%*s' "$length" '' | tr ' ' a)
    cat >"$fixture/long-inject.sh" <<'SH'
mktemp() {
    case ${!#} in
        */.phase.*) printf 'hit\n' >"$FIXTURE_ROOT/hit"; return 91 ;;
    esac
    "$REAL_MKTEMP" "$@"
}
SH
    if BASH_ENV="$fixture/long-inject.sh" bash "$here/atomic-release.sh" begin app "$long_release" "$commit" 7200 3 maintenance "$commit" stable-directory storage >"$fixture/output" 2>&1; then exit 1; fi
    test -f "$fixture/hit"
    test ! -e "$HOME/.deployments/app/deploy.lock"
    test ! -e "$HOME/.deployments/app/state/$long_release"
    test ! -e "$HOME/.deployments/app/releases/$long_release"
    test "$(cat "$HOME/app/storage/preserved")" = 'patient data'
    test "$(cat "$fixture/crontab")" = 'foreign cron'
    bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null
    checks=$((checks + 1))
done
setup
mkdir -p "$HOME/.deployments/app/state"
ln -s "$fixture/foreign-absent" "$HOME/.deployments/app/state/failed"
if bash "$here/atomic-release.sh" begin app failed "$commit" 7200 3 maintenance "$commit" stable-directory storage >"$fixture/output" 2>&1; then exit 1; fi
test ! -e "$HOME/.deployments/app/deploy.lock"
test -L "$HOME/.deployments/app/state/failed"
test "$(readlink "$HOME/.deployments/app/state/failed")" = "$fixture/foreign-absent"
bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null
checks=$((checks + 1))
echo "ok - $checks initialization fault/ownership cases; later acquisition and app preservation proven"
