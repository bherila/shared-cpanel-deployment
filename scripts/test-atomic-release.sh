#!/usr/bin/env bash
# Integration harness for the remote atomic release state machine.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/atomic-release.sh"
artisan_script="$here/remote-artisan.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
original_path=$PATH
fails=0

check() {
    local name=$1
    shift
    if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails + 1)); fi
}
check_expr() {
    local name=$1 expression=$2
    if eval "$expression"; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails + 1)); fi
}

setup() {
    root=$(mktemp -d "$scratch/case.XXXXXX")
    export HOME="$root/home"
    mkdir -p "$HOME" "$root/bin"
    export CRONTAB_FILE="$root/crontab" PHP_LOG="$root/php.log" FAIL_MIGRATION=false FAIL_DOWN=false FAIL_UP=false
    cat >"$root/bin/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then
    [ -f "$CRONTAB_FILE" ] || { echo 'no crontab for tester' >&2; exit 1; }
    cat "$CRONTAB_FILE"
elif [ "${1:-}" = -r ]; then
    rm -f "$CRONTAB_FILE"
else
    cp "$1" "$CRONTAB_FILE"
fi
SH
    cat >"$root/bin/php" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$PHP_LOG"
while [ "${1:-}" = -d ]; do shift 2; done
[ "${1:-}" = artisan ] && shift
case ${1:-} in
    -r) [ -f storage/framework/down ] ;;
    down) [ "$FAIL_DOWN" != true ] || exit 43; mkdir -p storage/framework; : >storage/framework/down ;;
    up) [ "$FAIL_UP" != true ] || exit 44; rm -f storage/framework/down ;;
    migrate) [ "$FAIL_MIGRATION" != true ] || exit 42 ;;
esac
SH
    chmod +x "$root/bin/crontab" "$root/bin/php"
    export PATH="$root/bin:$original_path"
    php="$root/bin/php"
    commit=0123456789abcdef0123456789abcdef01234567
}

make_legacy() {
    mkdir -p "$HOME/app/storage/framework" "$HOME/app/storage/app" "$HOME/app/public" "$HOME/app/vendor" "$HOME/app/bootstrap"
    : >"$HOME/app/artisan"
    : >"$HOME/app/vendor/autoload.php"; : >"$HOME/app/bootstrap/app.php"
    printf 'APP_KEY=base64:test\nAPP_ENV=production\nAPP_URL=https://example.test\n' >"$HOME/app/.env"
    printf 'runtime\n' >"$HOME/app/storage/app/live.txt"
    printf '* * * * * cd "$HOME/app" && php artisan schedule:run # JOB:app-scheduler\n' >"$CRONTAB_FILE"
}

begin_and_upload() {
    local release=$1 policy=${2:-maintenance} initial
    initial=''
    [ -d "$HOME/app" ] && [ ! -L "$HOME/app" ] && initial=$commit
    bash "$script" begin app "$release" "$commit" 7200 3 "$policy" "$initial" storage >/dev/null
    candidate="$HOME/.deployments/app/releases/$release"
    mkdir -p "$candidate/storage/framework" "$candidate/storage/app" "$candidate/public" "$candidate/vendor" "$candidate/bootstrap"
    : >"$candidate/artisan"
    : >"$candidate/vendor/autoload.php"; : >"$candidate/bootstrap/app.php"
}

status_field() {
    local release=$1 field=$2
    bash "$script" status app "$release" "$php" | sed -n "s/^${field}=//p" | head -1
}

preflight_quiesce() {
    local release=$1
    bash "$script" preflight app "$release" '' >/dev/null
    bash "$script" quiesce app "$release" "$php" >/dev/null
}

# First conversion is quiesced before runtime data moves, and pre-risk recovery restores service.
setup; make_legacy
bash "$script" begin app missing-initial "$commit" 7200 3 maintenance '' storage >/dev/null 2>&1
check "first conversion requires the exact existing live commit" test "$?" -eq 1

setup; make_legacy; begin_and_upload r1
ln -s app/public "$HOME/example.test"
bash "$script" preflight app r1 example.test >"$root/preflight.out"
check_expr "preflight reports conversion, persistence, filesystem and disk state" \
    'grep -Fq "conversion_required=true" "$root/preflight.out" && grep -Fq "persistent path storage" "$root/preflight.out" && grep -Fq "filesystem device" "$root/preflight.out" && grep -Fq "Preflight disk:" "$root/preflight.out"'
