#!/usr/bin/env bash
# Copy a pre-approved server-side branding bundle into an application's public directory.
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: install-branding.sh <app-dir> <source> <file>..." >&2
    exit 2
fi

app_dir=$1
source_directory=$2
shift 2

case $app_dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain, non-hidden name under the account home." >&2
        exit 2 ;;
esac
case $source_directory in
    .config/*) ;;
    *) echo "::error::branding-source must be a path below .config in the account home." >&2; exit 2 ;;
esac
case $source_directory in
    *..* | *[!A-Za-z0-9._/-]*)
        echo "::error::branding-source contains an unsafe path component." >&2
        exit 2 ;;
esac

app="$HOME/$app_dir"
source="$HOME/$source_directory"
public="$app/public"
[ -d "$app" ] && [ ! -L "$app" ] || { echo "::error::Application directory is missing or aliased." >&2; exit 1; }
[ -d "$public" ] && [ ! -L "$public" ] || { echo "::error::Application public directory is missing or aliased." >&2; exit 1; }

current=$HOME
IFS=/ read -r -a source_components <<<"$source_directory"
for component in "${source_components[@]}"; do
    current="$current/$component"
    [ ! -L "$current" ] || { echo "::error::branding-source must not traverse a symlink." >&2; exit 1; }
done
[ -d "$source" ] && [ ! -L "$source" ] || { echo "::error::Private branding source is missing or aliased." >&2; exit 1; }

files=()
for file in "$@"; do
    case $file in
        '' | .* | *[!A-Za-z0-9._-]*)
            echo "::error::Branding files must be plain, non-hidden file names." >&2
            exit 2 ;;
    esac
    candidate="$source/$file"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -s "$candidate" ] \
        || { echo "::error::Required private branding file '$file' is missing, empty, or aliased." >&2; exit 1; }
    files+=("$file")
done

destination="$public/branding"
[ ! -L "$destination" ] || { echo "::error::public/branding must not be a symlink." >&2; exit 1; }
install -d -m 755 "$destination"

temporary=''
trap '[ -z "$temporary" ] || rm -f "$temporary"' EXIT
for file in "${files[@]}"; do
    temporary=$(mktemp "$destination/.deploy-XXXXXX")
    install -m 644 "$source/$file" "$temporary"
    mv -f "$temporary" "$destination/$file"
    temporary=''
done

for file in "${files[@]}"; do
    [ -f "$destination/$file" ] && [ ! -L "$destination/$file" ] && [ -s "$destination/$file" ] \
        || { echo "::error::Branding file '$file' was not installed correctly." >&2; exit 1; }
done
echo "Installed ${#files[@]} private branding file(s)."
