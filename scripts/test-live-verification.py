#!/usr/bin/env python3
"""Execute actual composite live-check steps against the real atomic state machine.

Only SSH transport, HTTP responses, cron and framework calls are synthetic. The
YAML's conditions, environments and shell bodies drive classification/marking,
and atomic-release.sh makes the final availability/cron/durable-state decision.
"""
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ATOMIC = REPO / "scripts/atomic-release.sh"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
SELECTED = {
    "Verify site health", "Read the selected atomic release status",
    "Run atomic application-specific live verification",
    "Verify the web handler's PHP version and memory limit",
    "Record that the selected atomic release served healthily",
    "Run application-specific live verification", "Commit the verified atomic release",
    "Recover, unlock and report the atomic deployment",
}


def load_steps():
    # These blocks use only scalar metadata/env and literal shell bodies. Parsing
    # that subset avoids requiring a YAML package on consumers' test machines.
    blocks = re.split(r"(?=^    - (?:name|id):)", (REPO / "action.yml").read_text(), flags=re.M)
    steps = []
    for block in blocks:
        name = re.search(r"^\s+(?:- )?name: (.+)$", block, re.M)
        if not name or name[1] not in SELECTED:
            continue
        condition = re.search(r"^      if: (.+)$", block, re.M)
        identity = re.search(r"^    - id: (.+)$", block, re.M)
        env_block = re.search(r"^      env:\n((?:^        .*\n)+)", block, re.M)
        run = re.search(r"^      run: \|\n(.*)", block, re.M | re.S)
        assert run, f"Missing literal shell body: {name[1]}"
        body = "\n".join(line[8:] if line.startswith("        ") else line for line in run[1].splitlines())
        environment = {}
        for line in (env_block[1].splitlines() if env_block else []):
            key, value = line.strip().split(": ", 1)
            environment[key] = value
        steps.append(dict(name=name[1], id=identity[1] if identity else name[1],
                          condition=condition[1] if condition else "true", env=environment, run=body))
    assert len(steps) == len(SELECTED), "Live-step inventory changed; update fixture deliberately"
    return steps


STEPS = load_steps()
REFERENCE = re.compile(r"\b(?:inputs|steps|github)(?:\.[A-Za-z0-9_-]+)+")


def expression(value, context, success):
    value = value.replace("&&", " and ").replace("||", " or ")
    value = value.replace("always()", "True").replace("success()", str(success))
    if value.strip() == "true":
        return True
    value = REFERENCE.sub(lambda m: f"lookup({m[0]!r})", value)
    return eval(value, {"__builtins__": {}}, {"lookup": lambda key: context.get(key, "")})


def render(value, context, success):
    return re.sub(r"\$\{\{\s*(.*?)\s*\}\}", lambda m: str(expression(m[1], context, success)), value)


def executable(path, body):
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
    path.chmod(0o700)


