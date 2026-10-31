#!/usr/bin/env python3
"""Contract and behaviour checks for the tooling and configure-ssh sub-actions.

Runs the actual `run:` bodies from the checked-in YAML under a fake HOME; nothing connects to SSH.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
TOOLING = REPO / 'tooling' / 'action.yml'
CONFIGURE = REPO / 'configure-ssh' / 'action.yml'
MAIN = REPO / 'action.yml'
KEY = '-----BEGIN FAKE KEY-----\nabc123secretmaterial\n-----END FAKE KEY-----'
KNOWN = 'example.test ssh-ed25519 AAAAFAKEHOSTKEY'
INPUTS = {'alias': 'pilot-deploy', 'host': 'example.test', 'username': 'cpuser',
          'private-key': KEY, 'known-hosts': KNOWN}
fails = 0


def check(name, ok):
    global fails
    print(('ok   - ' if ok else 'FAIL - ') + name)
    fails += 0 if ok else 1


def step(path, step_id):
    """Return (env, run body) of the step with `id: step_id`."""
    text = path.read_text()
    block = re.search(r'^    - id: %s\n((?:^      .*\n|^\n)+)' % re.escape(step_id), text, re.M)
    assert block, f'{path}: no step {step_id}'
    body = block[1]
    env = {}
    match = re.search(r'^      env:\n((?:^        .*\n)+)', body, re.M)
    if match:
        for line in match[1].splitlines():
            key, value = line.strip().split(': ', 1)
            env[key] = value
    run = re.search(r'^      run: \|\n((?:^        .*\n|^\n)+)', body, re.M)
    if run:
        script = '\n'.join(line[8:] for line in run[1].splitlines()) + '\n'
    else:
        script = re.search(r'^      run: (.+)\n', body, re.M)[1]
    return env, script


def resolve(env, inputs):
    out = {}
    for key, value in env.items():
        match = re.fullmatch(r'\$\{\{ inputs\.([A-Za-z0-9-]+) \}\}', value)
        assert match, f'{key}: unexpected expression {value}'
        out[key] = inputs[match[1]]
    return out


def run_step(path, step_id, action_dir, home, inputs=None, extra_env=None):
    """Run a step the way the runner does: env from inputs, GITHUB_ACTION_PATH, GITHUB_OUTPUT."""
    env, script = step(path, step_id)
    output = Path(home) / 'github_output'
    output.touch()
    environment = {'PATH': os.environ['PATH'], 'HOME': str(home), 'GITHUB_ACTION_PATH': str(action_dir),
                   'GITHUB_OUTPUT': str(output)}
    environment.update(resolve(env, inputs or {}))
    environment.update(extra_env or {})
    result = subprocess.run(['bash', '-c', script], env=environment, capture_output=True, text=True)
    outputs = dict(line.split('=', 1) for line in output.read_text().splitlines() if '=' in line)
    return result, outputs


with tempfile.TemporaryDirectory(prefix='subactions.') as scratch:
    scratch = Path(scratch)

    def fresh_home(name):
        home = scratch / name
        home.mkdir()
        return home

    # Static contract.
    for label, path in (('tooling', TOOLING), ('configure-ssh', CONFIGURE)):
        text = path.read_text()
        check(f'{label} sub-action file exists', path.is_file())
        check(f'{label} is a composite action', re.search(r'^  using: composite$', text, re.M) is not None)
        runs = re.findall(r'^      run: .*(?:\n(?:        .*|))*', text, re.M)
        check(f'{label} never interpolates inputs into a run block', runs and not any('${{' in r for r in runs))
    configure_env, _ = step(CONFIGURE, 'ssh')
    declared = re.findall(r'^  ([a-z-]+):$', CONFIGURE.read_text().split('outputs:')[0].split('inputs:')[1], re.M)
    check('configure-ssh passes every input through env', sorted(declared) == sorted(
        re.fullmatch(r'\$\{\{ inputs\.([a-z-]+) \}\}', v)[1] for v in configure_env.values()))
    main_env, main_run = step(MAIN, 'ssh')
    check('configure-ssh maps the same script variables as the main action', set(configure_env) == set(main_env))
    check('configure-ssh runs the script the main action runs',
          main_run.strip().endswith('scripts/configure-ssh.sh"') and 'configure-ssh.sh' in step(CONFIGURE, 'ssh')[1])
    check('every required input is required', all(
        re.search(r'^  %s:\n    description: .*\n    required: true$' % n, CONFIGURE.read_text(), re.M) for n in declared))

    # tooling resolves the root and fails closed.
    home = fresh_home('tooling-home')
    result, outputs = run_step(TOOLING, 'locate', REPO / 'tooling', home)
    check('tooling resolves the repository root', result.returncode == 0 and outputs.get('path') == str(REPO.resolve()))
    root = Path(outputs.get('path', '/nonexistent'))
    check('tooling root contains action.yml and scripts/configure-ssh.sh',
          (root / 'action.yml').is_file() and (root / 'scripts' / 'configure-ssh.sh').is_file())
    for missing in ('action.yml', 'scripts'):
        fake = scratch / f'no-{missing}'
        shutil.copytree(REPO / 'tooling', fake / 'tooling')
        (fake / 'scripts').mkdir()
        (fake / 'scripts' / 'configure-ssh.sh').write_text('#\n')
        (fake / 'action.yml').write_text('name: x\n')
        if missing == 'action.yml':
            (fake / 'action.yml').unlink()
        else:
            shutil.rmtree(fake / 'scripts')
        result, outputs = run_step(TOOLING, 'locate', fake / 'tooling', fresh_home(f'h-{missing}'))
        check(f'tooling fails closed without {missing}', result.returncode != 0 and 'path' not in outputs)
    # A symlinked action directory still reports the physical root.
    link = scratch / 'link'
    link.symlink_to(REPO)
    result, outputs = run_step(TOOLING, 'locate', link / 'tooling', fresh_home('h-link'))
    check('tooling reports the physical path through a symlink', outputs.get('path') == str(REPO.resolve()))

    # configure-ssh resolves the script and writes the expected config.
    home = fresh_home('cfg-home')
    result, outputs = run_step(CONFIGURE, 'ssh', REPO / 'configure-ssh', home, INPUTS)
    config = (home / '.ssh' / 'config').read_text() if (home / '.ssh' / 'config').exists() else ''
    check('configure-ssh succeeds and outputs the alias target', result.returncode == 0 and outputs.get('target') == 'pilot-deploy')
    check('config names the alias, host and user', all(s in config for s in (
        'Host pilot-deploy', 'HostName example.test', 'User cpuser', 'StrictHostKeyChecking yes',
        'ControlMaster auto', 'ServerAliveInterval 15', 'ServerAliveCountMax 4')))
    check('key and known_hosts are written privately',
          (home / '.ssh' / 'pilot-deploy.key').read_text() == KEY + '\n'
          and oct((home / '.ssh' / 'pilot-deploy.key').stat().st_mode & 0o777) == '0o600'
          and (home / '.ssh' / 'pilot-deploy.known_hosts').read_text() == KNOWN + '\n')
    check('secrets are never echoed', 'abc123secretmaterial' not in result.stdout + result.stderr)

    # Missing inputs are refused with exit 2 and nothing written.
    for name in INPUTS:
        home = fresh_home('missing-' + name)
        result, outputs = run_step(CONFIGURE, 'ssh', REPO / 'configure-ssh', home, {**INPUTS, name: ''})
        check(f'configure-ssh refuses an empty {name}',
              result.returncode == 2 and not (home / '.ssh' / 'config').exists() and 'target' not in outputs
              and 'abc123secretmaterial' not in result.stdout + result.stderr)

    # The main action and the sub-action leave byte-identical SSH state for the same inputs.
    main_inputs = {'ssh-alias': INPUTS['alias'], 'ssh-host': INPUTS['host'], 'ssh-username': INPUTS['username'],
                   'ssh-private-key': KEY, 'ssh-known-hosts': KNOWN}
    main_home, sub_home = fresh_home('main-home'), fresh_home('sub-home')
    main_result, main_outputs = run_step(MAIN, 'ssh', REPO, main_home, main_inputs)
    sub_result, sub_outputs = run_step(CONFIGURE, 'ssh', REPO / 'configure-ssh', sub_home, INPUTS)
    check('both succeed', main_result.returncode == 0 and sub_result.returncode == 0)
    check('both output the same target', main_outputs.get('target') == sub_outputs.get('target') == 'pilot-deploy')

    def tree(home):
        return {str(p.relative_to(home)): (p.read_text().replace(str(home), '$HOME') if p.is_file() else 'dir',
                                           oct(p.stat().st_mode & 0o777))
                for p in sorted((home / '.ssh').rglob('*'))}

    a, b = tree(main_home), tree(sub_home)
    check('identical ~/.ssh files, contents and modes', a == b and '.ssh/config' in b)

print(f'failures: {fails}')
raise SystemExit(1 if fails else 0)
