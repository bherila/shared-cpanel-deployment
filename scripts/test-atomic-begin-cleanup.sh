#!/usr/bin/env bash
# Fault every initial metadata write without ever bootstrapping an application.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
finish() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "Failed initialization fixture: ${FAULT_COMMAND:-setup} ${FAULT_FIELD:-none} ${REPLACE:-none}" >&2
        if [ -n "${fixture:-}" ] && [ -f "$fixture/output" ]; then tail -20 "$fixture/output" >&2; fi
    fi
    rm -rf "$scratch"
}
trap finish EXIT
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
            candidate_sources=("$HOME/.deployments/app/releases"/.begin-cleanup-acquire.*-candidate)
            command mv "${candidate_sources[0]}" "$FIXTURE_ROOT/original-candidate"
            mkdir "${candidate_sources[0]}"
            touch "${candidate_sources[0]}/foreign" ;;
        transaction)
            transaction_sources=("$HOME/.deployments/app/state"/.begin-cleanup-acquire.*-transaction)
            command mv "${transaction_sources[0]}" "$FIXTURE_ROOT/original-transaction"
            mkdir "${transaction_sources[0]}"
            touch "${transaction_sources[0]}/foreign" ;;
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
        "$HOME/.deployments/app/state/failed/$FAULT_FIELD"|"$HOME/.deployments/app/state/failed/.$FAULT_FIELD."*|"$HOME/.deployments/app/$FAULT_FIELD"|"$HOME/.deployments/app/.$FAULT_FIELD."*|"$HOME/.deployments/app/deploy.lock/$FAULT_FIELD"|"$HOME/.deployments/app/.begin-cleanup-acquire."*"/$FAULT_FIELD") return 0 ;;
        "$HOME/.deployments/app/.begin-cleanup-acquire."*"/.$FAULT_FIELD."*|"$HOME/.deployments/app/state/.begin-cleanup-acquire."*"/$FAULT_FIELD"|"$HOME/.deployments/app/state/.begin-cleanup-acquire."*"/.$FAULT_FIELD."*) return 0 ;;
        "./$FAULT_FIELD"|"./.$FAULT_FIELD."*) case $PWD in "$HOME/.deployments/app"/.begin-cleanup-acquire.*|"$HOME/.deployments/app/state"/.begin-cleanup-acquire.*) return 0 ;; esac ;;
    esac
    return 1
}
printf() {
    local target process_id=$BASHPID
    target=$(readlink "/proc/$process_id/fd/1" || true)
    if [ "$FAULT_COMMAND" = printf ] && matches_field "$target"; then inject_fault; return 91; fi
    builtin printf "$@"
}
mktemp() {
    if [ "$FAULT_COMMAND" = open ] && matches_field "${!#}"; then
        builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
        # Deny creation in the held private directory. Cleanup restores this
        # fixture's write permission before removing already-proven metadata.
        command chmod 500 .
    fi
    if [ "$FAULT_COMMAND" = persistent-mktemp ] && { matches_field "${!#}" || [ -f "$FIXTURE_ROOT/hit" ]; }; then inject_fault; return 91; fi
    if [ "$FAULT_COMMAND" = mktemp ] && matches_field "${!#}"; then inject_fault; return 91; fi
    "$REAL_MKTEMP" "$@"
}
cmp() {
    if [ "$FAULT_COMMAND" = owner-window ] && [ "$PWD" = "$HOME/.deployments/app/deploy.lock" ] && [ "${@: -2:1}" = ./owner ] && [ ! -f "$FIXTURE_ROOT/hit" ]; then
        builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
        command mv "$HOME/.deployments/app/deploy.lock" "$FIXTURE_ROOT/original-owner-window"
        command mkdir "$HOME/.deployments/app/deploy.lock"
        builtin printf 'failed\n' >"$HOME/.deployments/app/deploy.lock/owner"
        builtin printf 'foreign started\n' >"$HOME/.deployments/app/deploy.lock/started"
        builtin printf 'foreign timeout\n' >"$HOME/.deployments/app/deploy.lock/requested-timeout"
    fi
    command cmp "$@"
}
stat() {
    if [ "$FAULT_COMMAND" = temp-symlink ] && [[ ${!#} == ./.persistent-paths.* ]] && [ ! -f "$FIXTURE_ROOT/hit" ]; then
        builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
        command mv "${!#}" "$FIXTURE_ROOT/held-original-temp"
        command ln -s "$FIXTURE_ROOT/unrelated" "${!#}"
    fi
    if [ "$FAULT_COMMAND" = lock-stat ] && [ "${!#}" = "$HOME/.deployments/app/deploy.lock" ] && [ ! -f "$FIXTURE_ROOT/hit" ]; then
        builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
        command mv "$HOME/.deployments/app/deploy.lock" "$FIXTURE_ROOT/original-acquired-lock"
        command mkdir "$HOME/.deployments/app/deploy.lock"
        builtin printf 'replacement\n' >"$HOME/.deployments/app/deploy.lock/owner"
    fi
    if [ "$FAULT_COMMAND" = directory-stat ] && [ ! -f "$FIXTURE_ROOT/hit" ]; then
        local target
        case $FAULT_FIELD in
            candidate) target="$HOME/.deployments/app/releases/failed" ;;
            transaction) target="$HOME/.deployments/app/state/failed" ;;
        esac
        if [ "${!#}" = "$target" ]; then
            builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
            command mv "$target" "$FIXTURE_ROOT/original-published"
            command mkdir "$target"
            builtin printf 'foreign payload\n' >"$target/foreign"
        fi
    fi
    command stat "$@"
}
swap_cleanup() {
    local target=$1 boundary=$2
    touch "$FIXTURE_ROOT/removal-hit"
    command mv "$target" "$FIXTURE_ROOT/original-removal"
    command mkdir "$target"
    builtin printf 'foreign payload\n' >"$target/foreign"
    [ "$boundary" != lock ] || builtin printf 'replacement\n' >"$target/owner"
}
rm() {
    if [ "$FAULT_COMMAND" = open ] && [ -f "$FIXTURE_ROOT/hit" ]; then command chmod 700 .; fi
    case ${REPLACE:-none}:$PWD in
        rm-transaction:*/.begin-cleanup-*-transaction|rm-lock:*/.begin-cleanup-*-lock)
            if [ ! -f "$FIXTURE_ROOT/removal-hit" ]; then swap_cleanup "$PWD" "${REPLACE#rm-}"; fi ;;
    esac
    command rm "$@"
}
rmdir() {
    case ${REPLACE:-none}:${!#} in
        rmdir-candidate:*/.begin-cleanup-*-candidate|rmdir-transaction:*/.begin-cleanup-*-transaction|rmdir-lock:*/.begin-cleanup-*-lock)
            if [ ! -f "$FIXTURE_ROOT/removal-hit" ]; then swap_cleanup "${!#}" "${REPLACE#rmdir-}"; fi ;;
    esac
    command rmdir "$@"
}
chmod() {
    local target=${!#}
    if [[ $FAULT_COMMAND == metadata-symlink || $FAULT_COMMAND == metadata-foreign ]] && [[ $target == "$HOME/.deployments/app/state/.begin-cleanup-acquire."*-transaction ]]; then
        builtin printf 'hit\n' >"$FIXTURE_ROOT/hit"
        if [ "$FAULT_COMMAND" = metadata-symlink ]; then
            command ln -s "$FIXTURE_ROOT/unrelated" "$target/persistent-paths"
        else
            builtin printf 'foreign payload\n' >"$target/foreign"
        fi
    fi
    if [ "$FAULT_COMMAND" = prepublish-lock ]; then
        case "$FAULT_FIELD:$target" in
            transaction:"$HOME/.deployments/app/state/.begin-cleanup-acquire."*-transaction|candidate:"$HOME/.deployments/app/releases/.begin-cleanup-acquire."*-candidate) inject_fault || true ;;
        esac
    fi
    if [ "$FAULT_COMMAND" = chmod ]; then
        case "$FAULT_FIELD:$target" in
            transaction:"$HOME/.deployments/app/state/.begin-cleanup-acquire."*-transaction|candidate:"$HOME/.deployments/app/releases/.begin-cleanup-acquire."*-candidate) inject_fault; return 91 ;;
        esac
    fi
    command chmod "$@"
}
mkdir() {
    local target=${!#}
    if [ "$FAULT_COMMAND" = mkdir-after ]; then
        case "$FAULT_FIELD:$target" in
            transaction:"$HOME/.deployments/app/state/.begin-cleanup-acquire."*-transaction|candidate:"$HOME/.deployments/app/releases/.begin-cleanup-acquire."*-candidate) command mkdir "$@"; inject_fault; return 91 ;;
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
                            path=${@: -2:1}
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
# Initial exclusive temporaries add allocation/publication boundaries for
# persistent paths and all lock records, before canonical publication.
for field in persistent-paths started requested-timeout; do
    for command in mktemp mv; do
        setup
        export FAULT_COMMAND="$command" FAULT_FIELD="$field" REPLACE=none
        run_fault
        assert_reacquire
    done
done
# Exclusive creation may fail before any field contents exist. Existing owner
# proof permits cleanup; an incomplete first owner remains deliberate evidence.
if [ "$(id -u)" -ne 0 ]; then
    for field in "${fields[@]}" persistent-paths started requested-timeout; do
        setup
        export FAULT_COMMAND=open FAULT_FIELD="$field" REPLACE=none
        run_fault
        assert_reacquire
    done
fi
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
    transaction_sources=("$HOME/.deployments/app/state"/.begin-cleanup-acquire.*-transaction)
    candidate_sources=("$HOME/.deployments/app/releases"/.begin-cleanup-acquire.*-candidate)
    test -d "${transaction_sources[0]}"
    test -d "${candidate_sources[0]}"
    case $replacement in
        lock|owner) test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = replacement ;;
        same-token) test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = failed ;;
        candidate) test -f "${candidate_sources[0]}/foreign" ;;
        transaction) test -f "${transaction_sources[0]}/foreign" ;;
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
transaction_sources=("$HOME/.deployments/app/state"/.begin-cleanup-acquire.*-transaction)
candidate_sources=("$HOME/.deployments/app/releases"/.begin-cleanup-acquire.*-candidate)
test -d "${transaction_sources[0]}"
test -d "${candidate_sources[0]}"
checks=$((checks + 1))