def case(name, *, proof=True, verifier=True, php=1, health=True, web=True,
         unmark_failure=False, interrupt=False, layout="stable-directory", mode="atomic", health_status=200, health_expect="Application up", health_text=True, health_ssh_stall=False, health_ssh_oversized=False, health_query=False, health_metadata=""):
    with tempfile.TemporaryDirectory(prefix="shared-live-proof-") as temporary:
        root = Path(temporary)
        home, binaries = root / "home", root / "bin"
        home.mkdir(); binaries.mkdir()
        state = home / ".deployments/app/state/fixture"
        trace = root / "trace"
        env = dict(os.environ, HOME=str(home), PATH=str(binaries) + ":" + os.environ["PATH"],
                   CRONTAB_FILE=str(root / "crontab"), FIXTURE_TRACE=str(trace),
                   FIXTURE_STATE=str(state), FIXTURE_PHP=str(php), FIXTURE_PROOF=str(int(proof)),
                   FIXTURE_HEALTH_METADATA=health_metadata, FIXTURE_HEALTH_SSH_OVERSIZED=str(int(health_ssh_oversized)), FIXTURE_HEALTH_QUERY=str(int(health_query)), FIXTURE_HEALTH_SSH_STALL=str(int(health_ssh_stall)), FIXTURE_HEALTH_STATUS=str(health_status), FIXTURE_HEALTH_TEXT=str(int(health_text)), FIXTURE_UNMARK_FAILURE=str(int(unmark_failure)), FIXTURE_INTERRUPT=str(int(interrupt)),
                   GITHUB_ACTION_PATH=str(REPO), WEB_PHP_PROBE_WINDOW="75")
        executable(binaries / "php", '''
while [ "${1:-}" = -d ]; do shift 2; done
[ "${1:-}" != artisan ] || shift
case "${1:-}" in
  -r) [ -f storage/framework/down ] ;;
  down) mkdir -p storage/framework; : >storage/framework/down ;;
  up) rm -f storage/framework/down ;;
esac
''')
        executable(binaries / "crontab", '''
case "${1:-}" in
  -l) cat "$CRONTAB_FILE" ;;
  -r) rm -f "$CRONTAB_FILE" ;;
  *) cp "$1" "$CRONTAB_FILE" ;;
esac
''')
        executable(binaries / "ssh", '''
command=${!#}
printf '%s\\n' "$command" >>"$FIXTURE_TRACE"
if [[ "$command" = *unmark-healthy* && "$FIXTURE_UNMARK_FAILURE" = 1 ]]; then exit 91; fi
if [[ "$command" = 'bash -s -- '* && "$command" = *'/up '* ]]; then
  if [[ "$FIXTURE_HEALTH_SSH_STALL" = 1 ]]; then /usr/bin/sleep 30; exit 1; fi
  if [[ "$FIXTURE_HEALTH_SSH_OVERSIZED" = 1 ]]; then exec head -c 1048576 /dev/zero; fi
  case "$FIXTURE_HEALTH_METADATA" in
    nul) printf 'Application up\\nORIGIN-META 2\\00000|text/html\\n'; exit 0 ;;
    secret) printf 'Application up\\nORIGIN-META SECRET_TOKEN|text/html\\n'; exit 0 ;;
    unterminated) printf 'Application up\\nORIGIN-META 200|text/html'; exit 0 ;;
  esac
fi
exec bash -c "$command"
''')
        executable(binaries / "sleep", "exit 0\n")
        executable(binaries / "hostname", "exit 0\n")
        executable(binaries / "uapi", '''
[[ "$FIXTURE_HEALTH_QUERY" = 1 ]] || exit 1
printf '  ip: 127.0.0.1\\n'
''')
        executable(binaries / "timeout", '''
if [[ "$FIXTURE_HEALTH_SSH_STALL" = 1 && "${1:-}" = --signal=KILL && "${2:-}" = 20s && "${3:-}" = ssh ]]; then
  printf 'health-ssh-budget=20\\n' >>"$FIXTURE_TRACE"
  shift 2
  exec /usr/bin/timeout --signal=KILL 1s "$@"
fi
exec /usr/bin/timeout "$@"
''')
        executable(binaries / "curl", '''
output='' format='' url=${!#}
if [[ "$url" = */up* && "$FIXTURE_HEALTH_STATUS" != 200 ]]; then exit 22; fi
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output=$2; shift ;; --write-out) format=$2; shift ;; esac
  shift
done
if [[ "$url" = *'_deploy-php-check-'* ]]; then
  printf 'probe\\n' >>"$FIXTURE_TRACE"
  case "$FIXTURE_PHP" in
    0) answer='8.5|1024M|litespeed'; mime=text/plain ;;
    3) answer='8.4|1024M|litespeed'; mime=text/plain ;;
    *) answer='<html><title>Unproven page</title></html>'; mime=text/html ;;
  esac
  if [ "$FIXTURE_PHP" = 2 ]; then exit 2; fi
elif [[ "$url" = */application-proof ]]; then
  if [ "$FIXTURE_PROOF" = 1 ]; then answer=application-fixture-healthy; else answer='<html>HTTP200 error page</html>'; fi
  mime=text/plain
elif [[ "$url" = */up* && "$FIXTURE_HEALTH_TEXT" = 1 ]]; then
  answer='<html>Application up</html>'; mime=text/html
else
  answer='<html>HTTP200 error page</html>'; mime=text/html
fi
if [ -n "$output" ]; then printf '%s' "$answer" >"$output"; else printf '%s' "$answer"; fi
[ -z "$format" ] || printf '200|%s' "$mime"
''')
        real_rm = shutil.which("rm")
        executable(binaries / "rm", f'''
if [ "$FIXTURE_INTERRUPT" = 1 ] && [[ "$*" = *"$FIXTURE_STATE"* ]] && [ ! -f "$FIXTURE_STATE/interrupted" ]; then
  : >"$FIXTURE_STATE/interrupted"; exit 92
fi
exec {real_rm} "$@"
''')
        verifier_file = root / "verify.sh"
        executable(verifier_file, '''
printf 'application-verification\\n' >>"$FIXTURE_TRACE"
if [ "$DEPLOYMENT_MODE" = atomic ]; then
  [ "$DEPLOY_LIVE_RELEASE" = "$DEPLOY_RELEASE_ID" ]
  [ "$DEPLOY_LIVE_COMMIT" = "$DEPLOY_SOURCE_COMMIT" ]
  [ "$DEPLOY_LIVE_STATE" = serving ]
fi
answer=$(curl --fail --silent "$DEPLOY_SITE_URL/application-proof")
[ "$answer" = application-fixture-healthy ]
''')
        (root / "crontab").write_text('* * * * * cd "$HOME/app" && php artisan schedule:run # JOB:app-scheduler\n')

        def atomic(*arguments):
            result = subprocess.run(["bash", str(ATOMIC), *arguments], env=env, text=True, capture_output=True)
            assert result.returncode == 0, (name, arguments, result.stdout, result.stderr)
            return result.stdout

        atomic("begin", "app", "fixture", COMMIT, "7200", "3", "maintenance", "", layout, "storage")
        candidate = home / ".deployments/app/releases/fixture"
        for folder in ["storage/framework", "storage/app", "public", "vendor", "bootstrap"]:
            (candidate / folder).mkdir(parents=True, exist_ok=True)
        for file in ["artisan", "vendor/autoload.php", "bootstrap/app.php"]:
            (candidate / file).touch()
        (candidate / ".env").write_text("APP_KEY=fixture\nAPP_ENV=production\nAPP_URL=https://example.test\n")
        atomic("preflight", "app", "fixture", "")
        atomic("prepare", "app", "fixture", str(binaries / "php"))
        atomic("quiesce", "app", "fixture", str(binaries / "php"))
        atomic("risk", "app", "fixture", str(binaries / "php"))
        atomic("activate", "app", "fixture", str(binaries / "php"))
        if layout == "stable-directory":
            atomic("refresh-caches", "app", "fixture", str(binaries / "php"), "256M", "config:cache")
        atomic("serve", "app", "fixture", str(binaries / "php"))
        atomic("restore-cron", "app", "fixture")

        context = {
            "github.sha": COMMIT, "inputs.deployment-mode": mode, "inputs.deploy-dir": "app",
            "inputs.site-url": "https://example.test", "inputs.health-path": ("/up?token=SECRET_QUERY" if health_query else "/up") if health else "",
            "inputs.verification-script": str(verifier_file) if verifier else "",
            "inputs.health-expect": health_expect,
            "inputs.verify-web-php": "true" if web else "false", "inputs.php-version": "8.5",
            "inputs.web-memory-limit": "invalid" if php == 2 else "1024M", "inputs.artisan-memory-limit": "256M",
            "inputs.atomic-layout": layout, "steps.ssh.outputs.target": "fixture",
            "steps.ssh.outcome": "success", "steps.resolve.outputs.release-id": "fixture",
            "steps.resolve.outputs.php": str(binaries / "php"),
            "steps.resolve.outputs.app-dir": ".deployments/app/releases/fixture",
        }
        success, failures, log, before_finalize = True, {}, "", None
        for step in STEPS:
            permitted = "always()" in step["condition"] or success
            if not permitted or not expression(step["condition"], context, success):
                context[f"steps.{step['id']}.outcome"] = "skipped"
                continue
            if step["id"] == "atomic-finalize":
                before_finalize = {p.name: p.read_text() for p in state.iterdir() if p.is_file()}
            step_env = env | {key: render(value, context, success) for key, value in step["env"].items()}
            output = root / "output"
            output.write_text("")
            step_env["GITHUB_OUTPUT"] = str(output)
            result = subprocess.run(["bash", "-c", render(step["run"], context, success)], env=step_env,
                                    cwd=root, text=True, capture_output=True)
            log += result.stdout + result.stderr
            outcome = "success" if result.returncode == 0 else "failure"
            context[f"steps.{step['id']}.outcome"] = outcome
            for record in output.read_text().splitlines():
                key, value = record.split("=", 1)
                context[f"steps.{step['id']}.outputs.{key}"] = value
            if result.returncode:
                success = False
                failures[step["id"]] = result.returncode
            if step["id"] == "atomic-finalize" and interrupt and mode == "atomic":
                assert result.returncode != 0 and (state / "left_serving").read_text().strip() == "true", log
                assert (state / "phase").read_text().strip() == "finalized", log
                assert (home / ".deployments/app/deploy.lock/owner").is_file(), log
                retry = subprocess.run(["bash", "-c", render(step["run"], context, success)], env=step_env,
                                       cwd=root, text=True, capture_output=True)
                log += retry.stdout + retry.stderr
                assert retry.returncode == 0, log
        assert "SECRET" not in log and "ignored null byte" not in log, log
        serving = not (home / "app/storage/framework/down").exists()
        health_proved = health and health_status == 200 and (not health_expect or health_text) and not health_ssh_stall and not health_ssh_oversized and not health_metadata
        preserved = proof and verifier and health_proved and php == 1 and web
        expected_serving = success or preserved or mode == "in-place"
        assert serving == expected_serving, (name, success, serving, log)
        if mode == "atomic":
            assert not (home / ".deployments/app/deploy.lock").exists(), log
            assert (root / "crontab").read_text() != "" if serving else (root / "crontab").read_text() == "", log
            qualified = proof and verifier and health_proved and (not web or php in [0, 1])
            assert (before_finalize.get("served_healthy", "false").strip() == "true") == qualified, log
            if preserved:
                assert before_finalize.get("served_healthy", "").strip() == "true", log
                assert before_finalize["committed"].strip() == "false", log
                assert "was left serving and was not committed" in log, log
            elif not success:
                assert before_finalize.get("served_healthy", "false").strip() != "true", log
        events = trace.read_text().splitlines() if trace.exists() else []
        if health and not health_proved:
            assert "application-verification" not in events and "probe" not in events, (events, log)
        if health_ssh_stall:
            assert events.count("health-ssh-budget=20") == 4, (events, log)
        marker_events = [i for i, event in enumerate(events) if "mark-healthy " in event and "unmark-healthy " not in event]
        if marker_events and web:
            assert marker_events[0] > max(i for i, event in enumerate(events) if event == "probe"), events
        if php == 3 and mode == "atomic" and proof and verifier:
            assert failures.get("Verify the web handler's PHP version and memory limit") == 3, (failures, log)
            assert not any("mark-healthy " in event and "unmark-healthy " not in event for event in events), events
        if success and verifier and web:
            app_index, probe_index = events.index("application-verification"), events.index("probe")
            assert app_index < probe_index if mode == "atomic" else probe_index < app_index, events
        print(f"ok - {name}")