bash "$script" quiesce app r1 "$php" 1G >/dev/null
check "quiesce pauses cron before conversion" test ! -s "$CRONTAB_FILE"
check "quiesce puts old code in maintenance" test "$(status_field r1 live_state)" = maintenance
check "atomic lifecycle Artisan commands inherit the configured memory limit" grep -Fq -- '-d memory_limit=1G artisan down' "$PHP_LOG"
check "Laravel maintenance probes inherit the configured memory limit" grep -Fq -- '-d memory_limit=1G -r' "$PHP_LOG"
bash "$script" prepare app r1 "$php" 1G >/dev/null
legacy_target=$(readlink "$HOME/app")
check "legacy conversion keeps a managed old release selected" test "$legacy_target" != ".deployments/app/releases/r1"
check "legacy and candidate use managed shared storage" test "$(readlink -f "$HOME/app/storage")" = "$HOME/.deployments/app/shared/storage"
check "runtime data survives first conversion" test -f "$HOME/.deployments/app/shared/storage/app/live.txt"
check "candidate environment is copied without sharing it" test -f "$candidate/.env"
bash "$script" begin app r2 "$commit" 1 3 maintenance '' storage >/dev/null 2>&1
check "a concurrent deployment is refused even after its requested timeout" test "$?" -ne 0
bash "$script" finalize app r1 "$php" 1G >/dev/null
check "pre-risk recovery keeps old code selected" test "$(readlink "$HOME/app")" = "$legacy_target"
check "pre-risk recovery restores serving state" test "$(status_field r1 live_state)" = serving
check "pre-risk recovery restores cron" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"

setup
bash "$script" begin app webroot-collision "$commit" 7200 3 maintenance '' storage >/dev/null
candidate="$HOME/.deployments/app/releases/webroot-collision"; mkdir -p "$candidate/storage"; : >"$candidate/artisan"
bash "$script" preflight app webroot-collision app >/dev/null 2>&1
check "preflight rejects a webroot name equal to the stable application path" test "$?" -eq 2
bash "$script" finalize app webroot-collision "$php" >/dev/null

setup; make_legacy; begin_and_upload before-move; preflight_quiesce before-move
check "pre-move interruption leaves no provisional release metadata on the real stable directory" test ! -e "$HOME/app/.deploy-release"
bash "$script" finalize app before-move "$php" >"$root/before-move-finalize.out"
check "pre-move recovery reports the exact old commit without provisional metadata" grep -Fq "live_commit=$commit" "$root/before-move-finalize.out"
check "standalone status retains the asserted exact legacy commit" test "$(status_field before-move live_commit)" = "$commit"
begin_and_upload conversion-retry; preflight_quiesce conversion-retry; bash "$script" prepare app conversion-retry "$php" >/dev/null
check "a new conversion attempt succeeds after pre-move interruption" test -L "$HOME/app"
bash "$script" finalize app conversion-retry "$php" >/dev/null

# Control and persistent path ancestors can never redirect mutations.
setup; mkdir -p "$HOME/.deployments/app" "$root/outside"; : >"$root/outside/sentinel"; ln -s "$root/outside" "$HOME/.deployments/app/releases"
bash "$script" begin app bad-control "$commit" 1 3 maintenance '' storage >/dev/null 2>&1
check "a symlinked control subtree is refused" test "$?" -ne 0
check "control-path refusal preserves outside data" test -f "$root/outside/sentinel"

setup; mkdir -p "$HOME/.deployments/app/releases" "$HOME/.deployments/app/shared" "$HOME/.deployments/app/state"; chmod 500 "$HOME/.deployments/app/state"
bash "$script" begin app init-fails "$commit" 1 3 maintenance '' storage >/dev/null 2>&1
check "partial begin initialization failure is surfaced" test "$?" -ne 0
check "partial begin failure releases its owned lock" test ! -e "$HOME/.deployments/app/deploy.lock"
chmod 700 "$HOME/.deployments/app/state"

