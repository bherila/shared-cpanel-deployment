#!/usr/bin/env bash
#
# Upload a build to one application's directory on a shared cPanel account, with `rsync --delete`.
#
# Runs ON THE RUNNER, from the checkout root. Configured through the environment so that no value is
# ever interpolated into shell source:
#
#   DEPLOY_TARGET                 ssh destination (an alias written by configure-ssh, or user@host)
#   DEPLOY_DIR                    the application's directory under the account home, e.g. uc-laravel
#   DEPLOY_PATHS                  newline-separated local paths to upload, relative to the checkout
#   DEPLOY_EXCLUDES               newline-separated extra rsync exclude patterns (optional)
#   DEPLOY_KEEP_RUNTIME_STORAGE   "true" (default) keeps logs, uploads, cache, sessions and views
#   DEPLOY_MARKER                 a file that marks an existing directory as this kind of app (default: artisan)
#
# `--delete` removes everything at the destination that is not in the upload, and one cPanel account
# hosts several applications plus its own webroots. So before anything is sent:
#
# - DEPLOY_DIR must be a plain, non-hidden directory name, and not one cPanel owns (public_html, mail…).
#   An empty value would otherwise make the destination the account home.
# - Every path must be relative, free of `..`, and present in the checkout.
# - The destination is inspected over ssh. It must be absent, empty, or already contain DEPLOY_MARKER;
#   a symlink, a file, or a populated directory of something else is refused, so a typo cannot point
#   `--delete` at another application.
# - `.env` is always excluded, whatever the caller passes.
set -euo pipefail

error() { echo "::error::$*" >&2; }

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    printf '%s' "${value%"${value##*[![:space:]]}"}"
}

target=${DEPLOY_TARGET:-}
dir=${DEPLOY_DIR:-}
marker=${DEPLOY_MARKER:-artisan}
keep_runtime=${DEPLOY_KEEP_RUNTIME_STORAGE:-true}

if [ -z "$target" ]; then
    error "DEPLOY_TARGET is not set."
    exit 2
fi

case $dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        error "The deploy directory '$dir' must be a plain, non-hidden directory name under the account home."
        exit 2 ;;
esac

case $dir in
    public_html | www | web | mail | etc | logs | tmp | ssl | cache | bin | lib | perl5 | access-logs | lscache | backups)
        error "The deploy directory '$dir' belongs to cPanel or is a webroot, not an application directory."
        exit 2 ;;
esac

case $marker in
    '' | . | .. | */* | *[!A-Za-z0-9._-]*)
        error "The marker '$marker' must be a plain file name."
        exit 2 ;;
esac

case $keep_runtime in
    true | false) ;;
    *)
        error "keep-runtime-storage must be 'true' or 'false', not '$keep_runtime'."
        exit 2 ;;
esac

paths=()
while IFS= read -r raw || [ -n "$raw" ]; do
    path=$(trim "$raw")
    [ -z "$path" ] && continue
    case $path in
        /* | -* | .. | ../* | */.. | */../*)
            error "Upload path '$path' must be relative to the checkout and must not contain '..'."
            exit 2 ;;
    esac
    if [ ! -e "$path" ]; then
        error "Upload path '$path' does not exist in the checkout."
        exit 2
    fi
    paths+=("$path")
done <<<"${DEPLOY_PATHS:-}"

if [ "${#paths[@]}" -eq 0 ]; then
    error "No upload paths were given."
    exit 2
fi

excludes=(--exclude=.env)
if [ "$keep_runtime" = true ]; then
    # Anchored at the transfer root, and the contents rather than the directories, so a first deploy
    # still creates the tree while an existing server keeps what is in it. rsync never deletes an
    # excluded path unless --delete-excluded is passed.
    excludes+=(
        '--exclude=/storage/app/*'
        '--exclude=/storage/logs/*'
        '--exclude=/storage/framework/cache/*'
        '--exclude=/storage/framework/sessions/*'
        '--exclude=/storage/framework/views/*'
    )
fi
while IFS= read -r raw || [ -n "$raw" ]; do
    pattern=$(trim "$raw")
    [ -z "$pattern" ] && continue
    excludes+=("--exclude=$pattern")
done <<<"${DEPLOY_EXCLUDES:-}"

# shellcheck disable=SC2016,SC2029 # The heredoc expands on the host; the %q arguments deliberately on the runner.
state=$(ssh "$target" "bash -s -- $(printf '%q ' "$dir" "$marker")" <<'REMOTE'
d="$HOME/$1"
if [ -L "$d" ]; then echo symlink
elif [ ! -e "$d" ]; then echo absent
elif [ ! -d "$d" ]; then echo not-a-directory
elif [ -e "$d/$2" ]; then echo app
elif [ -z "$(ls -A "$d")" ]; then echo empty
else echo other
fi
REMOTE
)

case $state in
    app | absent | empty) ;;
    *)
        error "Refusing to deploy with --delete: ~/$dir on the host is '$state', not an absent, empty or '$marker'-marked directory."
        exit 1 ;;
esac

echo "Deploying ${#paths[@]} path(s) to ~/$dir (destination was: $state)."
rsync -av --delete "${excludes[@]}" -e ssh "${paths[@]}" "$target:~/$dir/"