if __name__ == "__main__":
    for layout in ["stable-directory", "release-symlink"]:
        case(f"verified app/inconclusive PHP stays serving ({layout})", layout=layout)
        case(f"wrong PHP returns maintenance ({layout})", php=3, layout=layout)
    case("HTTP200 HTML without verifier never preserves", verifier=False, health_expect="", health_text=False)
    case("default health text rejects HTTP200 HTML before app verification and PHP", health_text=False)
    case("stalled health SSH is bounded on all four actual attempts", health_ssh_stall=True)
    case("oversized health SSH body never passes the actual health gate", health_ssh_oversized=True)
    case("trusted health query succeeds with credentials omitted from logs", health_query=True, php=0)
    case("NUL in health SSH metadata never passes the actual health gate", health_metadata="nul")
    case("invalid health metadata status never leaks its payload", health_metadata="secret")
    case("unterminated health metadata never passes the actual health gate", health_metadata="unterminated")
    case("HTTP200 HTML with failed app proof never preserves", proof=False)
    case("wrong PHP remains definitive when revocation SSH fails", php=3, unmark_failure=True)
    case("invalid PHP probe input never preserves", php=2)
    case("empty health path never preserves", health=False)
    case("failed health never preserves or bypasses gate", health_status=503)
    case("disabled PHP without verifier commits without marker", web=False, verifier=False)
    case("disabled PHP with app proof commits", web=False)
    case("successful PHP and app proof commits", php=0)
    case("successful PHP without verifier keeps ordinary deployment behavior", php=0, verifier=False)
    case("durable left-serving decision survives interrupted finalization", interrupt=True)
    case("in-place keeps verifier after PHP", php=0, mode="in-place")