setup; make_legacy
bash "$script" begin app ancestor "$commit" 1 3 maintenance "$commit" foo/bar >/dev/null
candidate="$HOME/.deployments/app/releases/ancestor"; mkdir -p "$candidate" "$root/outside"
: >"$candidate/artisan"; : >"$root/outside/sentinel"; ln -s "$root/outside" "$candidate/foo"
bash "$script" preflight app ancestor '' >/dev/null 2>&1
check "a candidate symlink ancestor is refused" test "$?" -ne 0
check "ancestor refusal leaves outside data untouched" test -f "$root/outside/sentinel"
bash "$script" finalize app ancestor "$php" >/dev/null

setup; make_legacy
bash "$script" begin app shared-ancestor "$commit" 1 3 maintenance "$commit" foo/bar >/dev/null
candidate="$HOME/.deployments/app/releases/shared-ancestor"; mkdir -p "$candidate/foo" "$root/outside"; : >"$candidate/artisan"; : >"$candidate/foo/bar"; : >"$root/outside/sentinel"; ln -s "$root/outside" "$HOME/.deployments/app/shared/foo"
bash "$script" preflight app shared-ancestor '' >/dev/null 2>&1
check "a shared-state symlink ancestor is refused" test "$?" -ne 0
check "shared-ancestor refusal leaves outside data untouched" test -f "$root/outside/sentinel"
bash "$script" finalize app shared-ancestor "$php" >/dev/null

# Persistent files and explicitly declared non-code public assets are supported; lone SQLite is not.
setup; make_legacy
mkdir -p "$HOME/app/runtime" "$HOME/app/public/ohif"; printf 'token\n' >"$HOME/app/runtime/state.bin"; printf 'viewer\n' >"$HOME/app/public/ohif/index.html"
bash "$script" begin app files "$commit" 7200 3 maintenance "$commit" storage runtime/state.bin public/ohif >/dev/null
candidate="$HOME/.deployments/app/releases/files"; mkdir -p "$candidate/storage" "$candidate/runtime" "$candidate/public/ohif" "$candidate/vendor" "$candidate/bootstrap"; : >"$candidate/artisan"; : >"$candidate/vendor/autoload.php"; : >"$candidate/bootstrap/app.php"; : >"$candidate/runtime/state.bin"
bash "$script" preflight app files '' >/dev/null; bash "$script" quiesce app files "$php" >/dev/null; bash "$script" prepare app files "$php" >/dev/null
check "a standalone persistent regular file is shared" test "$(readlink -f "$candidate/runtime/state.bin")" = "$HOME/.deployments/app/shared/runtime/state.bin"
check "regular-file contents survive conversion" grep -Fq token "$HOME/.deployments/app/shared/runtime/state.bin"
check "declared public assets are shared" test "$(readlink -f "$candidate/public/ohif")" = "$HOME/.deployments/app/shared/public/ohif"
bash "$script" finalize app files "$php" >/dev/null

setup; make_legacy
for unsafe in public public/index.php public/.htaccess public/build database/migrations app config routes resources bootstrap/app.php package.json database/database.sqlite; do
    bash "$script" begin app "unsafe-${unsafe//\//-}" "$commit" 7200 3 maintenance "$commit" "$unsafe" >/dev/null 2>&1
    check "release-code or SQLite path '$unsafe' cannot be persistent" test "$?" -eq 2
done

# Existing shared and live copies, dangling links, and absent paths fail closed.
setup; make_legacy; begin_and_upload both-copies; mkdir -p "$HOME/.deployments/app/shared/storage"; : >"$HOME/.deployments/app/shared/storage/shared-only"
bash "$script" preflight app both-copies '' >/dev/null 2>&1
check "preflight refuses distinct live and shared copies" test "$?" -ne 0
check "both persistent copies remain intact" test -f "$HOME/app/storage/app/live.txt" -a -f "$HOME/.deployments/app/shared/storage/shared-only"
bash "$script" finalize app both-copies "$php" >/dev/null

setup; make_legacy
bash "$script" begin app absent-file "$commit" 7200 3 maintenance "$commit" storage runtime/missing.bin >/dev/null
candidate="$HOME/.deployments/app/releases/absent-file"; mkdir -p "$candidate/storage" "$candidate/runtime" "$candidate/vendor" "$candidate/bootstrap"; : >"$candidate/artisan"; : >"$candidate/vendor/autoload.php"; : >"$candidate/bootstrap/app.php"
bash "$script" preflight app absent-file '' >/dev/null; bash "$script" quiesce app absent-file "$php" >/dev/null
bash "$script" prepare app absent-file "$php" >"$root/absent.out" 2>&1
absent_status=$?
check "an absent persistent file is refused instead of guessed" test "$absent_status" -ne 0
check "absent path reports type ambiguity" grep -Fq 'type will not be guessed' "$root/absent.out"
bash "$script" finalize app absent-file "$php" >/dev/null

