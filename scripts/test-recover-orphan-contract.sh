#!/usr/bin/env bash
# Explicit input guards run before transport; inspect the separate action order.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch" "$scratch-outside"' EXIT
mkdir "$scratch/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/verifier.sh"
cat >"$scratch/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'connected\n' >>"$FIXTURE_SSH_LOG"
if [[ ${FIXTURE_SSH_MODE:-success} == remote-wrapper ]]; then
    bash -c "${!#}"
    exit
fi
cat >"$FIXTURE_SSH_LOG.tar"
printf 'SECRET_SSH_ERROR\n' >&2
case ${FIXTURE_SSH_MODE:-success} in
    success) echo 'orphan-recovery result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released' ;;
    noisy) echo 'orphan-recovery result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released'; echo SECRET_BODY ;;
    nul) printf '\0orphan-recovery result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released\n' ;;
    timeout) exit 124 ;;
    html) echo '<html>SECRET_BODY</html>' ;;
esac
SH
chmod +x "$scratch/bin/ssh"
args=(resume app selected-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa orphan-0123456789abcdef0123456789abcdef \
    storage /usr/bin/php 256M https://example.test/up selected-maintenance-source-config true verifier.sh)
run() {
    (cd "$scratch"; env RECOVERY_SSH_TARGET=fixture FIXTURE_SSH_LOG="$scratch/ssh.log" FIXTURE_SSH_MODE="${transport:-success}" \
        PATH="$scratch/bin:$PATH" bash "$here/run-recover-orphan.sh" "${args[@]}") >"$scratch/output" 2>&1
}
reject_input() {
    local index=$1 value=$2 previous=${args[$1]}
    args[index]=$value
    rm -f "$scratch/ssh.log"
    if run; then echo "Invalid input index $index passed" >&2; exit 1; fi
    [[ ! -e $scratch/ssh.log ]]
    args[index]=$previous
}
reject_input 0 begin
reject_input 1 public_html
reject_input 1 ../app
reject_input 2 ../release
reject_input 3 deadbeef
reject_input 4 orphan-unknown
reject_input 5 $'storage\npublic/build/assets'
reject_input 5 $'storage\nstorage'
reject_input 5 public/ohif
reject_input 6 'php; touch unsafe'
reject_input 7 -1
reject_input 8 http://example.test/up
reject_input 9 yes
reject_input 10 false
reject_input 11 -
reject_input 11 missing.sh
mkdir "$scratch-outside"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch-outside/verifier.sh"
ln -s "$scratch-outside" "$scratch/escaped"
reject_input 11 escaped/verifier.sh
echo 'ok - all explicit invalid/unsafe inputs are refused before SSH or host staging'
run
grep -Fq 'result=serving' "$scratch/output"
if grep -Fq SECRET "$scratch/output"; then exit 1; fi
tar -tf "$scratch/ssh.log.tar" | grep -Fq './orphan-verification.sh'
echo 'ok - valid input uploads only private trusted helpers plus required verifier and accepts exact bounded proof'
# Evaluate the actual rendered remote program against a fixture extraction hook;
# no application is bootstrapped and no SSH service or production path is used.
real_tar=$(command -v tar)
cat >"$scratch/bin/tar" <<'SH'
#!/usr/bin/env bash
"$FIXTURE_REAL_TAR" "$@" || exit
if [[ $1 == -xf && $2 == - && $3 == -C ]]; then
    cat >"$4/recover-orphan-remote.sh" <<'FIXTURE'
#!/usr/bin/env bash
[[ $# == 12 && $1 == resume && $2 == app && $3 == selected-1 \
    && $4 == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    && $5 == orphan-0123456789abcdef0123456789abcdef \
    && $6 == $'storage\npublic/ohif' && $7 == /usr/bin/php && $8 == 256M \
    && $9 == https://example.test/up && ${10} == selected-maintenance-source-config \
    && ${11} == true && ${12} == orphan-verification.sh ]] || exit 2
echo 'orphan-recovery result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released'
FIXTURE
fi
SH
chmod +x "$scratch/bin/tar"
export FIXTURE_REAL_TAR="$real_tar"
args[5]=$'storage\npublic/ohif'
transport=remote-wrapper
run
args[5]=storage
rm "$scratch/bin/tar"
echo 'ok - actual quoted remote wrapper preserves all validated positional arguments including multiline persistence'
for transport in noisy nul timeout html; do
    if run; then echo "Invalid transport $transport passed" >&2; exit 1; fi
    if grep -Fq SECRET "$scratch/output"; then exit 1; fi
done
echo 'ok - noisy, NUL, HTML and timed-out SSH responses fail without exposing private diagnostics'
action="$here/../recover-orphan/action.yml"
validate=$(grep -nF 'name: Validate explicit orphan recovery before SSH' "$action" | cut -d: -f1)
configure=$(grep -nF 'name: Configure pinned recovery SSH' "$action" | cut -d: -f1)
execute=$(grep -nF 'name: Recover the exact orphaned selected release' "$action" | cut -d: -f1)
[[ $validate -lt $configure && $configure -lt $execute ]]
if grep -Eq 'recover-orphan|RECOVERY_TOKEN' "$here/../action.yml"; then exit 1; fi
grep -Fq 'required: true' "$action"
echo 'ok - separate explicit action validates before SSH and leaves ordinary deployment unchanged'
if [[ -f $here/assert-no-process-substitution.sh ]]; then
    bash "$here/assert-no-process-substitution.sh" "$here/recover-orphan-remote.sh"
fi
