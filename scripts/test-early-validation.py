#!/usr/bin/env python3
"""Run the actual composite's input, cron and install bodies without remote mutation."""
import ast
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
ACTION = (REPO / 'action.yml').read_text()
HOOKS = ('preflight-script', 'quiesce-script', 'pre-migrate-script', 'post-deploy-script',
         'pre-activate-script', 'post-activate-script', 'verification-script', 'post-finalize-script')


def steps():
    result = {}
    for block in re.split(r'(?=^    - (?:id|name):)', ACTION, flags=re.M):
        name = re.search(r'^\s+(?:- )?name: (.+)$', block, re.M)
        if not name:
            continue
        identity = re.search(r'^    - id: (.+)$', block, re.M)
        condition = re.search(r'^      if: (.+)$', block, re.M)
        environment = {}
        match = re.search(r'^      env:\n((?:^        .*\n|^          .*\n)+)', block, re.M)
        if match:
            key = None
            for line in match[1].splitlines():
                if line.startswith('          '):
                    environment[key] += ' ' + line.strip()
                else:
                    key, value = line.strip().split(': ', 1)
                    environment[key] = '' if value == '>-' else value
        match = re.search(r'^      run: (.*)\n', block, re.M)
        if not match:
            continue
        body = match[1]
        if body == '|':
            body = '\n'.join(line[8:] for line in block[match.end():].splitlines())
        result[name[1]] = dict(id=identity[1] if identity else name[1],
                               condition=condition[1] if condition else 'true', env=environment, body=body)
    return result


STEPS = steps()
RESOLVE = 'Resolve and validate inputs'
PREPARE = 'Render and validate managed cron before deployment'
# Use names from the checked-in YAML, including the compatibility install step.
INSTALL = tuple(name for name in STEPS if name.startswith('Install ') and 'cron lines' in name)
assert len(INSTALL) == 2
CLEAN = 'Remove the prepared cron artifact'
REF = re.compile(r'\b(?:inputs|steps|github)(?:\.[A-Za-z0-9_-]+)+')


def expression(value, context, success):
    value = value.replace('&&', ' and ').replace('||', ' or ')
    value = value.replace('always()', 'True').replace('success()', str(success))
    if value.strip() == 'true':
        return True
    return eval(REF.sub(lambda m: f'lookup({m[0]!r})', value), {'__builtins__': {}},
                {'lookup': lambda key: context.get(key, '')})


def render(value, context, success=True):
    return re.sub(r'\$\{\{\s*(.*?)\s*\}\}', lambda m: str(expression(m[1], context, success)), value)


def defaults():
    context = {'github.sha': 'a' * 40, 'github.run_id': '123', 'github.run_attempt': '1'}
    header = ACTION.split('\nruns:', 1)[0]
    for block in re.split(r'(?=^  [a-z][a-z0-9-]*:)', header, flags=re.M):
        name = re.match(r'^  ([a-z][a-z0-9-]*):', block)
        if not name:
            continue
        value = re.search(r'^    default: (.*)$', block, re.M)
        text = value[1] if value else ''
        if text.startswith(('"', "'")):
            text = ast.literal_eval(text)
        if text == '|':
            text = '\n'.join(line[6:] for line in block[value.end():].splitlines() if line.startswith('      '))
        context['inputs.' + name[1]] = text
    context['inputs.deploy-dir'] = 'app'
    return context


