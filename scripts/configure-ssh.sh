#!/usr/bin/env bash
#
# Write a deploy key and pinned host key for one SSH alias, leaving every other SSH setting on the
# runner alone (a job may also hold keys for private dependencies).
#
# Runs ON THE RUNNER. Environment: SSH_ALIAS, SSH_HOST_NAME, SSH_USER_NAME, SSH_PRIVATE_KEY,
# SSH_KNOWN_HOSTS. Writes `target=<alias>` to $GITHUB_OUTPUT when that is set.
#
# A deployment makes dozens of ssh/rsync calls. Opening a fresh TCP connection and key exchange for
# each one trips per-source connection-rate limits on shared hosts, which reset the handshake
# (`kex_exchange_identification: read: Connection reset by peer`) at an arbitrary step, possibly
# after the application is already in maintenance. The alias therefore multiplexes every call over
# one authenticated master connection that persists for the rest of the job.
set -euo pipefail

for pair in "alias:${SSH_ALIAS:-}" "host:${SSH_HOST_NAME:-}" "username:${SSH_USER_NAME:-}"; do
    value=${pair#*:}
    case $value in
        '' | *[!A-Za-z0-9._@-]*)
            echo "::error::The SSH ${pair%%:*} is empty or contains characters not allowed in an SSH config value." >&2
            exit 2 ;;
    esac
done

if [ -z "${SSH_PRIVATE_KEY:-}" ] || [ -z "${SSH_KNOWN_HOSTS:-}" ]; then
    echo "::error::ssh-private-key and ssh-known-hosts are both required; host keys are never trusted on first use." >&2
    exit 2
fi

install -d -m 700 "$HOME/.ssh"
key="$HOME/.ssh/$SSH_ALIAS.key"
known="$HOME/.ssh/$SSH_ALIAS.known_hosts"
(umask 077 && printf '%s\n' "$SSH_PRIVATE_KEY" >"$key")
(umask 077 && printf '%s\n' "$SSH_KNOWN_HOSTS" >"$known")
# %C hashes the connection tuple, keeping the socket path short enough for sun_path.
control_dir="$HOME/.ssh/cm"
install -d -m 700 "$control_dir"

if [ -f "$HOME/.ssh/config" ] && grep -Eq "^Host[[:space:]]+$SSH_ALIAS([[:space:]]|$)" "$HOME/.ssh/config"; then
    echo "::error::~/.ssh/config already defines Host $SSH_ALIAS; choose another ssh-alias." >&2
    exit 2
fi

{
    printf '\nHost %s\n' "$SSH_ALIAS"
    printf '    HostName %s\n' "$SSH_HOST_NAME"
    printf '    User %s\n' "$SSH_USER_NAME"
    printf '    IdentityFile %s\n' "$key"
    printf '    IdentitiesOnly yes\n'
    printf '    UserKnownHostsFile %s\n' "$known"
    printf '    StrictHostKeyChecking yes\n'
    printf '    BatchMode yes\n'
    printf '    ControlMaster auto\n'
    printf '    ControlPath %s\n' "$control_dir/%C"
    printf '    ControlPersist 15m\n'
    printf '    ServerAliveInterval 15\n'
    printf '    ServerAliveCountMax 4\n'
} >>"$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "target=$SSH_ALIAS" >>"$GITHUB_OUTPUT"
fi
