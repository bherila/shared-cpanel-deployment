#!/usr/bin/env bash
# Filesystem/state-machine tests use real PHP; only Laravel/HTTP/cron are stubs.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
php=$(command -v php)
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
token=orphan-0123456789abcdef0123456789abcdef
checks=0
setup() {
    root=$(mktemp -d "$scratch/case.XXXXXX")
    task_home="$root/home" stable="$root/home/app" control="$root/home/.deployments/app"
    bundle="$root/bundle"
    mkdir -p "$stable"/{bootstrap/cache,vendor,public} "$control"/{releases,state} \
        "$control/shared/storage"/{framework/cache,app} "$bundle" "$root/bin"
    ln -s "$control/shared/storage" "$stable/storage"
    printf 'release=selected-1\ncommit=%s\n' "$commit" >"$stable/.deploy-release"
    printf 'APP_KEY=fixture\n' >"$stable/.env"
    printf '<?php\n' >"$stable/vendor/autoload.php"
    printf '<?php\n' >"$stable/bootstrap/app.php"
    printf '<?php\n' >"$stable/artisan"
    printf '{"status":503,"secret":"private-marker"}\n' >"$stable/storage/framework/down"
    chmod 640 "$stable/storage/framework/down"
    printf '<?php echo "private-rendered";' >"$stable/storage/framework/maintenance.php"
    chmod 600 "$stable/storage/framework/maintenance.php"
    cp -p "$stable/storage/framework/down" "$root/original-down"
    cp -p "$stable/storage/framework/maintenance.php" "$root/original-rendered"
    printf 'patient-data\n' >"$stable/storage/app/patients"
    cp "$stable/.env" "$root/original-env"
    printf '* * * * * cd "$HOME/foreign" && php artisan schedule:run # JOB:foreign-scheduler\n' >"$root/cron"
    cp "$root/cron" "$root/original-cron"
    cp "$here"/{recover-orphan-remote.sh,recover-orphan-state.php,validate-recover-orphan-inputs.sh} "$bundle/"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/orphan-verification.sh"
    cat >"$bundle/recover-orphan-framework.php" <<'PHP'
<?php
require __DIR__.'/recover-orphan-state.php';
[, $mode, $app, $release, $commit, $token, $paths] = $argv;
$state = new OrphanRecoveryState($app, $release, $commit, $token, $paths);
if ($mode === 'preflight') {
    $state->owned('present');
    file_put_contents(getenv('FIXTURE_ROOT').'/framework-owned', 'yes');
    if (getenv('CASE_FAILURE') === 'preflight') { exit(1); }
    if (getenv('CASE_FAILURE') === 'preflight-marker') {
        $path=$state->storage.'/framework/down'; $stat=stat($path); copy($path,$path.'.new'); chmod($path.'.new',$stat['mode']&0777); touch($path.'.new',$stat['mtime']); rename($path.'.new',$path);
    }
}
else { $state->owned($mode === 'prove-up' ? 'absent' : 'present'); }
if ($mode === 'prepare') {
    if (getenv('CASE_FAILURE') === 'cache') { exit(1); }
    mkdir($state->record.'/framework', 0700);
    file_put_contents($state->stable.'/bootstrap/cache/config.php', '<?php return [];');
    $state->phase('prepared-cache');
    if (getenv('CASE_FAILURE') === 'term-cache') { posix_kill((int) getenv('FIXTURE_OWNER_PID'), SIGTERM); exit(1); }
    if (getenv('CASE_FAILURE') === 'byte-marker') {
        $path=$state->storage.'/framework/down'; $stat=stat($path); copy($path,$path.'.new'); chmod($path.'.new',$stat['mode']&0777); touch($path.'.new',$stat['mtime']); rename($path.'.new',$path);
    }
}
if ($mode === 'up') {
    unlink($state->storage.'/framework/down');
    unlink($state->storage.'/framework/maintenance.php');
    if (getenv('CASE_FAILURE') === 'up') { exit(1); }
    if (getenv('CASE_FAILURE') === 'term-up') { posix_kill((int) getenv('FIXTURE_OWNER_PID'), SIGTERM); exit(1); }
    if (getenv('CASE_FAILURE') === 'kill-up') { posix_kill((int) getenv('FIXTURE_OWNER_PID'), SIGKILL); exit(1); }
}
echo 'orphan-recovery framework='.(in_array($mode,['up','prove-up']) ? 'serving' : 'maintenance')."\n";
PHP
    cat >"$bundle/operational-audit.sh" <<'SH'
#!/usr/bin/env bash
[[ ${CASE_FAILURE:-} != audit ]] || exit 1
echo 'runtime-audit identity=exact paths=canonical writable=yes database=persistent phase=selected'
echo 'operational-audit pending_migrations=0 queue_driver=sync queue_applicability=no-persistent-queue pending_total=not-counted failed_applicability=disabled failed_total=not-counted'
SH
    cat >"$root/bin/crontab" <<'SH'
#!/usr/bin/env bash
[[ $1 == -l ]] || exit 99
[[ ${CASE_FAILURE:-} != cron-read ]] || { echo 'private cron failure' >&2; exit 2; }
cat "$FIXTURE_ROOT/cron"
SH
    cat >"$root/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ ${CASE_FAILURE:-} == health ]]; then printf 503; else printf 200; fi
SH
    chmod +x "$root/bin/"*
    failure=''
}
run() {
    local verifier=orphan-verification.sh
    [[ ${1:-resume} != restore ]] || verifier=-
    env HOME="$task_home" FIXTURE_ROOT="$root" CASE_FAILURE="$failure" PATH="$root/bin:$PATH" \
        bash -c 'export FIXTURE_OWNER_PID=$$; exec bash "$@"' sh "$bundle/recover-orphan-remote.sh" \
        "${1:-resume}" app selected-1 "$commit" "$token" storage "$php" 256M \
        https://example.test/up selected-maintenance-source-config true "$verifier" >"$root/output" 2>&1
}
state() {
    if [[ $1 == initialize ]]; then
        env HOME="$task_home" "$php" "$bundle/recover-orphan-state.php" inspect app selected-1 "$commit" "$token" storage "$bundle/preflight-record.json" >/dev/null
    fi
    env HOME="$task_home" "$php" "$bundle/recover-orphan-state.php" "$1" app selected-1 "$commit" "$token" storage "$bundle/preflight-record.json" >"$root/state-output" 2>&1
}
preserved() {
    cmp -s "$stable/.env" "$root/original-env" && cmp -s "$root/cron" "$root/original-cron" \
        && [[ $(cat "$stable/storage/app/patients") == patient-data ]] \
        && ! grep -Eq 'private-|patient-data|APP_KEY|private cron failure' "$root/output"
}
restored() {
    cmp -s "$stable/storage/framework/down" "$root/original-down" \
        && cmp -s "$stable/storage/framework/maintenance.php" "$root/original-rendered" \
        && [[ $(stat -c %a "$stable/storage/framework/down") == 640 ]] \
        && [[ $(stat -c %a "$stable/storage/framework/maintenance.php") == 600 ]] \
        && [[ ! -e $control/deploy.lock ]] && preserved
}
pass() { checks=$((checks + 1)); printf 'ok - %s\n' "$1"; }
reject() { if run; then echo 'Unexpected recovery success' >&2; exit 1; fi; }
setup
run
grep -Fq 'result=serving identity=exact runtime=valid pending_migrations=0 cron=paused lock=released' "$root/output"
[[ ! -e $stable/storage/framework/down && ! -e $control/deploy.lock ]]
preserved
pass 'successful exact recovery leaves app cron paused and foreign/patient/environment data unchanged'
for failure_case in preflight cache audit up health cron-read term-up term-cache; do
    setup; failure=$failure_case
    reject
    restored
    pass "failure at $failure_case restores exact markers/modes without bootstrap and releases owned lock"