# Interruptions after cron pause or down recover because intent was durable first.
setup; make_legacy; begin_and_upload down-fails; bash "$script" preflight app down-fails '' >/dev/null
export FAIL_DOWN=true; bash "$script" quiesce app down-fails "$php" >/dev/null 2>&1; check "down failure is surfaced after cron pause" test "$?" -ne 0
export FAIL_DOWN=false; bash "$script" finalize app down-fails "$php" >/dev/null
check "failed quiesce restores cron" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"
check "failed quiesce restores serving state" test "$(status_field down-fails live_state)" = serving

setup; make_legacy; begin_and_upload after-down; preflight_quiesce after-down; bash "$script" finalize app after-down "$php" >/dev/null
check "interruption after down restores serving" test "$(status_field after-down live_state)" = serving
check "interruption after down restores cron" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"

setup; make_legacy
bash "$script" begin app candidate-only "$commit" 7200 3 maintenance "$commit" storage runtime/newdata >/dev/null
candidate="$HOME/.deployments/app/releases/candidate-only"; mkdir -p "$candidate/storage/framework" "$candidate/runtime/newdata" "$candidate/vendor" "$candidate/bootstrap"; : >"$candidate/artisan"; : >"$candidate/vendor/autoload.php"; : >"$candidate/bootstrap/app.php"
bash "$script" preflight app candidate-only '' >/dev/null; bash "$script" quiesce app candidate-only "$php" >/dev/null; bash "$script" finalize app candidate-only "$php" >/dev/null
check "recovery accepts a preflight-absent candidate-only persistent path before seeding" test ! -e "$HOME/app/runtime/newdata"
check "candidate-only pre-risk recovery restores old serving state" test "$(status_field candidate-only live_state)" = serving

setup; make_legacy; begin_and_upload move-before-link; preflight_quiesce move-before-link
mv "$HOME/app/storage" "$HOME/.deployments/app/shared/storage"
bash "$script" finalize app move-before-link "$php" >/dev/null
check "recovery repairs a persistent link after move-before-link interruption" test "$(readlink -f "$HOME/app/storage")" = "$HOME/.deployments/app/shared/storage"
check "move-before-link recovery preserves authoritative runtime data" test -f "$HOME/app/storage/app/live.txt"
check "move-before-link recovery proves serving before restoring cron" test "$(status_field move-before-link live_state)" = serving
check "move-before-link recovery restores cron only after repair" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"

setup; make_legacy; begin_and_upload up-unproven; preflight_quiesce up-unproven; export FAIL_UP=true
bash "$script" finalize app up-unproven "$php" >"$root/up-unproven.out" 2>/dev/null
check "pre-risk recovery fails when serving cannot be established" test "$?" -ne 0
check "unproven serving recovery retains its lock" test -d "$HOME/.deployments/app/deploy.lock"
check "unproven serving recovery keeps application cron paused" test ! -s "$CRONTAB_FILE"
export FAIL_UP=false

setup; make_legacy; begin_and_upload moved-interruption; preflight_quiesce moved-interruption
transaction="$HOME/.deployments/app/state/moved-interruption"; conversion_target=.deployments/app/releases/legacy-interrupted; legacy_root="$HOME/$conversion_target"
mkdir -p "$HOME/.deployments/app/shared"; mv "$HOME/app/storage" "$HOME/.deployments/app/shared/storage"; ln -s "$HOME/.deployments/app/shared/storage" "$HOME/app/storage"
mv "$HOME/app" "$legacy_root"; printf '%s\n' "$conversion_target" >"$transaction/conversion_target"; printf 'converting\n' >"$transaction/phase"; rm -f "$legacy_root/.deploy-release"
bash "$script" finalize app moved-interruption "$php" >"$root/moved-finalize.out"
check "interrupted conversion reselects moved old code" test "$(readlink "$HOME/app")" = "$conversion_target"
check "interrupted conversion reconstructs exact old commit metadata" grep -Fq "commit=$commit" "$legacy_root/.deploy-release"
check "interrupted conversion reports the exact old commit" grep -Fq "live_commit=$commit" "$root/moved-finalize.out"

