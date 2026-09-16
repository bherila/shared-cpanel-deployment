#!/usr/bin/env bash
# Static phase-order and v2-interface contract for the composite action.
# shellcheck disable=SC2016
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
action="$here/action.yml"
fails=0

check() {
    local name=$1
    shift
    if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails + 1)); fi
}

line_of() {
    local text=$1
    { grep -nFx -- "    - $text" "$action" || grep -nFx -- "      $text" "$action"; } | head -1 | cut -d: -f1
}

atomic_default=$(awk '$1 == "deployment-mode:" { found=1 } found && $1 == "default:" { print $2; exit }' "$action")
check "v2 defaults to atomic deployment" test "$atomic_default" = atomic
layout_default=$(awk '$1 == "atomic-layout:" { found=1 } found && $1 == "default:" { print $2; exit }' "$action")
check "atomic deployment defaults to a cPanel-compatible real stable directory" test "$layout_default" = stable-directory
check "legacy in-place mode remains an explicit branch" grep -Fq "inputs.deployment-mode == 'in-place'" "$action"
check "the selected atomic layout is persisted with the remote transaction" grep -Fq '"$ATOMIC_LAYOUT" "${paths[@]}"' "$action"

recovery=$(line_of 'name: Finalize an explicitly selected interrupted transaction')
begin=$(line_of 'name: Start the remote atomic transaction')
capacity=$(line_of 'name: Verify remote capacity before atomic upload')
upload=$(line_of 'name: Upload the atomic candidate')
preflight=$(line_of 'name: Preflight the atomic conversion and host capacity')
conversion_quiesce=$(line_of 'name: Quiesce the selected atomic deployment')
conversion_drain=$(line_of 'name: Drain processes before persistent conversion')
prepare=$(line_of 'name: Prepare shared runtime paths and the atomic candidate')
versioned_quiesce=$(line_of 'name: Quiesce an already-versioned atomic deployment')
versioned_drain=$(line_of 'name: Drain processes before the atomic risk boundary')
risk=$(line_of 'name: Enter the atomic database-risk boundary')
pre_migrate=$(line_of 'name: Run the pre-migrate script')
migrate=$(line_of 'name: Clear config and migrate')
candidate_cache=$(line_of 'name: Cache config and run extra Artisan commands')
post_deploy=$(line_of 'name: Run the post-deploy script')
pre_activate=$(line_of 'name: Run atomic pre-activation checks')
activate=$(line_of 'name: Atomically select the candidate')
stable_cache=$(line_of 'name: Rebuild caches from the stable atomic path')
webroot=$(line_of "name: Ensure the atomic deployment's stable webroot symlink")
cron=$(line_of "name: Install the atomic deployment's cron lines")
post_activate=$(line_of 'name: Run the atomic post-activation script')
serve=$(line_of 'name: Bring the selected atomic release online')
verification=$(line_of 'name: Run application-specific live verification')
commit=$(line_of 'name: Commit the verified atomic release')
finalize=$(line_of 'name: Recover, unlock and report the atomic deployment')

check "read-only preflight precedes first-conversion mutation" test "$begin" -lt "$preflight" -a "$preflight" -lt "$prepare"
check "explicit interrupted-transaction recovery precedes a new transaction" test "$recovery" -lt "$begin"
check "explicit recovery must prove serving before a new transaction" grep -Fq 'Interrupted transaction finalized without proving that the selected application is serving' "$action"
check "capacity is enforced before candidate upload" test "$begin" -lt "$capacity" -a "$capacity" -lt "$upload"
check "legacy worker drain precedes first-conversion mutation" test "$preflight" -lt "$conversion_quiesce" -a "$conversion_quiesce" -lt "$conversion_drain" -a "$conversion_drain" -lt "$prepare"
check "versioned worker drain precedes durable risk and migration" test "$prepare" -lt "$versioned_quiesce" -a "$versioned_quiesce" -lt "$versioned_drain" -a "$versioned_drain" -lt "$risk" -a "$risk" -lt "$pre_migrate" -a "$pre_migrate" -lt "$migrate"
check "candidate-path caching is disabled only for real stable-directory activation" grep -Fq "if: inputs.deployment-mode != 'atomic' || inputs.atomic-layout != 'stable-directory'" "$action"
check "release-symlink and in-place caching retain their pre-activation order" test "$migrate" -lt "$candidate_cache" -a "$candidate_cache" -lt "$post_deploy"
check "candidate post-deploy checks gate activation" test "$post_deploy" -lt "$pre_activate" -a "$pre_activate" -lt "$activate"
check "stable-directory caches are rebuilt after selection and before stable-path hooks" test "$activate" -lt "$stable_cache" -a "$stable_cache" -lt "$webroot"
check "stable-directory cache rebuild is limited to its layout" grep -Fq "if: inputs.deployment-mode == 'atomic' && inputs.atomic-layout == 'stable-directory'" "$action"
check "cache rebuild runs through the guarded atomic state machine" grep -Fq 'refresh-caches "$DEPLOY_DIR" "$RELEASE_ID"' "$action"
check "the atomic state machine refuses to serve before final-path caches exist" grep -Fq 'Stable-directory caches were not rebuilt from the final selected path.' "$here/scripts/atomic-release.sh"
check "stable hooks finish down and cron starts only after serving proof" test "$stable_cache" -lt "$webroot" -a "$webroot" -lt "$post_activate" -a "$post_activate" -lt "$serve" -a "$serve" -lt "$cron" -a "$cron" -lt "$verification"
check "live verification gates commit" test "$serve" -lt "$verification" -a "$verification" -lt "$commit"
check "pre-verification status requires the exact serving candidate" grep -Fq 'Selected atomic release is not the exact serving candidate' "$action"
check "commit rechecks Laravel serving state" grep -Fq 'commit "$DEPLOY_DIR" "$RELEASE_ID" "$PHP_BINARY"' "$action"
check "the recovery finalizer is last and unconditional on prior success" test "$commit" -lt "$finalize"
check "finalizer uses always()" grep -Fq "if: always() && inputs.deployment-mode == 'atomic'" "$action"
check "nonzero recovery output is captured before status propagation" grep -Fq 'output=$(ssh "$TARGET"' "$action"
check "Passport keys must be covered by persistent state" grep -Fq 'passport-key-directory must be inside a declared persistent-path' "$action"
check "existing apps require an explicit quiescence policy" grep -Fq 'Existing atomic deployments require quiesce-script' "$action"
check "fresh installs never invoke the app quiesce hook" grep -Fq "steps.atomic-preflight.outputs.existing_release == 'true' && inputs.quiesce-script != ''" "$action"
check "unmanaged cron has an explicit restoration phase" grep -Fq 'name: Restore unmanaged atomic cron lines' "$action"
check "candidate and live release outputs are exposed" grep -Fq 'live-state:' "$action"
check "remote atomic state machine does not require /dev/fd process substitution" sh -c \
    '! grep -Fq '\''< <('\'' "$1"' sh "$here/scripts/atomic-release.sh"

echo "failures: $fails"
exit "$fails"
