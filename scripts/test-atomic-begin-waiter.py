#!/usr/bin/env python3
"""Coordinate actual competing initializers at cleanup failure boundaries."""
import atexit
import hashlib
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time

source = Path(__file__).resolve().with_name('atomic-release.sh')
snapshot = source.read_bytes()
digest = hashlib.sha256(snapshot).hexdigest()
root = Path(tempfile.mkdtemp(prefix='atomic-waiter-test-'))
atexit.register(shutil.rmtree, root, ignore_errors=True)
script = root / 'atomic-release.sh'
script.write_bytes(snapshot)
commit = '0123456789abcdef0123456789abcdef01234567'
hooks = root / 'hooks.sh'
hooks.write_text(r'''await_file() {
    local tries=0
    while [[ ! -e $1 ]]; do
        (( tries < 3000 )) || return 98
        tries=$((tries+1))
        /usr/bin/sleep 0.01
    done
}
mktemp() {
    if [[ $ROLE == old && ${!#} == "$HOME/.deployments/app/.generation.XXXXXX" ]]; then
        builtin printf ready >"$REVIEW_ROOT/old-ready"
        await_file "$REVIEW_ROOT/allow-old" || return
    fi
    /usr/bin/mktemp "$@"
}
mv() {
    local source=${@: -2:1} destination=${!#}
    if [[ $ROLE == old && $destination == ./phase ]]; then
        builtin printf fault >"$REVIEW_ROOT/old-fault"
        return 91
    fi
    if [[ $ROLE == waiter && $destination == "$HOME/.deployments/app/deploy.lock" && $source == */.begin-cleanup-acquire.* ]]; then
        builtin printf '%s\n' "$source" >"$REVIEW_ROOT/waiter-source"
        builtin printf ready >"$REVIEW_ROOT/waiter-ready"
        await_file "$REVIEW_ROOT/allow-waiter" || return
        local result=0
        /usr/bin/mv "$@" || result=$?
        # Coreutils versions differ on the status of a no-clobber skip.
        # Exercise both conventions while keeping the real rename behavior.
        if [[ -d $source && -d $destination ]]; then
            return "$REVIEW_SKIP_STATUS"
        fi
        (( result == 0 )) || return "$result"
        if [[ $REVIEW_CASE == lock ]]; then
            builtin printf published >"$REVIEW_ROOT/waiter-published"
            await_file "$REVIEW_ROOT/old-finished" || return
        fi
        return 0
    fi
    /usr/bin/mv "$@"
}
rmdir() {
    if [[ $ROLE == old && $REVIEW_CASE == child && ${!#} == */.begin-cleanup-*-candidate ]]; then
        builtin printf failed >"$REVIEW_ROOT/old-child-failed"
        return 92
    fi
    /usr/bin/rmdir "$@"
}
rm() {
    if [[ $ROLE == old && $REVIEW_CASE == transaction && $PWD == */.begin-cleanup-*-transaction ]]; then
        builtin printf failed >"$REVIEW_ROOT/old-child-failed"
        return 94
    fi
    if [[ $ROLE == old && $REVIEW_CASE == lock && $PWD == */.begin-cleanup-*-lock ]]; then
        builtin printf detached >"$REVIEW_ROOT/old-lock-detached"
        builtin printf go >"$REVIEW_ROOT/allow-waiter"
        await_file "$REVIEW_ROOT/waiter-published" || return
        return 93
    fi
    /usr/bin/rm "$@"
}
''')

def await_file(path):
    deadline = time.monotonic() + 30
    while not path.exists():
        if time.monotonic() > deadline:
            raise AssertionError('Missing coordination event: ' + str(path))
        time.sleep(.01)