done
setup
state inspect
mkdir "$control/deploy.lock"; printf 'competing-deployment\n' >"$control/deploy.lock/owner"
if env HOME="$task_home" "$php" "$bundle/recover-orphan-state.php" initialize app selected-1 "$commit" "$token" storage "$bundle/preflight-record.json" >"$root/state-output" 2>&1; then exit 1; fi
[[ ! -e $root/framework-owned && $(cat "$control/deploy.lock/owner") == competing-deployment ]]
pass 'a competing deployment after filesystem preflight prevents every provider bootstrap'
for mutation in metadata marker state alias unsafe uncertainty releases-uncertainty; do
    setup
    case $mutation in
        metadata) printf 'release=selected-1\nrelease=foreign\ncommit=%s\n' "$commit" >"$stable/.deploy-release" ;;
        marker) printf '{"bad":true}' >"$stable/storage/framework/down" ;;
        state) touch "$control/state/foreign" ;;
        alias) mv "$control/shared/storage/framework" "$control/shared/storage/real-framework"; ln -s real-framework "$control/shared/storage/framework" ;;
        unsafe) mkdir -p "$control/shared/public/build/assets" "$stable/public/build"; ln -s "$control/shared/public/build/assets" "$stable/public/build/assets" ;;
        uncertainty) mkdir "$control/.begin-cleanup-foreign-1-candidate" ;;
        releases-uncertainty) mkdir "$control/releases/.begin-cleanup-foreign-1-candidate" ;;
    esac
    if [[ $mutation == unsafe ]]; then
        if env HOME="$task_home" "$php" "$bundle/recover-orphan-state.php" inspect app selected-1 "$commit" "$token" $'storage\npublic/build/assets' >"$root/output" 2>&1; then exit 1; fi
    else reject; fi
    [[ ! -e $control/deploy.lock && ! -e $control/recovery/$token ]]
    pass "ambiguous $mutation is refused before acquiring a lock"
