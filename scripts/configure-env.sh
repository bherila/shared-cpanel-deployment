#!/usr/bin/env bash
#
# Install and check an application's .env.
#
# Runs ON THE HOST, fed over SSH by the action:
#
#   ssh <target> "bash -s -- $(printf '%q ' <app-dir> <source> <op>...)" < scripts/configure-env.sh
#
#   <app-dir>  The application's directory under $HOME.
#   <source>   A file under $HOME installed as .env (mode 600) first, or '' to keep the existing .env.
#   <op>...    SET:KEY=value  set KEY, replacing an existing assignment or appending one
#              REQUIRE:KEY    fail unless KEY is assigned a non-empty value
#
# Every SET is applied to a copy; the live .env is replaced only when something changed, after the
# previous one is saved to ~/.env-backups/<app-dir>/ (outside the deploy directory, where rsync
# --delete would remove it). Values are never printed. REQUIRE checks run after the SETs, so a deploy
# stops here, before any migration, when a key the application needs is missing.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: configure-env.sh <app-dir> <source> [SET:KEY=value | REQUIRE:KEY]..." >&2
    exit 2
fi

app_dir=$1
source_file=$2
shift 2

case $app_dir in
    '' | . | .. | .* | *[!A-Za-z0-9._-]*)
        echo "::error::The application directory must be a plain directory name under the account home." >&2
        exit 2 ;;
esac

valid_key() {
    case $1 in
        '' | [!A-Z_]* | *[!A-Z0-9_]*) return 1 ;;
    esac
}

app="$HOME/$app_dir"
if [ ! -d "$app" ]; then
    echo "::error::~/$app_dir does not exist on the host." >&2
    exit 1
fi

if [ -n "$source_file" ]; then
    case $source_file in
        /* | *..*) echo "::error::env-source must be a path under the account home without '..'." >&2; exit 2 ;;
    esac
    if [ ! -f "$HOME/$source_file" ]; then
        echo "::error::env-source ~/$source_file does not exist on the host." >&2
        exit 1
    fi
    install -m 600 "$HOME/$source_file" "$app/.env"
    echo "Installed .env from ~/$source_file."
fi

if [ ! -f "$app/.env" ]; then
    echo "::error::~/$app_dir/.env does not exist. Create it on the host or set env-source." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$app/.env" "$work/next"

requires=()
for op in "$@"; do
    case $op in
        SET:*)
            assignment=${op#SET:}
            key=${assignment%%=*}
            value=${assignment#*=}
            if [ "$key" = "$assignment" ] || ! valid_key "$key"; then
                echo "::error::'${key}' is not a valid .env key (A-Z, 0-9, _), or the pair has no '='." >&2
                exit 2
            fi
            case $value in
                *$'\n'*) echo "::error::The value for $key contains a newline." >&2; exit 2 ;;
            esac
            # Quote anything dotenv would otherwise split, and escape what double quotes interpret.
            case $value in
                *[[:space:]#\"\'\\\$]*)
                    escaped=${value//\\/\\\\}
                    escaped=${escaped//\"/\\\"}
                    escaped=${escaped//\$/\\\$}
                    rendered="$key=\"$escaped\"" ;;
                *) rendered="$key=$value" ;;
            esac
            printf '%s\n' "$rendered" >"$work/line"
            awk -v key="$key" '
                FNR == NR { line = $0; next }
                $0 ~ "^(export[ \t]+)?" key "[ \t]*=" { if (!done) print line; done = 1; next }
                { print }
                END { if (!done) print line }
            ' "$work/line" "$work/next" >"$work/tmp"
            mv "$work/tmp" "$work/next"
            echo "Set $key." ;;
        REQUIRE:*)
            key=${op#REQUIRE:}
            if ! valid_key "$key"; then
                echo "::error::'$key' is not a valid .env key." >&2
                exit 2
            fi
            requires+=("$key") ;;
        *)
            echo "::error::Unknown operation '${op%%:*}'." >&2
            exit 2 ;;
    esac
done

if ! cmp -s "$app/.env" "$work/next"; then
    backups="$HOME/.env-backups/$app_dir"
    install -d -m 700 "$HOME/.env-backups" "$backups"
    backup="$backups/.env-$(date -u +%Y%m%dT%H%M%SZ)"
    install -m 600 "$app/.env" "$backup"
    install -m 600 "$work/next" "$app/.env"
    # Keep the ten most recent.
    find "$backups" -maxdepth 1 -type f -name '.env-*' | sort -r | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done
    echo "Updated .env (previous saved to $backup)."
fi

missing=()
for key in ${requires[@]+"${requires[@]}"}; do
    if ! grep -Eq "^(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*[^[:space:]#]" "$app/.env" \
        || grep -Eq "^(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*(\"\"|'')[[:space:]]*$" "$app/.env"; then
        missing+=("$key")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error::~/$app_dir/.env is missing a value for: ${missing[*]}" >&2
    exit 1
fi

echo ".env checked: ${#requires[@]} required key(s) present."