for field in transaction candidate; do
    setup
    export FAULT_COMMAND=mkdir-after FAULT_FIELD="$field" REPLACE=none
    run_fault
    test -d "$HOME/.deployments/app/deploy.lock"
    if [ "$field" = transaction ]; then
        partial_sources=("$HOME/.deployments/app/state"/.begin-cleanup-acquire.*-transaction)
    else
        transaction_sources=("$HOME/.deployments/app/state"/.begin-cleanup-acquire.*-transaction)
        test -d "${transaction_sources[0]}"
        partial_sources=("$HOME/.deployments/app/releases"/.begin-cleanup-acquire.*-candidate)
    fi
    test -d "${partial_sources[0]}"
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
        *) original_sources=("$fixture/original-ancestor"/.begin-cleanup-acquire.*); test -d "${original_sources[0]}" ;;
    esac
    test -f "$HOME/.deployments/app/$(case $replacement in control) echo foreign ;; *) echo "$replacement/foreign" ;; esac)"
    [ "$replacement" = control ] || test -d "$HOME/.deployments/app/deploy.lock"
    checks=$((checks + 1))
done
# The first owner write can leave an empty private owner record. Preserve
# hidden evidence and refuse another begin until deliberate recovery.
setup
export FAULT_COMMAND=printf FAULT_FIELD=owner REPLACE=none
run_fault
test ! -e "$HOME/.deployments/app/deploy.lock"
private_sources=("$HOME/.deployments/app"/.begin-cleanup-acquire.*)
test -d "${private_sources[0]}"
test ! -s "${private_sources[0]}/owner"
if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
checks=$((checks + 1))
for command in mktemp mv; do
    setup
    export FAULT_COMMAND="$command" FAULT_FIELD=owner REPLACE=none
    run_fault
    test ! -e "$HOME/.deployments/app/deploy.lock"
    private_sources=("$HOME/.deployments/app"/.begin-cleanup-acquire.*)
    test -d "${private_sources[0]}"
    if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
    checks=$((checks + 1))