setup; make_legacy; : >"$HOME/app/storage/framework/down"; begin_and_upload intentional-down; bash "$script" preflight app intentional-down '' >/dev/null
bash "$script" quiesce app intentional-down "$php" >/dev/null 2>&1
check "intentional pre-existing maintenance is refused without mutation" test "$?" -ne 0
check "intentional maintenance leaves cron untouched" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"
bash "$script" finalize app intentional-down "$php" >/dev/null

setup; make_legacy; begin_and_upload legacy-hook-up; preflight_quiesce legacy-hook-up; (cd "$HOME/app" && "$php" artisan up --no-ansi)
bash "$script" prepare app legacy-hook-up "$php" >/dev/null 2>&1
check "legacy conversion refuses a hook that brings old code up" test "$?" -ne 0
check "refused legacy conversion leaves the real old directory selected" test ! -L "$HOME/app"
bash "$script" finalize app legacy-hook-up "$php" >/dev/null

setup; make_legacy; begin_and_upload establish-managed; preflight_quiesce establish-managed; bash "$script" prepare app establish-managed "$php" >/dev/null; bash "$script" finalize app establish-managed "$php" >/dev/null
begin_and_upload versioned-hook-up; bash "$script" preflight app versioned-hook-up '' >/dev/null; bash "$script" prepare app versioned-hook-up "$php" >/dev/null; bash "$script" quiesce app versioned-hook-up "$php" >/dev/null
(cd "$HOME/app" && "$php" artisan up --no-ansi); bash "$script" risk app versioned-hook-up "$php" >/dev/null 2>&1
check "risk boundary refuses a hook that brings old code up" test "$?" -ne 0
check "refused risk boundary remains pre-risk" grep -Fqx false "$HOME/.deployments/app/state/versioned-hook-up/risk_started"
old_target=$(readlink "$HOME/app"); (cd "$HOME/app" && "$php" artisan down --no-ansi)
ln -sfn ".deployments/app/releases/versioned-hook-up" "$HOME/app"
bash "$script" risk app versioned-hook-up "$php" >/dev/null 2>&1
check "risk boundary refuses a stable selection changed after quiescence" test "$?" -ne 0
check "selection-change refusal remains pre-risk" grep -Fqx false "$HOME/.deployments/app/state/versioned-hook-up/risk_started"
ln -sfn "$old_target" "$HOME/app"
bash "$script" finalize app versioned-hook-up "$php" >/dev/null

setup; make_legacy; begin_and_upload candidate-hook-up; preflight_quiesce candidate-hook-up; bash "$script" prepare app candidate-hook-up "$php" >/dev/null; old_target=$(readlink "$HOME/app"); bash "$script" risk app candidate-hook-up "$php" >/dev/null
(cd "$candidate" && "$php" artisan up --no-ansi); bash "$script" activate app candidate-hook-up "$php" >/dev/null 2>&1
check "activation refuses a candidate no longer in maintenance" test "$?" -ne 0
check "refused activation leaves old release selected" test "$(readlink "$HOME/app")" = "$old_target"
bash "$script" finalize app candidate-hook-up "$php" >/dev/null

# A deliberately failing migration keeps exact old code selected and down.
setup; make_legacy; begin_and_upload fail-migration; preflight_quiesce fail-migration; bash "$script" prepare app fail-migration "$php" >/dev/null
old_target=$(readlink "$HOME/app"); bash "$script" risk app fail-migration "$php" >/dev/null; export FAIL_MIGRATION=true
bash "$artisan_script" .deployments/app/releases/fail-migration "$php" '' 'migrate --force' >/dev/null 2>&1; check "the migration harness fails deliberately" test "$?" -eq 42
bash "$script" finalize app fail-migration "$php" >"$root/finalize.out"
check "failed migration never selects candidate code" test "$(readlink "$HOME/app")" = "$old_target"
check "failed migration leaves old selection in maintenance" test "$(status_field fail-migration live_state)" = maintenance
check "failed migration keeps application cron paused" test ! -s "$CRONTAB_FILE"
check "failed migration preserves paused cron for manual recovery" grep -Fq '# JOB:app-scheduler' "$HOME/.deployments/app/recovery/fail-migration.cron"