class Fixture:
    def __init__(self, root, changes):
        self.root = root
        self.context = defaults()
        self.context.update({'inputs.' + key: value for key, value in changes.items()})
        self.bin = root / 'bin'; self.bin.mkdir()
        self.home = root / 'home'; self.home.mkdir()
        self.remote = root / 'remote'; self.remote.mkdir()
        self.environment = dict(os.environ, HOME=str(self.home), RUNNER_TEMP=str(root),
                                GITHUB_ACTION_PATH=str(REPO), PATH=str(self.bin) + ':' + os.environ['PATH'],
                                SSH_RECEIPT=str(root / 'ssh.json'))
        (self.bin / 'ssh').write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
            'open(os.environ["SSH_RECEIPT"],"w").write(json.dumps(sys.argv[1:]))\n'
            'sys.stdin.read()\n')
        (self.bin / 'ssh').chmod(0o700)

    def execute(self, name, success=True):
        step = STEPS[name]
        condition = step['condition']
        allowed = expression(condition, self.context, success)
        if 'always()' not in condition and 'success()' not in condition:
            allowed = success and allowed
        if not allowed:
            self.context['steps.' + step['id'] + '.outcome'] = 'skipped'
            return None
        output = self.root / 'outputs'; output.write_text('')
        env = dict(self.environment, GITHUB_OUTPUT=str(output))
        env.update({key: render(value, self.context, success) for key, value in step['env'].items()})
        run = subprocess.run(['bash', '-c', render(step['body'], self.context, success)],
                             env=env, cwd=self.root, text=True, capture_output=True)
        for line in output.read_text().splitlines():
            key, value = line.split('=', 1)
            self.context['steps.' + step['id'] + '.outputs.' + key] = value
        self.context['steps.' + step['id'] + '.outcome'] = 'success' if run.returncode == 0 else 'failure'
        return run

    def preflight(self):
        resolve = self.execute(RESOLVE)
        prepare = self.execute(PREPARE, resolve.returncode == 0)
        return resolve, prepare


def reject(name, changes, stage):
    with tempfile.TemporaryDirectory(prefix='shared-early-') as temporary:
        f = Fixture(Path(temporary), changes)
        resolve, prepare = f.preflight()
        result = resolve if stage == 'resolve' else prepare
        assert result is not None and result.returncode == 2, (name, result)
        assert f.execute('Configure SSH', success=False) is None
        assert f.execute('Start the remote atomic transaction', success=False) is None
        assert f.execute('Recover, unlock and report the atomic deployment', success=False) is None
        f.execute(CLEAN, success=False)
        assert not (f.root / 'ssh.json').exists(), name
        assert not list(f.root.glob('shared-deploy-cron.*')), name
        assert not list(f.remote.iterdir()), name
        assert not list(f.home.iterdir()), name
    print('ok - ' + name + ': rejected before SSH/transaction')


def accepted(name, changes, expect_cron=True):
    with tempfile.TemporaryDirectory(prefix='shared-early-') as temporary:
        f = Fixture(Path(temporary), changes)
        resolve, prepare = f.preflight()
        assert resolve.returncode == 0, (name, resolve.stderr)
        if expect_cron:
            assert prepare and prepare.returncode == 0, (name, prepare.stderr if prepare else '')
            artifact = Path(f.context['steps.prepared-cron.outputs.file'])
            assert artifact.stat().st_mode & 0o777 == 0o600
        else:
            assert prepare is None
        f.execute(CLEAN)
        assert not list(f.root.glob('shared-deploy-cron.*'))
    print('ok - ' + name)


for hook in HOOKS:
    reject('missing ' + hook, {hook: 'does-not-exist.sh'}, 'resolve')
    reject('directory ' + hook, {hook: '/tmp'}, 'resolve')
for enabled in ('operational-audit', 'runtime-audit'):
    reject(enabled + ' unlimited memory', {enabled: 'true', 'artisan-memory-limit': '-1'}, 'resolve')
for value in ('8589934592G', '8796093022208m', '9007199254740992K', '18446744073709551616G', '9' * 4096 + 'M'):
    reject('overflow memory ' + value[:24], {'artisan-memory-limit': value}, 'resolve')
reject('invalid cron memory', {'cron-memory-limit': 'unlimited'}, 'cron')
reject('invalid scheduler log', {'scheduler-log': '/outside'}, 'cron')
reject('wrong Artisan binary', {'cron-lines': '* * * * * cd "$HOME/app" && php artisan schedule:run # JOB:test'}, 'cron')
reject('wrong cron directory', {'cron-lines': '* * * * * cd "$HOME/other" && true # JOB:test'}, 'cron')
reject('missing cron job id', {'cron-lines': '* * * * * cd "$HOME/app" && true'}, 'cron')
# These tests deliberately use app to make directory validation meaningful.
for mode in ('atomic', 'in-place'):
    accepted(mode + ' default rendering', {'deploy-dir': 'app', 'deployment-mode': mode})
