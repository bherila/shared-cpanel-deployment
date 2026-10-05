#!/usr/bin/env bash
# Runner: upload trusted helpers privately, execute one bounded host transaction.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bash "$here/validate-recover-orphan-inputs.sh" "$@" || exit 2
[[ ${RECOVERY_SSH_TARGET:-} =~ ^[A-Za-z0-9._@-]+$ ]] || exit 2
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
umask 077
mkdir "$work/bundle"
for script in recover-orphan-remote.sh recover-orphan-state.php recover-orphan-framework.php validate-recover-orphan-inputs.sh operational-audit.sh; do
    cp -- "$here/$script" "$work/bundle/$script"
done
verifier=${12}
if [[ $verifier != - ]]; then cp -- "$verifier" "$work/bundle/orphan-verification.sh"; fi
# The original local verifier path is not used on the host; the trusted bundle has
# a fixed private filename which was validated before any connection/staging.
remote_verifier=-
if [[ $1 == resume ]]; then remote_verifier=orphan-verification.sh; fi
arguments=("${@:1:11}" "$remote_verifier")
tar -C "$work/bundle" -cf "$work/bundle.tar" .
command=$(cat <<'REMOTE'
umask 077
stage=$(mktemp -d) || exit 1
trap 'rm -rf -- "$stage"' EXIT
tar -xf - -C "$stage" || exit 1
timeout --signal=TERM --kill-after=45s 240s bash "$stage/recover-orphan-remote.sh" "$@"
REMOTE
)
status=0
(ulimit -f 1024; timeout --kill-after=5s 330s ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "$RECOVERY_SSH_TARGET" \
    "bash -c $(printf '%q' "$command") -- $(printf '%q ' "${arguments[@]}")" <"$work/bundle.tar") >"$work/output" 2>"$work/error" || status=$?
if [[ $(wc -c <"$work/output") -le 512 ]] && LC_ALL=C awk '
    NR != 1 || $0 !~ /^orphan-recovery result=(serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released|restored identity=exact maintenance=original cron=paused lock=released|failed rollback=maintenance cron=paused lock=released|failed rollback=unconfirmed lock=(retained|absent)|refused service_mutations=none lock=absent)$/ { invalid=1 }
    END { if (NR != 1 || invalid) exit 1 }
' "$work/output"; then
    if [[ $status == 0 ]] && grep -Eq '^orphan-recovery result=(serving|restored) ' "$work/output"; then
        cat "$work/output"
        exit 0
    fi
    if [[ $status != 0 ]]; then cat "$work/output"; fi
fi
echo '::error::Orphan recovery failed or transport proof is incomplete; inspect the exact recovery token. Diagnostics redacted.' >&2
exit 1
