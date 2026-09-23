#!/usr/bin/env bash
# Real-transport harness for configure-ssh.sh: a throwaway sshd on localhost, the alias the action
# writes, and the call shapes the action uses (captured output, rsync -e ssh, timeout-wrapped ssh).
# shellcheck disable=SC2016,SC2034 # Checks are eval'd strings and use variables assigned before them.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
[ -x "$sshd_bin" ] || { echo "FAIL - sshd is required for this harness" >&2; exit 1; }

# GNU timeout on CI; a perl alarm stands in on hosts without coreutils.
command -v timeout >/dev/null || timeout() {
    while [[ $1 == --* ]]; do shift; done
    local limit=${1%s}; shift
    perl -e 'alarm shift; exec @ARGV' "$limit" "$@"
}

scratch=$(mktemp -d /tmp/cfgssh.XXXXXX)
sshd_pid=''
cleanup() {
    [ -n "$sshd_pid" ] && kill "$sshd_pid" 2>/dev/null
    ssh -F "$scratch/home/.ssh/config" -O exit example-deploy >/dev/null 2>&1
    rm -rf "$scratch"
}
trap cleanup EXIT
fails=0
check() {
    if eval "$2"; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        fails=$((fails + 1))
    fi
}

ssh-keygen -q -t ed25519 -N '' -f "$scratch/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$scratch/user_key"
cp "$scratch/user_key.pub" "$scratch/authorized_keys"
chmod 600 "$scratch/authorized_keys"
port=$((20000 + RANDOM % 20000))
cat >"$scratch/sshd_config" <<CFG
Port $port
ListenAddress 127.0.0.1
HostKey $scratch/host_key
AuthorizedKeysFile $scratch/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
StrictModes no
PidFile $scratch/sshd.pid
LogLevel VERBOSE
CFG
"$sshd_bin" -D -f "$scratch/sshd_config" -E "$scratch/sshd.log" &
sshd_pid=$!
for _ in $(seq 50); do grep -q "Server listening" "$scratch/sshd.log" 2>/dev/null && break; sleep 0.1; done

export HOME="$scratch/home"
mkdir -p "$HOME"
SSH_ALIAS=example-deploy SSH_HOST_NAME=127.0.0.1 SSH_USER_NAME=$(id -un) \
    SSH_PRIVATE_KEY=$(cat "$scratch/user_key") \
    SSH_KNOWN_HOSTS="[127.0.0.1]:$port $(cut -d' ' -f1,2 "$scratch/host_key.pub")" \
    GITHUB_OUTPUT="$scratch/output" bash "$here/configure-ssh.sh"; status=$?
check "configuration succeeds and names the alias" '[ "$status" -eq 0 ] && grep -qx "target=example-deploy" "$scratch/output"'
printf '    Port %s\n' "$port" >>"$HOME/.ssh/config"
cfg="$HOME/.ssh/config"
resolved=$(ssh -F "$cfg" -G example-deploy)
check "alias keeps the pinned host key" 'grep -qx "stricthostkeychecking true" <<<"$resolved"'
check "alias multiplexes over a persistent master" 'grep -qx "controlmaster auto" <<<"$resolved" && grep -qx "controlpersist 900" <<<"$resolved"'
check "control socket directory is private" '[ "$(stat -c %a "$HOME/.ssh/cm" 2>/dev/null || stat -f %Lp "$HOME/.ssh/cm")" = 700 ]'

# A backgrounded master must not hold the capture pipe open, or every `output=$(ssh ...)` hangs.
start=$SECONDS
out=$(timeout 20s ssh -F "$cfg" example-deploy 'echo first'); status=$?
check "captured output returns promptly while the master persists" \
    '[ "$status" -eq 0 ] && [ "$out" = first ] && [ $((SECONDS - start)) -lt 10 ]'
check "master stays up after the first call exits" 'ssh -F "$cfg" -O check example-deploy 2>/dev/null'

for i in $(seq 20); do
    timeout --kill-after=5s 60s ssh -F "$cfg" -o ConnectTimeout=10 example-deploy "echo $i" >/dev/null || fails=$((fails + 1))
done
mkdir -p "$scratch/src" "$scratch/dst"
echo payload >"$scratch/src/file"
rsync -a -e "ssh -F $cfg" "$scratch/src/" "example-deploy:$scratch/dst/" >/dev/null 2>&1
check "rsync reuses the alias" '[ "$(cat "$scratch/dst/file" 2>/dev/null)" = payload ]'
accepted=$(grep -c "Accepted publickey" "$scratch/sshd.log")
check "twenty-two calls cost one authenticated connection (saw $accepted)" '[ "$accepted" -eq 1 ]'

SSH_ALIAS=example-deploy SSH_HOST_NAME=127.0.0.1 SSH_USER_NAME=x SSH_PRIVATE_KEY=k SSH_KNOWN_HOSTS=h \
    bash "$here/configure-ssh.sh" >/dev/null 2>&1; status=$?
check "an existing alias is still refused" '[ "$status" -eq 2 ]'

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all configure-ssh checks passed"