done
# Replace the canonical lock exactly as its identity is first checked. The
# prepared source identity must not adopt or overwrite the replacement owner.
setup
export FAULT_COMMAND=lock-stat FAULT_FIELD=none REPLACE=none
run_fault
test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = replacement
checks=$((checks + 1))
for field in transaction candidate; do
    setup
    export FAULT_COMMAND=directory-stat FAULT_FIELD="$field" REPLACE=none
    run_fault
    test -d "$HOME/.deployments/app/deploy.lock"
    case $field in
        transaction) test -f "$HOME/.deployments/app/state/failed/foreign" ;;
        candidate) test -f "$HOME/.deployments/app/releases/failed/foreign" ;;
    esac
    checks=$((checks + 1))
done
for field in transaction candidate; do
    setup
    export FAULT_COMMAND=prepublish-lock FAULT_FIELD="$field" REPLACE=lock
    run_fault
    test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = replacement
    case $field in
        transaction) test ! -e "$HOME/.deployments/app/state/failed" ;;
        candidate) test ! -e "$HOME/.deployments/app/releases/failed" ;;
    esac
    checks=$((checks + 1))
done
# The owner is checked through a held inode before the final canonical check.
setup
export FAULT_COMMAND=owner-window FAULT_FIELD=none REPLACE=none
run_fault
test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = failed
test "$(cat "$HOME/.deployments/app/deploy.lock/started")" = 'foreign started'
test "$(cat "$HOME/.deployments/app/deploy.lock/requested-timeout")" = 'foreign timeout'
checks=$((checks + 1))
# Inject a field symlink, replace the open temporary name with a symlink, or add
# unknown regular payload. No outside file may be overwritten or payload erased.
for fault in metadata-symlink temp-symlink metadata-foreign; do
    setup
    printf 'unrelated account payload\n' >"$fixture/unrelated"
    export FAULT_COMMAND="$fault" FAULT_FIELD=none REPLACE=none
    run_fault
    test "$(cat "$fixture/unrelated")" = 'unrelated account payload'
    test -d "$HOME/.deployments/app/deploy.lock"
    if [ "$fault" = metadata-foreign ]; then
        transaction_sources=("$HOME/.deployments/app/state"/.begin-cleanup-*-transaction)
        test "$(cat "${transaction_sources[0]}/foreign")" = 'foreign payload'
    fi
    if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
    checks=$((checks + 1))
done
# Replace each detached path as the deletion command itself starts. Flat
# metadata removals stay inside the held original cwd; rmdir never erases data.
for replacement in rmdir-candidate rm-transaction rmdir-transaction rm-lock rmdir-lock; do
    setup
    export FAULT_COMMAND=mv FAULT_FIELD=phase REPLACE="$replacement"
    run_fault
    test -f "$fixture/removal-hit"
    test "$(find "$HOME/.deployments/app" -name foreign -type f | wc -l)" -eq 1
    test -d "$HOME/.deployments/app/deploy.lock"
    if [[ $replacement == *-lock ]]; then test "$(cat "$HOME/.deployments/app/deploy.lock/owner")" = replacement; fi
    if bash "$here/atomic-release.sh" begin app retry "$commit" 7200 3 maintenance "$commit" stable-directory storage >/dev/null 2>&1; then exit 1; fi
    checks=$((checks + 1))
done
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