accepted('option-shaped existing application name remains valid', {'deploy-dir': '--validate-only'})
accepted('all configured readable hooks', {'deploy-dir': 'app', **{hook: str(REPO / 'scripts/test-action-contract.sh') for hook in HOOKS}})
accepted('audits disabled preserve unlimited Artisan setting', {'deploy-dir': 'app', 'artisan-memory-limit': '-1'})
accepted('disabled cron ignores unused malformed configuration', {'deploy-dir': 'app', 'install-cron': 'false',
         'cron-memory-limit': 'bad', 'scheduler-log': '/outside', 'cron-lines': 'bad'}, expect_cron=False)
for value in ('8589934591G', '8796093022207m', '9007199254740991K', '1k', '256M'):
    accepted('finite boundary ' + value, {'deploy-dir': 'app', 'operational-audit': 'true', 'artisan-memory-limit': value})

# Both installation bodies must consume the identical prevalidated bytes, even
# when the original inputs change later. A changed artifact must never reach SSH.
for name in INSTALL:
    with tempfile.TemporaryDirectory(prefix='shared-early-') as temporary:
        mode = 'atomic' if 'atomic' in name else 'in-place'
        f = Fixture(Path(temporary), {'deploy-dir': 'app', 'deployment-mode': mode})
        resolve, prepare = f.preflight()
        assert resolve.returncode == prepare.returncode == 0
        artifact = Path(f.context['steps.prepared-cron.outputs.file'])
        original = artifact.read_text().splitlines()
        f.context['steps.ssh.outputs.target'] = 'fixture'
        f.context['inputs.cron-lines'] = 'invalid changed inputs'
        f.context['inputs.cron-memory-limit'] = 'bad'
        assert f.execute(name).returncode == 0
        args = json.loads((f.root / 'ssh.json').read_text())
        assert shlex.split(args[-1])[3:] == ['app'] + original
        (f.root / 'ssh.json').unlink()
        artifact.write_text(artifact.read_text() + 'tampered\n')
        assert f.execute(name).returncode == 2
        assert not (f.root / 'ssh.json').exists()
        f.execute(CLEAN, success=False)
        assert not artifact.exists()
    print('ok - ' + name + ': validated bytes reused; tampering rejected')

# Host entry point receives arbitrary direct inputs: invalid finite sizes must
# fail before any PHP invocation, without relying on runner-side validation.
with tempfile.TemporaryDirectory(prefix='shared-memory-host-') as temporary:
    root = Path(temporary)
    (root / 'app/vendor').mkdir(parents=True)
    (root / 'app/bootstrap').mkdir()
    (root / 'app/vendor/autoload.php').touch(); (root / 'app/bootstrap/app.php').touch()
    php = root / 'php'
    php.write_text('#!/usr/bin/env bash\nprintf called >>"$HOME/php-called"\nexit 1\n'); php.chmod(0o700)
    for value in ('8589934592G', '8796093022208M', '9007199254740992k', '9' * 4096 + 'M'):
        run = subprocess.run(['bash', str(REPO / 'scripts/operational-audit.sh'), 'app', str(php), value],
                             env=dict(os.environ, HOME=str(root)), capture_output=True)
        assert run.returncode == 2 and not (root / 'php-called').exists()
    for value in ('8589934591G', '8796093022207m', '9007199254740991K'):
        run = subprocess.run(['bash', str(REPO / 'scripts/operational-audit.sh'), 'app', str(php), value],
                             env=dict(os.environ, HOME=str(root)), capture_output=True)
        assert run.returncode == 1 and (root / 'php-called').exists(), (value, run.stderr)
        (root / 'php-called').unlink()
print('ok - host audit enforces finite byte ceiling before PHP; boundaries reach PHP')

assert ACTION.index('name: Render and validate managed cron') < ACTION.index('name: Configure SSH') < ACTION.index('name: Start the remote atomic transaction')
print('Early validation composite fixtures passed.')
