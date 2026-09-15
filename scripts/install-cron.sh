#!/usr/bin/env bash
#
# Install this application's cron lines on a shared cPanel account, leaving every other line alone.
#
# Runs ON THE HOST, fed over SSH by the deploy workflow:
#
#   ssh <target> "bash -s -- $(printf '%q ' <app-dir> <line>...)" < scripts/deploy/install-cron.sh
#
#   <app-dir>  The application's directory under $HOME.
#   <line>...  The desired lines. Each runs from `cd "$HOME/<app-dir>" ` and ends in `# JOB:<id>`.
#
# A line in the current crontab belongs to this application, and is replaced, when it runs from the
# application's directory (in any of the spellings a hand-installed line uses) or ends in one of the
# desired job ids. So a legacy line cannot survive beside its deploy-managed replacement and run the
# same job twice, and a job id cannot be installed twice. Ownership is never inferred from a shared
# prefix: another application's `# JOB:<app-dir>-two-scheduler`, run from its own directory, is not
# this application's.
#
# The account crontab is shared by every application on the account, so the rewrite is careful:
#
# - One deploy at a time holds a lock, so two applications deploying together cannot each write back
#   a crontab missing the other's change.
# - The current crontab is read into a file first, and a failed read stops the deploy. Piping
#   `crontab -l` into `crontab -` has already replaced a whole account crontab with one line when the
#   read came back empty.
# - The previous crontab is kept under ~/.crontab-backups before anything is written.
# - The new crontab is installed from a file and read back; the deploy fails unless it matches.
# - Running it again with the same lines changes nothing.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: install-cron.sh <app-dir> <line>..." >&2
    exit 2
fi

app_dir=$1
shift

case $app_dir in
    ''|*[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain directory name under the account home." >&2
        exit 2 ;;
esac

ids=()
for line in "$@"; do
    # shellcheck disable=SC2016 # $HOME is matched literally: cron expands it, not this script.
    case $line in
        *'cd "$HOME/'"$app_dir"'" '*) ;;
        *)
            echo "::error::Desired cron line does not run from cd \"\$HOME/$app_dir\": $line" >&2
            exit 2 ;;
    esac

    id=${line##*# JOB:}
    if [ "$id" = "$line" ] || [ -z "$id" ] || [ "${id//[A-Za-z0-9._-]/}" != "" ]; then
        echo "::error::Desired cron line does not end in '# JOB:<id>': $line" >&2
        exit 2
    fi
    ids+=("$id")
done

if ! command -v flock >/dev/null 2>&1; then
    echo "::error::flock is not available on this host, so the shared crontab cannot be locked." >&2
    exit 1
fi

exec 9>"$HOME/.crontab-deploy.lock"
if ! flock -w 120 9; then
    echo "::error::Another deploy has held the crontab lock for two minutes; not rewriting the crontab." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! crontab -l >"$work/current" 2>"$work/error"; then
    if grep -qi 'no crontab for' "$work/error"; then
        : >"$work/current"
    else
        cat "$work/error" >&2
        echo "::error::crontab -l failed, so the current crontab is unknown; refusing to rewrite it." >&2
        exit 1
    fi
fi

# The job ids reach awk as a file, not a -v value: some awks refuse a newline inside -v.
printf '%s\n' "${ids[@]}" >"$work/ids"

# shellcheck disable=SC2016 # The first two spellings are matched literally, $HOME unexpanded.
awk \
    -v quoted_literal='cd "$HOME/'"$app_dir"'" ' \
    -v bare_literal='cd $HOME/'"$app_dir"' ' \
    -v quoted_expanded="cd \"$HOME/$app_dir\" " \
    -v bare_expanded="cd $HOME/$app_dir " \
    '
    FNR == NR { job["# JOB:" $0] = 1; next }
    {
        owned = index($0, quoted_literal) || index($0, bare_literal) || index($0, quoted_expanded) || index($0, bare_expanded)
        if (!owned && match($0, /# JOB:[A-Za-z0-9._-]+$/)) owned = (substr($0, RSTART) in job)
        if (!owned) print
    }
    ' "$work/ids" "$work/current" >"$work/kept"

printf '%s\n' "$@" >"$work/desired"
cat "$work/kept" "$work/desired" >"$work/next"

if cmp -s "$work/current" "$work/next"; then
    echo "Cron lines for $app_dir are already installed; crontab unchanged."
    exit 0
fi

install -d -m 700 "$HOME/.crontab-backups"
backup="$HOME/.crontab-backups/$app_dir-$(date -u +%Y%m%dT%H%M%SZ).txt"
cp "$work/current" "$backup"

echo "Updating cron lines for $app_dir (previous crontab saved to $backup):"
diff "$work/current" "$work/next" || true

crontab "$work/next"

if ! crontab -l | cmp -s - "$work/next"; then
    echo "::error::The installed crontab does not match what was written. The previous one is in $backup." >&2
    exit 1
fi

echo "Cron lines for $app_dir installed and verified."
