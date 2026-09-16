#!/usr/bin/env bash
# Upload one checkout into an already-created managed candidate release.
set -euo pipefail

error() { echo "::error::$*" >&2; }

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    printf '%s' "${value%"${value##*[![:space:]]}"}"
}

target=${DEPLOY_TARGET:-}
app=${DEPLOY_DIR:-}
release=${DEPLOY_RELEASE_ID:-}

[ -n "$target" ] || { error "DEPLOY_TARGET is not set."; exit 2; }
for pair in "application:$app" "release:$release"; do
    value=${pair#*:}
    case $value in
        '' | . | .. | .* | *[!A-Za-z0-9._-]*)
            error "The ${pair%%:*} name '$value' is unsafe."
            exit 2 ;;
    esac
done

paths=()
while IFS= read -r raw || [ -n "$raw" ]; do
    path=$(trim "$raw")
    [ -n "$path" ] || continue
    case $path in
        /* | -* | .. | ../* | */.. | */../*)
            error "Upload path '$path' must be relative to the checkout and must not contain '..'."
            exit 2 ;;
    esac
    [ -e "$path" ] || { error "Upload path '$path' does not exist in the checkout."; exit 2; }
    paths+=("$path")
done <<<"${DEPLOY_PATHS:-}"
[ "${#paths[@]}" -gt 0 ] || { error "No upload paths were given."; exit 2; }

excludes=(--exclude=.env --exclude=.deploy-release)
while IFS= read -r raw || [ -n "$raw" ]; do
    pattern=$(trim "$raw")
    [ -n "$pattern" ] && excludes+=("--exclude=$pattern")
done <<<"${DEPLOY_EXCLUDES:-}"

# The remote transaction, not a caller-controlled destination, creates and owns
# this exact directory. Refuse upload if its lock or state is not present.
# shellcheck disable=SC2016,SC2029
state=$(ssh "$target" "bash -s -- $(printf '%q ' "$app" "$release")" <<'REMOTE'
app=$1
release=$2
root="$HOME/.deployments/$app"
candidate="$root/releases/$release"
if [ ! -f "$root/deploy.lock/owner" ] || [ "$(cat "$root/deploy.lock/owner")" != "$release" ]; then
    echo no-lock
elif [ ! -d "$candidate" ] || [ -L "$candidate" ]; then
    echo invalid-candidate
elif [ -n "$(ls -A "$candidate")" ]; then
    echo nonempty
else
    echo ready
fi
REMOTE
)

[ "$state" = ready ] || { error "Managed candidate is '$state', not ready for upload."; exit 1; }

destination="$target:~/.deployments/$app/releases/$release/"
echo "Uploading ${#paths[@]} path(s) into candidate release $release."
rsync -av --delete "${excludes[@]}" -e ssh "${paths[@]}" "$destination"