done
for ownership in '"$HOME/app"' '"${HOME}/app"' '"$HOME"/app' '"${HOME}"/app'; do
    setup
    printf '* * * * * cd %s && php artisan schedule:run\n' "$ownership" >>"$root/cron"
    reject
    [[ ! -e $control/deploy.lock ]]
    pass "active application cron $ownership refuses recovery before mutation"
done
setup; failure=preflight-marker
original_inode=$(stat -c %i "$stable/storage/framework/down")
reject
[[ -d $control/deploy.lock && $(stat -c %i "$stable/storage/framework/down") != "$original_inode" ]]
pass 'byte-identical operator marker during owned preflight retains the lock'
setup; failure=byte-marker
reject
[[ -d $control/deploy.lock && -f $stable/storage/framework/down ]]
grep -Fq 'lock=retained' "$root/output"
pass 'byte-identical newer operator marker after acquisition refuses up and retains evidence'
setup
mkdir "$control/deploy.lock"; printf 'foreign\n' >"$control/deploy.lock/owner"
reject
[[ $(cat "$control/deploy.lock/owner") == foreign ]]
pass 'foreign lock is untouched'
for injection in verification term-verification replacement owner identity storage marker; do
    setup
    cat >"$bundle/orphan-verification.sh" <<'SH'
#!/usr/bin/env bash
case $CASE_FAILURE in
    verification) touch "$1/storage/app/bootstrap-broken" ;;
    term-verification) kill -TERM "$FIXTURE_OWNER_PID" ;;
    replacement) mv "$HOME/.deployments/app/deploy.lock" "$HOME/.deployments/app/original-lock"; mkdir "$HOME/.deployments/app/deploy.lock"; printf 'foreign\n' >"$HOME/.deployments/app/deploy.lock/owner" ;;
    owner) printf 'foreign\n' >"$HOME/.deployments/app/deploy.lock/owner" ;;
    identity) printf 'release=foreign\n' >"$1/.deploy-release" ;;
    storage) mv "$HOME/.deployments/app/shared/storage" "$HOME/.deployments/app/shared/original-storage"; mkdir -p "$HOME/.deployments/app/shared/storage/framework" ;;
    marker) printf '{"status":502}' >"$1/storage/framework/down" ;;
esac
exit 1
SH
    failure=$injection
    reject
    if [[ $injection == verification || $injection == term-verification ]]; then restored
    else [[ -d $control/deploy.lock ]]; grep -Fq 'lock=retained' "$root/output"; fi
    pass "verification $injection restores only provable ownership, retaining ambiguous locks"
done
setup; failure=kill-up
reject
[[ ! -e $stable/storage/framework/down && -d $control/deploy.lock ]]
failure=''
run restore
restored
pass 'SIGKILL after up requires explicit token restore and exact direct marker restoration'
setup
env HOME="$task_home" "$php" -r '
    $framework=getenv("HOME")."/app/storage/framework";
    file_put_contents($framework."/down",json_encode(["status"=>503,"padding"=>str_repeat("x",30000)]));
    file_put_contents($framework."/maintenance.php","<?php /*".str_repeat("x",32750)."*/");