setup; make_legacy; begin_and_upload down-unproven; preflight_quiesce down-unproven; bash "$script" prepare app down-unproven "$php" >/dev/null; bash "$script" risk app down-unproven "$php" >/dev/null
export FAIL_DOWN=true; bash "$script" finalize app down-unproven "$php" >"$root/down-unproven.out" 2>/dev/null
check "risky recovery fails when maintenance cannot be re-established" test "$?" -ne 0
check "unproven maintenance recovery retains its lock" test -d "$HOME/.deployments/app/deploy.lock"
export FAIL_DOWN=false

# Explicit rollback derives recovery from actual selection, including an interrupted activation.
setup; make_legacy; begin_and_upload rollback-release rollback; preflight_quiesce rollback-release; bash "$script" prepare app rollback-release "$php" >/dev/null
old_target=$(readlink "$HOME/app"); bash "$script" risk app rollback-release "$php" >/dev/null; bash "$script" activate app rollback-release "$php" >/dev/null
printf 'false\n' >"$HOME/.deployments/app/state/rollback-release/activated"; printf 'activating\n' >"$HOME/.deployments/app/state/rollback-release/phase"
bash "$script" finalize app rollback-release "$php" >/dev/null
check "rollback after activation interruption reselects prior release" test "$(readlink "$HOME/app")" = "$old_target"
check "rollback after activation interruption serves only prior release" test "$(status_field rollback-release live_state)" = serving
check "rollback restores prior cron" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"

setup; make_legacy; begin_and_upload rollback-blocked rollback; preflight_quiesce rollback-blocked; bash "$script" prepare app rollback-blocked "$php" >/dev/null
old_target=$(readlink "$HOME/app"); bash "$script" risk app rollback-blocked "$php" >/dev/null; bash "$script" activate app rollback-blocked "$php" >/dev/null
mv "$HOME/$old_target" "$root/prior-away"
bash "$script" finalize app rollback-blocked "$php" >"$root/blocked-finalize.out" 2>/dev/null
blocked_status=$?
check "failed rollback recovery returns nonzero" test "$blocked_status" -ne 0
check "failed rollback never brings selected candidate up" test "$(status_field rollback-blocked live_state)" = maintenance
check_expr "failed recovery still reports exact live status" 'grep -Fq "live_release=rollback-blocked" "$root/blocked-finalize.out" && grep -Fq "live_state=maintenance" "$root/blocked-finalize.out"'
check "failed recovery retains its lock for manual inspection" test -d "$HOME/.deployments/app/deploy.lock"

setup; make_legacy; begin_and_upload rollback-up-fails rollback; preflight_quiesce rollback-up-fails; bash "$script" prepare app rollback-up-fails "$php" >/dev/null
bash "$script" risk app rollback-up-fails "$php" >/dev/null; export FAIL_UP=true
bash "$script" finalize app rollback-up-fails "$php" >"$root/rollback-up-fails.out" 2>/dev/null
check "rollback fails when prior serving state is unproven" test "$?" -ne 0
check "unproven rollback serving state retains its lock" test -d "$HOME/.deployments/app/deploy.lock"
check "unproven rollback serving state keeps application cron paused" test ! -s "$CRONTAB_FILE"
export FAIL_UP=false

# Fresh and healthy deploys stay down through activation; unmanaged cron is restored.
setup
bash "$script" begin app fresh "$commit" 7200 3 maintenance '' storage >/dev/null
candidate="$HOME/.deployments/app/releases/fresh"; mkdir -p "$candidate/storage/framework" "$candidate/vendor" "$candidate/bootstrap"; : >"$candidate/artisan"; : >"$candidate/vendor/autoload.php"; : >"$candidate/bootstrap/app.php"
bash "$script" preflight app fresh '' >/dev/null; bash "$script" prepare app fresh "$php" >/dev/null; bash "$script" quiesce app fresh "$php" >/dev/null; bash "$script" risk app fresh "$php" >/dev/null; bash "$script" activate app fresh "$php" >/dev/null
check "fresh activation remains in maintenance before post-activate work" test "$(status_field fresh live_state)" = maintenance
bash "$script" serve app fresh "$php" >/dev/null; bash "$script" commit app fresh "$php" >/dev/null; bash "$script" finalize app fresh "$php" >/dev/null