for case, skip_status in [(case, status) for status in (0, 1) for case in ('child', 'transaction', 'lock')]:
    fixture = root / f'{case}-skip{skip_status}'
    app = fixture / 'home/app'
    (app / 'storage').mkdir(parents=True)
    (app / 'artisan').write_text('<?php\n')
    (app / '.deploy-release').write_text('release=prior\ncommit=' + commit + '\n')
    (app / 'storage/preserved').write_text('patient data\n')
    (fixture / 'crontab').write_text('foreign cron\n')
    control = fixture / 'home/.deployments/app'
    env = dict(os.environ, HOME=str(fixture/'home'), BASH_ENV=str(hooks), REVIEW_ROOT=str(fixture), REVIEW_CASE=case, REVIEW_SKIP_STATUS=str(skip_status))
    args = ['bash',str(script),'begin','app','old',commit,'7200','3','maintenance',commit,'stable-directory','storage']
    logs = []
    processes = []
    try:
        oldlog = open(fixture/'old.log','wb'); logs.append(oldlog)
        old = subprocess.Popen(args,env=dict(env,ROLE='old'),stdout=oldlog,stderr=subprocess.STDOUT,start_new_session=True)
        processes.append(old)
        await_file(fixture/'old-ready')
        original_lock = (control/'deploy.lock').stat().st_ino
        assert (control/'deploy.lock/owner').read_text() == 'old\n'
        waiterlog = open(fixture/'waiter.log','wb'); logs.append(waiterlog)
        args[4] = 'waiter'
        waiter = subprocess.Popen(args,env=dict(env,ROLE='waiter'),stdout=waiterlog,stderr=subprocess.STDOUT,start_new_session=True)
        processes.append(waiter)
        await_file(fixture/'waiter-ready')
        waiter_source = Path((fixture/'waiter-source').read_text().strip())
        assert waiter_source.is_dir()
        assert (control/'deploy.lock').stat().st_ino == original_lock
        assert (control/'deploy.lock/owner').read_text() == 'old\n'
        (fixture/'allow-old').touch()
        assert old.wait(timeout=30) != 0
        (fixture/'old-finished').touch()
        if case != 'lock':
            assert (fixture/'old-child-failed').exists()
            assert (control/'deploy.lock').stat().st_ino == original_lock
            assert (control/'deploy.lock/owner').read_text() == 'old\n'
            (fixture/'allow-waiter').touch()
        else:
            assert (fixture/'old-lock-detached').exists()
            assert (fixture/'waiter-published').exists()
        assert waiter.wait(timeout=30) != 0
        waiter_text = (fixture/'waiter.log').read_text()
        assert not waiter_source.exists()
        assert not (control/'releases/waiter').exists()
        assert not (control/'state/waiter').exists()
        assert (control/'generation').read_text() == 'old\n'
        if case != 'lock':
            assert (control/'deploy.lock').stat().st_ino == original_lock
            assert (control/'deploy.lock/owner').read_text() == 'old\n'
        else:
            assert 'Initialization evidence appeared before lock publication' in waiter_text
            retained = list(control.glob('.begin-cleanup-*-lock'))
            assert len(retained) == 1
            assert retained[0].stat().st_ino == original_lock
            assert (retained[0]/'owner').read_text() == 'old\n'
            assert not (control/'deploy.lock').exists()
            retry = args.copy()
            retry[4] = 'retry'
            result = subprocess.run(retry,env=dict(env,ROLE='retry'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
            assert result.returncode != 0
            assert b'Uncertain initialization evidence requires deliberate recovery' in result.stdout
            assert not (control/'deploy.lock').exists()
            assert not (control/'releases/retry').exists()
            assert not (control/'state/retry').exists()
        assert (app/'storage/preserved').read_text() == 'patient data\n'
        assert (fixture/'crontab').read_text() == 'foreign cron\n'
        print('PASS', case, f'- no-clobber skip status {skip_status}; no new initialization', flush=True)
    except BaseException:
        for name in ('old.log', 'waiter.log'):
            path = fixture/name
            if path.exists():
                print(f'{case}/skip{skip_status} {name}:\n{path.read_text()}', flush=True)
        raise
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for log in logs:
            log.close()
print('Snapshot SHA256', digest, flush=True)
print('Three coordinated cleanup/waiter cases passed with both no-clobber exit conventions (six runs).', flush=True)