'
cp "$stable/storage/framework/down" "$root/original-down"
cp "$stable/storage/framework/maintenance.php" "$root/original-rendered"
failure=health
reject
restored
pass 'large valid original marker payloads retain readable bounded proof throughout exact restoration'
for interruption in intent created inode partial foreign; do
    setup
    state initialize
    env HOME="$task_home" "$php" -r '
        $control=getenv("HOME")."/.deployments/app";
        $path=$control."/recovery/".$argv[1]."/record.json";
        $d=json_decode(file_get_contents($path),true);
        $marker=$control."/shared/storage/framework/down"; unlink($marker);
        $temporary=dirname($marker)."/.orphan-restore-".str_repeat("b",32);
        $d["phase"]="restoring"; $d["pendingTemporary"]["down"]=basename($temporary);
        if ($argv[2]!=="intent") {
            file_put_contents($temporary,""); chmod($temporary,0600); $s=stat($temporary);
            if ($argv[2]!=="created") { $d["temporaryIds"]["down"]=[$s["dev"],$s["ino"]]; }
            if ($argv[2]==="partial") { file_put_contents($temporary,substr(base64_decode($d["down"]["bytes"]),0,5)); }
            if ($argv[2]==="foreign") {
                rename($temporary,$temporary.".original"); file_put_contents($temporary,"foreign-payload"); chmod($temporary,0600);
            }
        }
        file_put_contents($path,json_encode($d));
    ' "$token" "$interruption"
    if [[ $interruption == created || $interruption == foreign ]]; then
        if run restore; then exit 1; fi
        [[ -d $control/deploy.lock && ! -e $stable/storage/framework/down ]]
        temporary="$stable/storage/framework/.orphan-restore-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        if [[ $interruption == created ]]; then [[ ! -s $temporary && $(stat -c %a "$temporary") == 600 ]]
        else [[ $(cat "$temporary") == foreign-payload ]]; fi
    else
        run restore
        restored
        [[ ! -e $stable/storage/framework/.orphan-restore-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
    fi
    pass "restore creation interruption at $interruption preserves exact durable intent and inode ownership"
done
setup
state initialize
env HOME="$task_home" "$php" -r '
    $p=getenv("HOME")."/.deployments/app/recovery/".$argv[1]."/record.json";
    $d=json_decode(file_get_contents($p),true); $d["phase"]="restored";
    $d["pendingTemporary"]["down"]=".orphan-restore-".str_repeat("c",32);
    file_put_contents($p,json_encode($d));
' "$token"
if state release-down; then exit 1; fi
[[ $(cat "$control/deploy.lock/owner") == "$token" ]]
pass 'even restored maintenance cannot release ownership with unfinished temporary intent'
for interruption in planned linked unlinked; do
    setup
    state initialize
    # Reconstruct the exact durable records/files at each publication boundary,
    # without adding interruption hooks to the production filesystem helper.
    env HOME="$task_home" "$php" -r '
        $control=getenv("HOME")."/.deployments/app";
        $path=$control."/recovery/".$argv[1]."/record.json";
        $d=json_decode(file_get_contents($path),true);
        $marker=$control."/shared/storage/framework/down";
        unlink($marker);
        $temporary=dirname($marker)."/.orphan-restore-".str_repeat("a",32);
        file_put_contents($temporary,base64_decode($d["down"]["bytes"]));
        chmod($temporary,$d["down"]["mode"]); touch($temporary,$d["down"]["mtime"]);
        $s=stat($temporary);
        $d["phase"]="restoring";
        $d["pendingMarkers"]["down"]=array_replace($d["down"],["id"=>[$s["dev"],$s["ino"]]]);
        $d["pendingTemporary"]["down"]=basename($temporary);
        file_put_contents($path,json_encode($d));
        if ($argv[2]!=="planned") { link($temporary,$marker); }
        if ($argv[2]==="unlinked") { unlink($temporary); }
    ' "$token" "$interruption"
    run restore
    restored
    [[ ! -e $stable/storage/framework/.orphan-restore-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
    pass "interrupted marker publication at $interruption resumes only its persisted exact inode"
done
setup
state initialize
rm "$control/deploy.lock/owner"
env HOME="$task_home" "$php" -r '$p=getenv("HOME")."/.deployments/app/recovery/".$argv[1]."/record.json"; $d=json_decode(file_get_contents($p),true); $d["phase"]="acquired"; file_put_contents($p,json_encode($d));' "$token"
run restore
restored
pass 'persisted exact inode permits restoring known empty partial initialization'
setup
state initialize
printf 'partial' >"$control/deploy.lock/owner"
if run restore; then exit 1; fi
[[ $(cat "$control/deploy.lock/owner") == partial ]]
pass 'partial owner bytes are ambiguous and never adopted'
setup
state initialize
env HOME="$task_home" "$php" -r '$p=getenv("HOME")."/.deployments/app/recovery/".$argv[1]."/record.json"; $d=json_decode(file_get_contents($p),true); $d["phase"]="prepared"; $d["lock"]=null; file_put_contents($p,json_encode($d));' "$token"
rm "$control/deploy.lock/owner"
if run restore; then exit 1; fi
[[ -d $control/deploy.lock && ! -e $control/deploy.lock/owner ]]
pass 'unpersisted inode initialization window retains its uncertain lock'
echo "orphan recovery checks: $checks"
