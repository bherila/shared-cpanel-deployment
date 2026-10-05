#!/usr/bin/env bash
# One bounded host session owns preparation, serving proof and direct rollback.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"
bash "$here/validate-recover-orphan-inputs.sh" "$@" || exit 2
mode=$1 app=$2 release=$3 commit=$4 token=$5 persistent=$6 php=$7 memory=$8 site=$9
[[ -x $php ]] || exit 2
timeout_binary=$(command -v timeout)
[[ $timeout_binary == /* && -x $timeout_binary ]] || exit 2
umask 077
work=$(mktemp -d)
ulimit -f 8192
started=false completed=false may_up=false
state() {
    "$timeout_binary" --kill-after=2s 10s "$php" -d "memory_limit=$memory" -d display_errors=0 -d log_errors=0 \
        "$here/recover-orphan-state.php" "$1" "$app" "$release" "$commit" "$token" "$persistent" "${2:-}" \
        >"$work/state" 2>"$work/error" && one_record "$work/state" 'orphan-recovery state=validated'
}
one_record() {
    [[ $(wc -c <"$1") -le 512 ]] && printf '%s\n' "$2" | cmp -s -- "$1" -
}
framework() {
    "$timeout_binary" --kill-after=2s 45s "$php" -d "memory_limit=$memory" -d display_errors=0 -d log_errors=0 \
        "$here/recover-orphan-framework.php" "$1" "$app" "$release" "$commit" "$token" "$persistent" \
        >"$work/framework" 2>"$work/error" && one_record "$work/framework" "orphan-recovery framework=$2"
}
cron_paused() {
    local status=0
    "$timeout_binary" --kill-after=2s 10s crontab -l >"$work/cron" 2>"$work/error" || status=$?
    if [[ $status != 0 ]]; then
        [[ $status == 1 && ! -s $work/cron && $(wc -c <"$work/error") -le 256 ]] || return 1
        LC_ALL=C awk '
            NR != 1 || tolower($0) !~ /^(crontab: )?no crontab for [a-z0-9_.-]+\$?$/ { invalid=1 }
            END { if (NR != 1 || invalid) exit 1 }
        ' "$work/error" || return 1
    fi
    state cron-paused "$work/cron"
}
audit() {
    state "$1" && "$timeout_binary" --kill-after=2s 60s bash "$here/operational-audit.sh" \
        "$app" "$php" "$memory" "$release" "$commit" "$persistent" selected \
        >"$work/audit" 2>"$work/error" && [[ $(wc -c <"$work/audit") -le 512 ]] || return 1
    LC_ALL=C awk '
        NR == 1 { if ($0 != "runtime-audit identity=exact paths=canonical writable=yes database=persistent phase=selected") invalid=1; next }
        NR != 2 || $0 !~ /^operational-audit pending_migrations=0 queue_driver=(sync|null|database|redis|sqs|beanstalkd|deferred|background|failover) queue_applicability=(database|no-persistent-queue|external) pending_total=([0-9]+|not-counted) failed_applicability=(database|disabled|external) failed_total=([0-9]+|not-counted)$/ { invalid=1 }
        END { if (NR != 2 || invalid) exit 1 }
    ' "$work/audit"
}
finish() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ $completed == true && $status == 0 ]]; then rm -rf -- "$work"; return; fi
    if [[ $started == true ]] && state restore && cron_paused && state release-down; then
        echo 'orphan-recovery result=failed rollback=maintenance cron=paused lock=released'
    elif [[ -e $HOME/.deployments/$app/deploy.lock || -L $HOME/.deployments/$app/deploy.lock ]]; then
        echo 'orphan-recovery result=failed rollback=unconfirmed lock=retained'
    elif [[ $may_up == true ]]; then
        echo 'orphan-recovery result=failed rollback=unconfirmed lock=absent'
    else
        echo 'orphan-recovery result=refused service_mutations=none lock=absent'
    fi
    rm -rf -- "$work"
    exit 1
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
if [[ $mode == restore ]]; then
    started=true
    state restore && cron_paused && state release-down || exit 1
    completed=true
    echo 'orphan-recovery result=restored identity=exact maintenance=original cron=paused lock=released'
    exit 0
fi
state inspect "$here/preflight-record.json" && cron_paused || exit 1
started=true
state initialize "$here/preflight-record.json" && state owned-down && cron_paused || exit 1
framework preflight maintenance && state owned-down || exit 1
framework prepare maintenance && audit owned-down && state owned-down && cron_paused || exit 1
state up-armed
may_up=true
framework up serving && state serving && audit owned-up && framework prove-up serving && cron_paused || exit 1
state verifying
status=$("$timeout_binary" --kill-after=2s 25s curl --silent --show-error --max-time 20 \
    --output /dev/null --write-out '%{http_code}' "$site" 2>"$work/error")
[[ $status == 200 ]] && state owned-up || exit 1
if [[ -f $here/orphan-verification.sh && ! -L $here/orphan-verification.sh ]]; then
    export DEPLOY_DIR="$app" DEPLOY_STABLE_DIR="$app" DEPLOY_RELEASE_ID="$release" \
        DEPLOY_SOURCE_COMMIT="$commit" DEPLOY_PHP_BINARY="$php" DEPLOY_LIVE_STATE=serving
    "$timeout_binary" --kill-after=2s 45s bash "$here/orphan-verification.sh" "$HOME/$app" "$php" \
        >"$work/verification" 2>"$work/error"
else exit 1; fi
state owned-up && framework prove-up serving && cron_paused && state release-up || exit 1
completed=true
echo 'orphan-recovery result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released'