setup; make_legacy; begin_and_upload healthy; preflight_quiesce healthy; bash "$script" prepare app healthy "$php" >/dev/null; bash "$script" risk app healthy "$php" >/dev/null
bash "$script" activate app healthy "$php" >/dev/null; bash "$script" serve app healthy "$php" >/dev/null; bash "$script" restore-cron app healthy >/dev/null
mkdir -p "$HOME/.deployments/app/releases/pending-release" "$HOME/.deployments/app/state/pending-release"; printf 'risk\n' >"$HOME/.deployments/app/state/pending-release/phase"
bash "$script" commit app healthy "$php" >/dev/null; bash "$script" finalize app healthy "$php" >/dev/null
check "healthy deployment reports exact selected release" test "$(status_field healthy live_release)" = healthy
check "healthy deployment reports exact commit" test "$(status_field healthy live_commit)" = "$commit"
check "install-cron:false restoration preserves prior app cron" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"
check "cleanup preserves a genuinely active transaction" test -d "$HOME/.deployments/app/releases/pending-release"

# Preparing a later release leaves old code serving until the later quiesce phase.
: >"$PHP_LOG"; begin_and_upload next-healthy; bash "$script" preflight app next-healthy '' >/dev/null; bash "$script" prepare app next-healthy "$php" >/dev/null
check "later candidate preparation does not blip selected release" test ! -s "$PHP_LOG"
check "later candidate preparation leaves old code serving" test "$(status_field next-healthy live_state)" = serving
bash "$script" finalize app next-healthy "$php" >/dev/null

setup; make_legacy; begin_and_upload verifier-downs; preflight_quiesce verifier-downs; bash "$script" prepare app verifier-downs "$php" >/dev/null; bash "$script" risk app verifier-downs "$php" >/dev/null
bash "$script" activate app verifier-downs "$php" >/dev/null; bash "$script" serve app verifier-downs "$php" >/dev/null; (cd "$candidate" && "$php" artisan down --no-ansi)
bash "$script" commit app verifier-downs "$php" >/dev/null 2>&1
check "commit refuses a verification hook that leaves the candidate down" test "$?" -ne 0
bash "$script" finalize app verifier-downs "$php" >/dev/null
check "uncommitted verification failure remains selected in maintenance" test "$(status_field verifier-downs live_state)" = maintenance

# A post-activate hook must leave the selected candidate down for core serve.
setup; make_legacy; begin_and_upload hook-serves; preflight_quiesce hook-serves; bash "$script" prepare app hook-serves "$php" >/dev/null; bash "$script" risk app hook-serves "$php" >/dev/null
bash "$script" activate app hook-serves "$php" >/dev/null; (cd "$candidate" && "$php" artisan up --no-ansi)
bash "$script" serve app hook-serves "$php" >/dev/null 2>&1
check "serve refuses a post-activate hook that brought the candidate online" test "$?" -ne 0
bash "$script" finalize app hook-serves "$php" >/dev/null
check "post-activate contract violation is recovered to selected maintenance" test "$(status_field hook-serves live_state)" = maintenance

# A post-activation verification failure defaults to selected candidate maintenance.
setup; make_legacy; begin_and_upload live-check-failure; preflight_quiesce live-check-failure; bash "$script" prepare app live-check-failure "$php" >/dev/null
bash "$script" risk app live-check-failure "$php" >/dev/null; bash "$script" activate app live-check-failure "$php" >/dev/null; bash "$script" serve app live-check-failure "$php" >/dev/null
bash "$script" restore-cron app live-check-failure >/dev/null
check "application cron starts only after serving is proven" grep -Fq '# JOB:app-scheduler' "$CRONTAB_FILE"
bash "$script" finalize app live-check-failure "$php" >/dev/null
check "post-activation failure leaves candidate selected" test "$(status_field live-check-failure live_release)" = live-check-failure
check "post-activation failure puts candidate in maintenance" test "$(status_field live-check-failure live_state)" = maintenance
check "post-activation failure re-pauses restored application cron" test ! -s "$CRONTAB_FILE"

echo "failures: $fails"
exit "$fails"
