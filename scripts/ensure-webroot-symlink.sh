#!/usr/bin/env bash
#
# Make ~/<link-name> a symlink to <app-dir>/public.
#
# Runs ON THE HOST: ssh <target> "bash -s -- <app-dir> <link-name>" < scripts/ensure-webroot-symlink.sh
#
# A symlink is created, or repointed when it points elsewhere. A real file or directory at that name is
# never removed: it may be another site's document root, or an AutoSSL challenge directory, so the
# deploy fails and says so instead.
# shellcheck disable=SC2088 # "~/" in messages is display text, not a path to expand.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: ensure-webroot-symlink.sh <app-dir> <link-name>" >&2
    exit 2
fi

app_dir=$1
link_name=$2

for pair in "application directory:$app_dir" "webroot symlink:$link_name"; do
    value=${pair#*:}
    case $value in
        '' | . | .. | .* | *[!A-Za-z0-9._-]*)
            echo "::error::The ${pair%%:*} '$value' must be a plain name under the account home." >&2
            exit 2 ;;
    esac
done

case $link_name in
    public_html | www)
        echo "::error::Refusing to manage ~/$link_name: it is the account's main document root." >&2
        exit 2 ;;
esac

cd "$HOME"
want="$app_dir/public"

if [ ! -d "$want" ]; then
    echo "::error::~/$want does not exist, so ~/$link_name would point nowhere." >&2
    exit 1
fi

if [ -L "$link_name" ]; then
    current=$(readlink "$link_name")
    if [ "$current" = "$want" ]; then
        echo "~/$link_name already points to $want."
        exit 0
    fi
    ln -sfn "$want" "$link_name"
    echo "Repointed ~/$link_name from $current to $want."
elif [ -e "$link_name" ]; then
    echo "::error::~/$link_name is a real file or directory, not a symlink. Move it aside by hand; the deploy will not delete it." >&2
    exit 1
else
    ln -s "$want" "$link_name"
    echo "Created ~/$link_name -> $want."
fi
