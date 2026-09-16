#!/usr/bin/env bash
# Manage one application's versioned releases on the cPanel host.
#
# Usage:
#   atomic-release.sh begin <app> <release> <commit> <lock-seconds> <retain> <failure-policy> <initial-live-commit> <path>...
#   atomic-release.sh capacity <app> <release> <required-kib>
#   atomic-release.sh quiesce <app> <release> <php>
#   atomic-release.sh prepare <app> <release> <php>
#   atomic-release.sh preflight <app> <release> <webroot-name>
#   atomic-release.sh risk <app> <release> <php>
#   atomic-release.sh activate <app> <release> <php>
#   atomic-release.sh serve <app> <release> <php>
#   atomic-release.sh commit <app> <release> <php>
#   atomic-release.sh finalize <app> <release> <php>
#
# The stable ~/app path is never changed to a candidate until every candidate
# command has passed. State is kept outside releases so an always() finalizer
# can recover and report the actual selected code after any failed phase.
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: atomic-release.sh <command> <app> <release> [...]" >&2
    exit 2
fi

command=$1
app_name=$2
release_id=$3
shift 3

plain_name() {
    case $1 in
        '' | . | .. | .* | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

plain_name "$app_name" || {
    echo "::error::The application name must be a plain, non-hidden account-home name." >&2
    exit 2
}
plain_name "$release_id" || {
    echo "::error::The release id must contain only letters, numbers, dot, underscore and hyphen." >&2
    exit 2
}

case $app_name in
    public_html | www | web | mail | etc | logs | tmp | ssl | cache | bin | lib | perl5 | access-logs | lscache | backups)
        echo "::error::The application name belongs to cPanel or is a webroot." >&2
        exit 2 ;;
esac

control="$HOME/.deployments/$app_name"
releases="$control/releases"
shared="$control/shared"
state_root="$control/state"
recovery_root="$control/recovery"
transaction="$state_root/$release_id"
lock="$control/deploy.lock"
stable="$HOME/$app_name"
candidate="$releases/$release_id"

read_value() {
    local name=$1
    [ -f "$transaction/$name" ] || return 1
    IFS= read -r REPLY <"$transaction/$name"
}

write_value() {
    local name=$1 value=$2 temporary
    temporary=$(mktemp "$transaction/.${name}.XXXXXX")
    printf '%s\n' "$value" >"$temporary"
    mv -f "$temporary" "$transaction/$name"
}

require_owner() {
    if [ ! -d "$transaction" ] || [ ! -f "$lock/owner" ] || [ "$(cat "$lock/owner")" != "$release_id" ]; then
        echo "::error::Release '$release_id' does not own the deployment transaction for $app_name." >&2
        exit 1
    fi
}

validate_persistent_path() {
    local path=$1
    case $path in
        '' | . | .. | /* | */ | *//* | .* | */.* | *..* | *[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    case $path in
        artisan | composer.json | composer.lock | package.json | package-lock.json | yarn.lock | pnpm-lock.yaml | vite.config.* | webpack.mix.js | phpunit.xml | phpunit.xml.dist | \
        app | app/* | bootstrap | bootstrap/* | config | config/* | routes | routes/* | resources | resources/* | vendor | vendor/* | \
        public | public/index.php | public/.htaccess | public/build | public/build/* | \
        database | database/migrations | database/migrations/* | database/seeders | database/seeders/* | database/factories | database/factories/* | \
        *.sqlite | *.sqlite-journal | *.sqlite-wal | *.sqlite-shm)
            return 1 ;;
    esac
}

ensure_real_dir() {
    local path=$1 mode=${2:-700}
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
        echo "::error::Control path '$path' must be a real directory, never a symlink." >&2
        return 1
    fi
    if [ ! -d "$path" ]; then
        install -d -m "$mode" "$path"
    fi
    if [ ! -d "$path" ] || [ -L "$path" ]; then
        echo "::error::Could not establish real directory '$path'." >&2
        return 1
    fi
}

# Refuse symlink or non-directory ancestors before any persistent-path mutation.
# The leaf itself may be a file, directory, symlink, or absent and is checked by
# the caller. Missing ancestors are created only after the existing prefix has
# been proven safe.
ensure_safe_ancestors() {
    local root=$1 relative=$2 create=${3:-false} current part parent
    current=$root
    if [ ! -d "$root" ] || [ -L "$root" ]; then
        echo "::error::Persistent root '$root' is not a real directory." >&2
        return 1
    fi
    parent=${relative%/*}
    [ "$parent" != "$relative" ] || return 0
    IFS=/ read -r -a parts <<<"$parent"
    for part in "${parts[@]}"; do
        current="$current/$part"
        if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
            echo "::error::Persistent path '$relative' traverses unsafe ancestor '$current'." >&2
            return 1
        fi
        if [ ! -d "$current" ]; then
            [ "$create" = true ] || return 0
            install -d -m 700 "$current"
        fi
    done
}

assert_no_overlaps() {
    local paths=() path seen
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        validate_persistent_path "$path" || {
            echo "::error::Persistent path '$path' is unsafe or is release code rather than runtime data." >&2
            exit 2
        }
        for seen in "${paths[@]+"${paths[@]}"}"; do
            case "$path/" in "$seen/"*) echo "::error::Persistent paths '$seen' and '$path' overlap." >&2; exit 2 ;; esac
            case "$seen/" in "$path/"*) echo "::error::Persistent paths '$path' and '$seen' overlap." >&2; exit 2 ;; esac
        done
        paths+=("$path")
    done
}

selected_target() {
    if [ -L "$stable" ]; then
        readlink "$stable"
    elif [ -d "$stable" ] && [ -f "$stable/artisan" ]; then
        printf '%s\n' legacy
    elif [ ! -e "$stable" ]; then
        printf '%s\n' none
    else
        printf '%s\n' invalid
    fi
}

validate_release_target() {
    local target=$1 release
    case $target in
        ".deployments/$app_name/releases/"*) ;;
        *) return 1 ;;
    esac
    release=${target##*/}
    plain_name "$release" || return 1
    [ "$target" = ".deployments/$app_name/releases/$release" ] || return 1
    [ -d "$HOME/$target" ] && [ ! -L "$HOME/$target" ] && [ -f "$HOME/$target/artisan" ]
}

validate_memory_limit() {
    local memory=${1:-}
    if [ -n "$memory" ] && [ "$memory" != -1 ] && [[ ! $memory =~ ^[1-9][0-9]*[KMGkmg]$ ]]; then
        echo "::error::Invalid atomic PHP memory limit '$memory'." >&2
        return 2
    fi
}

run_php() {
    local php=$1 memory=$2
    shift 2
    if [ -n "$memory" ]; then "$php" -d "memory_limit=$memory" "$@"; else "$php" "$@"; fi
}

artisan_mode() {
    local php=$1 root=$2 mode=$3 memory=${4:-}
    [ -x "$php" ] || { echo "::error::PHP binary '$php' is not executable." >&2; return 1; }
    [ -f "$root/artisan" ] || { echo "::error::$root has no artisan file." >&2; return 1; }
    validate_memory_limit "$memory" || return
    (cd "$root" && run_php "$php" "$memory" artisan "$mode" --no-ansi)
}

write_release_metadata() {
    local root=$1 release=$2 commit=$3 existing_release existing_commit temporary
    if [ -f "$root/.deploy-release" ]; then
        existing_release=$(sed -n 's/^release=//p' "$root/.deploy-release" | head -1)
        existing_commit=$(sed -n 's/^commit=//p' "$root/.deploy-release" | head -1)
        if [ "$existing_release" != "$release" ] || [ "$existing_commit" != "$commit" ]; then
            echo "::error::Release metadata in '$root' does not match the recovery transaction." >&2
            return 1
        fi
        return 0
    fi
    temporary=$(mktemp "$root/.deploy-release.XXXXXX")
    printf 'release=%s\ncommit=%s\ncreated_at=%s\n' "$release" "$commit" "$(date -u +%FT%TZ)" >"$temporary"
    chmod 644 "$temporary"
    mv -f "$temporary" "$root/.deploy-release"
}

maintenance_state() {
    local php=$1 root=$2 memory=${3:-}
    [ -x "$php" ] || { echo "::error::PHP binary '$php' is not executable." >&2; return 2; }
    if [ ! -f "$root/vendor/autoload.php" ] || [ ! -f "$root/bootstrap/app.php" ]; then
        echo "::error::Cannot bootstrap Laravel to determine maintenance state in '$root'." >&2
        return 2
    fi
    validate_memory_limit "$memory" || return
    # This is PHP source, not shell interpolation.
    # shellcheck disable=SC2016
    (cd "$root" && run_php "$php" "$memory" -r '
        require "vendor/autoload.php";
        $app = require "bootstrap/app.php";
        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
        exit($app->isDownForMaintenance() ? 0 : 1);
    ')
}

require_maintenance() {
    local php=$1 root=$2 memory=${3:-} status=0
    maintenance_state "$php" "$root" "$memory" || status=$?
    if [ "$status" -eq 0 ]; then return 0; fi
    if [ "$status" -eq 1 ]; then
        echo "::error::Laravel did not report maintenance mode for '$root'." >&2
    else
        echo "::error::Laravel maintenance state could not be determined for '$root'." >&2
    fi
    return 1
}

require_serving() {
    local php=$1 root=$2 memory=${3:-} status=0
    maintenance_state "$php" "$root" "$memory" || status=$?
    if [ "$status" -eq 1 ]; then return 0; fi
    if [ "$status" -eq 0 ]; then
        echo "::error::Laravel still reports maintenance mode for '$root'." >&2
    else
        echo "::error::Laravel serving state could not be determined for '$root'." >&2
    fi
    return 1
}

switch_stable() {
    local target=$1 temporary="$HOME/.${app_name}.next-$release_id"
    validate_release_target "$target" || {
        echo "::error::Refusing to select invalid release target '$target'." >&2
        return 1
    }
    if [ -e "$temporary" ] || [ -L "$temporary" ]; then
        echo "::error::Temporary activation path '$temporary' already exists." >&2
        return 1
    fi
    ln -s "$target" "$temporary"
    if [ -L "$stable" ]; then
        mv -Tf "$temporary" "$stable"
    elif [ ! -e "$stable" ]; then
        mv "$temporary" "$stable"
    else
        rm -f "$temporary"
        echo "::error::Stable path is not a symlink during activation." >&2
        return 1
    fi
}

with_cron_lock() {
    local callback=$1
    if ! command -v crontab >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
        echo "::error::Atomic migration safety requires crontab and flock on the host." >&2
        return 1
    fi
    exec 9>"$HOME/.crontab-deploy.lock"
    flock -w 120 9 || { echo "::error::Could not acquire the shared crontab lock." >&2; return 1; }
    "$callback"
}

read_crontab() {
    local destination=$1 error_file=$2
    if crontab -l >"$destination" 2>"$error_file"; then
        return 0
    fi
    if grep -qi 'no crontab for' "$error_file"; then
        : >"$destination"
        return 0
    fi
    cat "$error_file" >&2
    return 1
}

filter_app_cron() {
    local source=$1 kept=$2 owned=$3
    awk \
        -v quoted_literal='cd "$HOME/'"$app_name"'"' \
        -v bare_literal='cd $HOME/'"$app_name" \
        -v quoted_expanded="cd \"$HOME/$app_name\"" \
        -v bare_expanded="cd $HOME/$app_name" \
        -v owned="$owned" \
        'BEGIN { ORS="\n" }
         function shell_boundary(character) {
             return character == "" || character ~ /[[:space:];&|()<>]/
         }
         function contains_cd(line, token, offset, relative, start, before, after) {
             offset = 1
             while ((relative = index(substr(line, offset), token)) != 0) {
                 start = offset + relative - 1
                 before = start == 1 ? "" : substr(line, start - 1, 1)
                 after = substr(line, start + length(token), 1)
                 if (shell_boundary(before) && shell_boundary(after)) return 1
                 offset = start + 1
             }
             return 0
         }
         {
             belongs = contains_cd($0, quoted_literal) || contains_cd($0, bare_literal) ||
                 contains_cd($0, quoted_expanded) || contains_cd($0, bare_expanded)
             if (belongs) print > owned; else print > "/dev/stdout"
         }' "$source" >"$kept"
    [ -f "$owned" ] || : >"$owned"
}

pause_cron_impl() {
    local work current kept owned error_file
    work=$(mktemp -d)
    current="$work/current"; kept="$work/kept"; owned="$work/owned"; error_file="$work/error"
    read_crontab "$current" "$error_file" || { rm -rf "$work"; return 1; }
    filter_app_cron "$current" "$kept" "$owned"
    if [ ! -f "$transaction/cron-owned" ]; then
        cp "$owned" "$transaction/cron-owned"
    fi
    if ! cmp -s "$current" "$kept"; then
        crontab "$kept"
        crontab -l | cmp -s - "$kept" || { rm -rf "$work"; echo "::error::Paused crontab did not read back exactly." >&2; return 1; }
    fi
    rm -rf "$work"
    write_value cron_paused true
}

pause_cron() {
    with_cron_lock pause_cron_impl
}

restore_cron_impl() {
    local work current kept ignored error_file next
    [ -f "$transaction/cron-owned" ] || return 0
    work=$(mktemp -d)
    current="$work/current"; kept="$work/kept"; ignored="$work/ignored"; error_file="$work/error"; next="$work/next"
    read_crontab "$current" "$error_file" || { rm -rf "$work"; return 1; }
    filter_app_cron "$current" "$kept" "$ignored"
    cat "$kept" "$transaction/cron-owned" >"$next"
    if ! cmp -s "$current" "$next"; then
        crontab "$next"
        crontab -l | cmp -s - "$next" || { rm -rf "$work"; echo "::error::Restored crontab did not read back exactly." >&2; return 1; }
    fi
    rm -rf "$work"
    write_value cron_paused false
}

restore_cron() {
    with_cron_lock restore_cron_impl
}

nearest_real_parent() {
    local path=$1
    while [ ! -e "$path" ] && [ ! -L "$path" ]; do path=${path%/*}; done
    if [ ! -d "$path" ] || [ -L "$path" ]; then
        echo "::error::Nearest existing parent '$path' is not a real directory." >&2
        return 1
    fi
    printf '%s\n' "$path"
}

report_status() {
    local php=${1:-} memory=${2:-} target live_root release commit state maintenance_status=0
    target=$(selected_target)
    case $target in
        none) release=none; commit=none; state=absent ;;
        invalid) release=invalid; commit=unknown; state=unavailable ;;
        legacy)
            release=legacy; commit=unknown
            if [ -f "$stable/.deploy-release" ]; then
                commit=$(sed -n 's/^commit=//p' "$stable/.deploy-release" | head -1)
                [ -n "$commit" ] || commit=unknown
            elif [ -f "$transaction/initial_live_commit" ]; then
                commit=$(head -1 "$transaction/initial_live_commit")
                [ -n "$commit" ] || commit=unknown
            elif [ -f "$control/legacy-live-commit" ] && [ ! -L "$control/legacy-live-commit" ]; then
                commit=$(head -1 "$control/legacy-live-commit")
                [ -n "$commit" ] || commit=unknown
            fi
            if [ -n "$php" ]; then
                maintenance_state "$php" "$stable" "$memory" || maintenance_status=$?
                case $maintenance_status in 0) state=maintenance ;; 1) state=serving ;; *) state=unavailable ;; esac
            elif [ -f "$stable/storage/framework/down" ]; then state=maintenance; else state=serving; fi ;;
        *)
            if validate_release_target "$target"; then
                live_root="$HOME/$target"
                release=${target##*/}
                commit=unknown
                if [ -f "$live_root/.deploy-release" ]; then
                    commit=$(sed -n 's/^commit=//p' "$live_root/.deploy-release" | head -1)
                    [ -n "$commit" ] || commit=unknown
                fi
                if [ -n "$php" ]; then
                    maintenance_state "$php" "$live_root" "$memory" || maintenance_status=$?
                    case $maintenance_status in 0) state=maintenance ;; 1) state=serving ;; *) state=unavailable ;; esac
                elif [ -f "$live_root/storage/framework/down" ]; then state=maintenance; else state=serving; fi
            else
                release=invalid; commit=unknown; state=unavailable
            fi ;;
    esac
    printf 'live_release=%s\nlive_commit=%s\nlive_state=%s\n' "$release" "$commit" "$state"
    echo "Selected release: $release ($commit); state: $state."
    [ "$state" != unavailable ]
}

preflight() {
    [ "$#" -eq 1 ] || { echo "usage: ... preflight <app> <release> <webroot-name-or-empty>" >&2; exit 2; }
    local webroot=$1 selected selected_root stable_device release_device path source shared_path shared_state type available source_device destination_parent destination_device source_real destination_real inventory
    require_owner
    if [ ! -d "$candidate" ] || [ -L "$candidate" ] || [ ! -f "$candidate/artisan" ]; then
        echo "::error::Candidate release is not a real Laravel directory after upload." >&2
        exit 1
    fi
    selected=$(selected_target)
    echo "Preflight stable selection: $selected"
    if [ "$selected" = legacy ]; then echo 'conversion_required=true'; else echo 'conversion_required=false'; fi
    if [ "$selected" = none ]; then echo 'existing_release=false'; else echo 'existing_release=true'; fi
    if [ "$selected" != none ] && [ "$selected" != invalid ]; then
        if [ "$selected" = legacy ]; then
            echo "Preflight stable path: real legacy directory $stable"
        else
            echo "Preflight stable path: $stable -> $selected (resolved $(readlink -f "$stable"))"
        fi
    fi
    [ "$selected" != invalid ] || { echo "::error::Stable application path has an unsupported type." >&2; exit 1; }
    if [ "$selected" = legacy ] && { [ -e "$stable/.deploy-release" ] || [ -L "$stable/.deploy-release" ]; }; then
        echo "::error::Legacy application contains reserved .deploy-release metadata; resolve it before atomic conversion." >&2
        exit 1
    fi
    case $selected in legacy) selected_root=$stable ;; none) selected_root= ;; *) selected_root="$HOME/$selected" ;; esac

    stable_device=$(stat -c %d "$HOME")
    release_device=$(stat -c %d "$candidate")
    [ "$stable_device" = "$release_device" ] || {
        echo "::error::Stable and release paths are on different filesystems; atomic rename is unavailable." >&2
        exit 1
    }
    echo "Preflight filesystem device: $release_device (stable and releases match)."

    inventory=$(mktemp "$transaction/.persistent-original.XXXXXX")
    trap 'rm -f "$inventory"' RETURN
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        if [ -n "$selected_root" ]; then source="$selected_root/$path"; else source="$stable/$path"; fi
        shared_path=$shared/$path
        ensure_safe_ancestors "$shared" "$path" false
        if [ -n "$selected_root" ]; then ensure_safe_ancestors "$selected_root" "$path" false; fi
        ensure_safe_ancestors "$candidate" "$path" false
        if [ -L "$source" ]; then type="symlink -> $(readlink "$source") (resolved $(readlink -f "$source"))"
        elif [ -d "$source" ]; then type=directory
        elif [ -f "$source" ]; then type='file'
        elif [ -e "$source" ]; then type=other
        else type=absent
        fi
        if [ -e "$shared_path" ] || [ -L "$shared_path" ]; then shared_state=present; else shared_state=absent; fi
        echo "Preflight persistent path $path: live=$type; shared=$shared_state."
        if [ "$type" = absent ]; then printf '%s\tabsent\n' "$path" >>"$inventory"; else printf '%s\tpresent\n' "$path" >>"$inventory"; fi
        [ "$type" != other ] || { echo "::error::Persistent path '$path' has an unsupported live type." >&2; exit 1; }
        [ ! -L "$shared_path" ] || { echo "::error::Managed shared path '$shared_path' must never be a symlink." >&2; exit 1; }
        if [ -L "$source" ]; then
            source_real=$(readlink -f "$source" || true)
            destination_real=$(readlink -f "$shared_path" || true)
            if [ -z "$source_real" ] || [ -z "$destination_real" ] || [ "$source_real" != "$destination_real" ]; then
                echo "::error::Live persistent symlink '$source' is dangling or does not resolve to '$shared_path'." >&2
                exit 1
            fi
        elif [ -e "$source" ]; then
            if [ -e "$shared_path" ] || [ -L "$shared_path" ]; then
                echo "::error::Both live '$source' and managed '$shared_path' exist; refusing to choose or delete either copy." >&2
                exit 1
            fi
            destination_parent=$(nearest_real_parent "${shared_path%/*}")
            source_device=$(stat -c %d "$source")
            destination_device=$(stat -c %d "$destination_parent")
            [ "$source_device" = "$destination_device" ] || {
                echo "::error::Persistent '$path' and its managed destination are on different filesystems; explicit migration is required." >&2
                exit 1
            }
        fi
    done <"$transaction/persistent-paths"

    if [ -n "$webroot" ]; then
        plain_name "$webroot" || { echo "::error::webroot-symlink must be a plain account-home name." >&2; exit 2; }
        [ "$webroot" != "$app_name" ] || {
            echo "::error::webroot-symlink must not equal deploy-dir; that would replace the stable release link." >&2
            exit 2
        }
        if [ -L "$HOME/$webroot" ]; then
            echo "Preflight webroot: ~/$webroot -> $(readlink "$HOME/$webroot") (resolved $(readlink -f "$HOME/$webroot"))."
        elif [ -e "$HOME/$webroot" ]; then
            echo "::error::~/$webroot is a real path and cannot be managed as a webroot symlink." >&2
            exit 1
        else
            echo "Preflight webroot: ~/$webroot is absent and will be created after activation."
        fi
    fi

    available=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
    echo "Preflight disk: candidate=$(du -sk "$candidate" | awk '{print $1}') KiB; account filesystem available=${available:-unknown} KiB."
    if command -v quota >/dev/null 2>&1; then
        quota -s 2>/dev/null | sed -n '1,4p' | sed 's/^/Preflight quota: /' || true
    fi
    mv -f "$inventory" "$transaction/persistent-original"
    trap - RETURN
    write_value phase preflight
}

capacity() {
    [ "$#" -eq 1 ] || { echo "usage: ... capacity <app> <release> <required-kib>" >&2; exit 2; }
    local required=$1 available reserve=262144 needed quota_line quota_remaining
    require_owner
    [[ $required =~ ^[1-9][0-9]*$ ]] || { echo "::error::Required candidate size must be positive KiB." >&2; exit 2; }
    available=$(df -Pk "$control" | awk 'NR == 2 { print $4 }')
    [[ $available =~ ^[0-9]+$ ]] || { echo "::error::Could not determine remote free disk space." >&2; exit 1; }
    needed=$((required * 2 + reserve))
    echo "Pre-upload capacity: local candidate=${required} KiB; remote available=${available} KiB; required with staging reserve=${needed} KiB."
    [ "$available" -ge "$needed" ] || {
        echo "::error::Insufficient remote disk headroom for upload and safe staging." >&2
        exit 1
    }
    if command -v quota >/dev/null 2>&1; then
        quota_line=$(quota -w 2>/dev/null | awk '$2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { limit=($4>0?$4:$3); if (limit>0) { print limit-$2; exit } }' || true)
        if [[ $quota_line =~ ^-?[0-9]+$ ]]; then
            quota_remaining=$quota_line
            echo "Pre-upload quota remaining: ${quota_remaining} KiB."
            [ "$quota_remaining" -ge "$needed" ] || { echo "::error::Account quota has insufficient headroom." >&2; exit 1; }
        else
            echo "Pre-upload quota: installed but no reliable numeric account limit was reported."
        fi
    else
        echo "Pre-upload quota: quota command unavailable; filesystem gate enforced."
    fi
    write_value phase capacity_checked
}

begin() {
    if [ "$#" -lt 6 ]; then
        echo "usage: ... begin <app> <release> <commit> <lock-seconds> <retain> <failure-policy> <initial-live-commit> <path>..." >&2
        exit 2
    fi
    local commit=$1 lock_seconds=$2 retain=$3 failure_policy=$4 initial_live_commit=$5 legacy_commit_temp
    shift 5
    [[ $commit =~ ^[0-9A-Fa-f]{7,64}$ ]] || { echo "::error::Source commit must be a 7-64 digit hexadecimal revision." >&2; exit 2; }
    [[ $lock_seconds =~ ^[1-9][0-9]*$ ]] || { echo "::error::deploy-lock-timeout must be positive seconds." >&2; exit 2; }
    if [[ ! $retain =~ ^[0-9]+$ ]] || [ "$retain" -lt 2 ]; then echo "::error::retain-releases must be at least 2." >&2; exit 2; fi
    case $failure_policy in maintenance | rollback) ;; *) echo "::error::failure-policy must be maintenance or rollback." >&2; exit 2 ;; esac
    if [ -n "$initial_live_commit" ] && [[ ! $initial_live_commit =~ ^[0-9A-Fa-f]{7,64}$ ]]; then
        echo "::error::initial-live-commit must be empty or a 7-64 digit hexadecimal revision." >&2
        exit 2
    fi
    [ "$#" -gt 0 ] || { echo "::error::Atomic deployments require at least one persistent path." >&2; exit 2; }
    printf '%s\n' "$@" | assert_no_overlaps

    ensure_real_dir "$HOME/.deployments"
    ensure_real_dir "$control"
    ensure_real_dir "$releases"
    ensure_real_dir "$shared"
    ensure_real_dir "$state_root"
    ensure_real_dir "$recovery_root"

    local now acquired=false
    now=$(date +%s)
    if mkdir "$lock" 2>/dev/null; then acquired=true; fi
    [ "$acquired" = true ] || {
        echo "::error::Another deployment owns $app_name's remote lock; automatic stale takeover is intentionally disabled." >&2
        [ -f "$lock/owner" ] && echo "Lock owner: $(cat "$lock/owner")" >&2
        echo "Verify that the owning run and all remote PHP processes have stopped before manually recovering this lock." >&2
        exit 1
    }
    printf '%s\n' "$release_id" >"$lock/owner"
    printf '%s\n' "$now" >"$lock/started"
    printf '%s\n' "$lock_seconds" >"$lock/requested-timeout"

    if [ -e "$transaction" ] || [ -e "$candidate" ] || [ -L "$candidate" ]; then
        rm -rf "$lock"
        echo "::error::Release '$release_id' already exists; use a unique run attempt." >&2
        exit 1
    fi
    if ! install -d -m 700 "$transaction" || ! install -d -m 755 "$candidate"; then
        if [ -f "$lock/owner" ] && [ "$(cat "$lock/owner")" = "$release_id" ]; then rm -rf "$lock"; fi
        rm -rf "$transaction" "$candidate"
        echo "::error::Could not initialize the deployment transaction." >&2
        exit 1
    fi
    printf '%s\n' "$@" >"$transaction/persistent-paths"
    write_value commit "$commit"
    write_value retain "$retain"
    write_value failure_policy "$failure_policy"
    write_value initial_live_commit "$initial_live_commit"
    write_value risk_started false
    write_value recovery_required false
    write_value activated false
    write_value committed false
    write_value previous_was_maintenance false
    write_value phase begun

    local selected
    selected=$(selected_target)
    case $selected in
        none) write_value previous_target "$selected" ;;
        legacy)
            if [ -z "$initial_live_commit" ]; then
                rm -rf "$candidate" "$transaction" "$lock"
                echo "::error::initial-live-commit is required when converting an existing in-place deployment." >&2
                exit 1
            fi
            if [ -L "$control/legacy-live-commit" ] || { [ -e "$control/legacy-live-commit" ] && [ ! -f "$control/legacy-live-commit" ]; }; then
                rm -rf "$candidate" "$transaction" "$lock"
                echo "::error::The trusted legacy commit record has an unsafe type." >&2
                exit 1
            fi
            legacy_commit_temp=$(mktemp "$control/.legacy-live-commit.XXXXXX")
            printf '%s\n' "$initial_live_commit" >"$legacy_commit_temp"
            chmod 600 "$legacy_commit_temp"
            mv -f "$legacy_commit_temp" "$control/legacy-live-commit"
            write_value previous_target "$selected" ;;
        invalid) rm -rf "$candidate" "$transaction" "$lock"; echo "::error::~/$app_name is neither absent, a Laravel app, nor a managed release symlink." >&2; exit 1 ;;
        *) validate_release_target "$selected" || { rm -rf "$candidate" "$transaction" "$lock"; echo "::error::Stable symlink target '$selected' is outside the managed release tree." >&2; exit 1; }; write_value previous_target "$selected" ;;
    esac
    echo "Started atomic release $release_id for $app_name; previous selection: $selected."
}

link_persistent_path() {
    local app_root=$1 path=$2 replace_source=${3:-false} destination source source_real destination_real
    destination="$shared/$path"
    source="$app_root/$path"
    ensure_safe_ancestors "$shared" "$path" true
    ensure_safe_ancestors "$app_root" "$path" true
    [ ! -L "$destination" ] || { echo "::error::Shared persistent path '$destination' must not be a symlink." >&2; return 1; }
    if [ -L "$source" ]; then
        source_real=$(readlink -f "$source" || true)
        destination_real=$(readlink -f "$destination" || true)
        if [ -z "$source_real" ] || [ -z "$destination_real" ] || [ "$source_real" != "$destination_real" ]; then
            echo "::error::Persistent path '$source' is dangling or points outside its existing managed shared path." >&2
            return 1
        fi
        return 0
    fi
    if [ ! -e "$destination" ]; then
        if [ -e "$source" ]; then mv "$source" "$destination"; else return 3; fi
    elif [ -e "$source" ] && [ "$replace_source" != true ]; then
        echo "::error::Both '$source' and '$destination' exist; refusing to choose or delete either persistent copy." >&2
        return 1
    fi
    if [ -L "$destination" ] || { [ ! -d "$destination" ] && [ ! -f "$destination" ]; }; then
        echo "::error::Shared persistent path '$destination' is not a real file or directory." >&2
        return 1
    fi
    if [ -d "$source" ] && [ ! -L "$source" ]; then rm -rf "$source"
    elif [ -f "$source" ] && [ ! -L "$source" ]; then rm -f "$source"
    elif [ -e "$source" ] || [ -L "$source" ]; then echo "::error::Cannot safely replace persistent path '$source'." >&2; return 1
    fi
    ln -s "$destination" "$source"
}

quiesce() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... quiesce <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} previous root state=0
    validate_memory_limit "$memory"
    require_owner
    case $(cat "$transaction/phase") in preflight | prepared) ;; *) echo "::error::Read-only preflight must pass before quiescing." >&2; exit 1 ;; esac
    read_value previous_target; previous=$REPLY
    if [ "$previous" != none ]; then
        if [ "$previous" = legacy ]; then root=$stable; else root="$HOME/$previous"; fi
        maintenance_state "$php" "$root" "$memory" || state=$?
        case $state in
            0) echo "::error::The selected application is already in maintenance; refusing to change intentional operator state." >&2; exit 1 ;;
            1) ;;
            *) echo "::error::Could not determine the selected application's maintenance state." >&2; exit 1 ;;
        esac
    fi
    write_value previous_was_maintenance false
    # Durable recovery intent precedes the first cron or application mutation.
    write_value recovery_required true
    write_value phase quiescing
    pause_cron
    write_value phase cron_paused
    if [ "$previous" != none ]; then
        artisan_mode "$php" "$root" down "$memory"
        require_maintenance "$php" "$root" "$memory"
    fi
    write_value phase quiesced
    echo "Quiesced $previous: application cron is paused and selected code is in maintenance."
}

prepare() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... prepare <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} previous legacy_id legacy_target legacy_root path candidate_path converted=false status source_real destination_real
    validate_memory_limit "$memory"
    require_owner
    [ -f "$candidate/artisan" ] || { echo "::error::Candidate release has no artisan file after upload." >&2; exit 1; }
    case $(cat "$transaction/phase") in preflight | quiesced) ;; *) echo "::error::Candidate is not ready for preparation." >&2; exit 1 ;; esac
    read_value previous_target; previous=$REPLY
    if [ "$previous" = legacy ] && [ "$(cat "$transaction/recovery_required")" != true ]; then
        echo "::error::Legacy conversion must be quiesced before persistent paths move." >&2
        exit 1
    fi

    if [ "$previous" = legacy ]; then
        [ "$(selected_target)" = legacy ] || { echo "::error::Stable selection changed before legacy conversion." >&2; exit 1; }
        require_maintenance "$php" "$stable" "$memory"
        legacy_id="legacy-$(date -u +%Y%m%dT%H%M%SZ)-${release_id}"
        legacy_target=".deployments/$app_name/releases/$legacy_id"
        legacy_root="$HOME/$legacy_target"
        [ ! -e "$legacy_root" ] || { echo "::error::Legacy release target already exists." >&2; exit 1; }
        write_value conversion_target "$legacy_target"
        write_value phase converting
        while IFS= read -r path || [ -n "$path" ]; do
            [ -n "$path" ] || continue
            status=0; link_persistent_path "$stable" "$path" false || status=$?
            [ "$status" -eq 0 ] || [ "$status" -eq 3 ] || exit "$status"
        done <"$transaction/persistent-paths"
        read_value initial_live_commit
        mv "$stable" "$legacy_root"
        write_release_metadata "$legacy_root" "$legacy_id" "$REPLY"
        ln -s "$legacy_target" "$stable"
        converted=true
        write_value previous_target "$legacy_target"
        previous=$legacy_target
        echo "Converted legacy ~/$app_name while keeping $legacy_id selected in maintenance."
    elif [ "$previous" != none ]; then
        legacy_root="$HOME/$previous"
        while IFS= read -r path || [ -n "$path" ]; do
            [ -n "$path" ] || continue
            ensure_safe_ancestors "$legacy_root" "$path" false
            ensure_safe_ancestors "$shared" "$path" false
            source_real=$(readlink -f "$legacy_root/$path" || true)
            destination_real=$(readlink -f "$shared/$path" || true)
            if [ ! -L "$legacy_root/$path" ] || [ -z "$source_real" ] || [ -z "$destination_real" ] || [ "$source_real" != "$destination_real" ]; then
                echo "::error::Established release ${previous##*/} does not link '$path' to existing managed shared state." >&2
                exit 1
            fi
        done <"$transaction/persistent-paths"
    fi

    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        if [ ! -e "$shared/$path" ]; then
            status=0; link_persistent_path "$candidate" "$path" true || status=$?
            if [ "$status" -eq 3 ]; then
                echo "::error::Persistent path '$path' is absent from both selected and candidate releases; its type will not be guessed." >&2
                exit 1
            elif [ "$status" -ne 0 ]; then exit "$status"; fi
        else
            candidate_path="$candidate/$path"
            ensure_safe_ancestors "$candidate" "$path" true
            ensure_safe_ancestors "$shared" "$path" false
            if [ -d "$candidate_path" ] && [ ! -L "$candidate_path" ]; then rm -rf "$candidate_path"; fi
            if [ -f "$candidate_path" ] && [ ! -L "$candidate_path" ]; then rm -f "$candidate_path"; fi
            if [ -e "$candidate_path" ] || [ -L "$candidate_path" ]; then echo "::error::Candidate persistent path '$path' cannot be replaced safely." >&2; exit 1; fi
            ln -s "$shared/$path" "$candidate_path"
        fi
    done <"$transaction/persistent-paths"

    if [ "$converted" = true ]; then
        legacy_root="$HOME/$previous"
        while IFS= read -r path || [ -n "$path" ]; do [ -n "$path" ] && link_persistent_path "$legacy_root" "$path" false; done <"$transaction/persistent-paths"
    fi
    if [ ! -f "$candidate/.env" ] && [ "$previous" != none ] && [ -f "$HOME/$previous/.env" ]; then install -m 600 "$HOME/$previous/.env" "$candidate/.env"; fi
    read_value commit
    write_release_metadata "$candidate" "$release_id" "$REPLY"
    write_value phase prepared
    echo "Prepared candidate $release_id; live selection remains $previous in maintenance."
}

risk() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... risk <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} previous current
    validate_memory_limit "$memory"
    require_owner
    case $(cat "$transaction/phase") in prepared | quiesced) ;; *) echo "::error::Candidate is not prepared and quiesced." >&2; exit 1 ;; esac
    if [ "$(cat "$transaction/recovery_required")" != true ] || [ "$(cat "$transaction/cron_paused")" != true ]; then
        echo "::error::Cannot enter the database-risk boundary before durable quiescence." >&2; exit 1
    fi
    read_value previous_target; previous=$REPLY
    current=$(selected_target)
    [ "$current" = "$previous" ] || { echo "::error::Stable selection changed after quiescence." >&2; exit 1; }
    if [ "$previous" != none ]; then require_maintenance "$php" "$HOME/$previous" "$memory"; fi
    # Record the irreversible boundary before the candidate command or any
    # subsequent hook is allowed to touch shared database state.
    write_value risk_started true
    write_value phase risk
    artisan_mode "$php" "$candidate" down "$memory"
    require_maintenance "$php" "$candidate" "$memory"
    echo "Database-risk boundary entered; selected and candidate code are in maintenance and application cron is paused."
}

activate() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... activate <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} previous current
    validate_memory_limit "$memory"
    require_owner
    [ "$(cat "$transaction/risk_started")" = true ] || { echo "::error::Cannot activate before the risk boundary." >&2; exit 1; }
    [ -f "$candidate/.deploy-release" ] || { echo "::error::Candidate release metadata is missing." >&2; exit 1; }
    read_value previous_target; previous=$REPLY
    current=$(selected_target)
    [ "$current" = "$previous" ] || { echo "::error::Stable selection changed before activation." >&2; exit 1; }
    if [ "$previous" != none ]; then require_maintenance "$php" "$HOME/$previous" "$memory"; fi
    require_maintenance "$php" "$candidate" "$memory"
    write_value phase activating
    switch_stable ".deployments/$app_name/releases/$release_id"
    write_value activated true
    write_value phase activated
    echo "Atomically selected release $release_id; it remains in maintenance until serve."
}

serve() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... serve <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} target
    validate_memory_limit "$memory"
    require_owner
    [ "$(cat "$transaction/activated")" = true ] || { echo "::error::Candidate is not selected." >&2; exit 1; }
    target=$(selected_target)
    [ "$target" = ".deployments/$app_name/releases/$release_id" ] || { echo "::error::Selected release changed before serve." >&2; exit 1; }
    # A trusted post-activation hook must leave the selected candidate down.
    # Re-prove that boundary immediately before the action's sole `artisan up`.
    require_maintenance "$php" "$candidate" "$memory"
    artisan_mode "$php" "$candidate" up "$memory"
    require_serving "$php" "$candidate" "$memory"
    write_value phase serving
    echo "Release $release_id is selected and serving; live verification may begin."
}

commit_release() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... commit <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} expected_commit recorded_commit
    validate_memory_limit "$memory"
    require_owner
    [ "$(cat "$transaction/activated")" = true ] || { echo "::error::Candidate was not activated." >&2; exit 1; }
    [ "$(cat "$transaction/phase")" = serving ] || { echo "::error::Candidate has not completed the serving transition." >&2; exit 1; }
    [ "$(selected_target)" = ".deployments/$app_name/releases/$release_id" ] || { echo "::error::Candidate is no longer selected." >&2; exit 1; }
    read_value commit; expected_commit=$REPLY
    recorded_commit=$(sed -n 's/^commit=//p' "$candidate/.deploy-release" | head -1)
    [ "$recorded_commit" = "$expected_commit" ] || { echo "::error::Candidate commit metadata changed before commit." >&2; exit 1; }
    require_serving "$php" "$candidate" "$memory"
    write_value committed true
    write_value phase committed
    echo "Committed healthy release $release_id."
}

cleanup_releases() {
    local retain live_target previous inventory item name kept=0 pending=false
    read_value retain; retain=$REPLY
    live_target=$(selected_target)
    read_value previous_target || REPLY=none
    previous=$REPLY
    inventory=$(find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -nr) || {
        echo "::error::Could not inventory retained releases." >&2
        return 1
    }
    while IFS= read -r item; do
        name=${item#* }
        plain_name "$name" || continue
        if [ -d "$state_root/$name" ] && [ "$(cat "$state_root/$name/phase" 2>/dev/null || true)" != finalized ]; then pending=true; else pending=false; fi
        if [ "$name" = "${live_target##*/}" ] || [ "$name" = "${previous##*/}" ] || [ "$pending" = true ]; then
            kept=$((kept + 1))
        elif [ "$kept" -lt "$retain" ]; then
            kept=$((kept + 1))
        else
            rm -rf "${releases:?}/$name"
            echo "Removed old release $name."
        fi
    done <<<"$inventory"
}

release_lock() {
    local unlock="$control/.unlock-${release_id}-$$"
    if [ ! -f "$lock/owner" ] || [ "$(cat "$lock/owner")" != "$release_id" ]; then
        echo "::error::Refusing to release a lock no longer owned by '$release_id'." >&2
        return 1
    fi
    mv "$lock" "$unlock" || return 1
    if [ ! -f "$unlock/owner" ] || [ "$(cat "$unlock/owner")" != "$release_id" ]; then
        echo "::error::Lock ownership changed during release." >&2
        return 1
    fi
    rm -rf "$unlock"
}

restore_cron_command() {
    [ "$#" -eq 0 ] || { echo "usage: ... restore-cron <app> <release>" >&2; exit 2; }
    require_owner
    restore_cron
    echo "Restored the application's pre-deployment cron lines."
}

preserve_cron_recovery() {
    local destination="$recovery_root/$release_id.cron" temporary
    [ -f "$transaction/cron-owned" ] || return 0
    if [ -L "$destination" ]; then
        echo "::error::Cron recovery path '$destination' has an unsafe type." >&2
        return 1
    fi
    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
        echo "::error::Cron recovery path '$destination' has an unsafe type." >&2
        return 1
    fi
    temporary=$(mktemp "$recovery_root/.${release_id}.cron.XXXXXX")
    cp "$transaction/cron-owned" "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$destination"
    echo "Preserved paused application cron for manual recovery at '$destination'."
}

repair_previous_persistence() {
    local root=$1 path source destination source_real destination_real original
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        source="$root/$path"
        destination="$shared/$path"
        original=$(awk -F '\t' -v wanted="$path" '$1 == wanted { print $2; exit }' "$transaction/persistent-original")
        case $original in present | absent) ;; *) echo "::error::Missing preflight inventory for persistent path '$path'." >&2; return 1 ;; esac
        ensure_safe_ancestors "$root" "$path" true
        ensure_safe_ancestors "$shared" "$path" false
        [ ! -L "$destination" ] || { echo "::error::Shared recovery path '$destination' is a symlink." >&2; return 1; }
        if [ -L "$source" ]; then
            source_real=$(readlink -f "$source" || true)
            destination_real=$(readlink -f "$destination" || true)
            if [ -z "$source_real" ] || [ -z "$destination_real" ] || [ "$source_real" != "$destination_real" ]; then
                echo "::error::Persistent recovery symlink '$source' is dangling or unmanaged." >&2
                return 1
            fi
        elif [ -e "$source" ]; then
            if [ -e "$destination" ]; then
                echo "::error::Both '$source' and '$destination' exist during persistence recovery." >&2
                return 1
            fi
            if [ ! -d "$source" ] && [ ! -f "$source" ]; then
                echo "::error::Persistent recovery source '$source' has an unsupported type." >&2
                return 1
            fi
        elif [ -d "$destination" ] || [ -f "$destination" ]; then
            ln -s "$destination" "$source"
            echo "Repaired persistent link '$source' after interrupted conversion."
        elif [ "$original" = absent ]; then
            :
        else
            echo "::error::Persistent path '$path' is absent from both old and shared state during recovery." >&2
            return 1
        fi
    done <"$transaction/persistent-paths"
}

finalize() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: ... finalize <app> <release> <php> [memory-limit]" >&2
        exit 2
    fi
    local php=$1 memory=${2:-} committed=false risk_started=false recovery_required=false policy=maintenance previous=none current recovery_status=0 conversion_target=
    validate_memory_limit "$memory"
    if [ ! -d "$transaction" ]; then
        if [ -f "$lock/owner" ] && [ "$(cat "$lock/owner")" = "$release_id" ]; then release_lock || true; fi
        report_status "$php" "$memory"
        return 0
    fi
    if [ ! -f "$lock/owner" ] || [ "$(cat "$lock/owner")" != "$release_id" ]; then
        echo "::warning::Transaction $release_id does not own the current lock; recovery was not attempted." >&2
        report_status "$php" "$memory"
        return 0
    fi
    read_value committed && committed=$REPLY
    read_value risk_started && risk_started=$REPLY
    read_value recovery_required && recovery_required=$REPLY
    read_value failure_policy && policy=$REPLY
    read_value previous_target && previous=$REPLY

    if [ "$committed" = true ]; then
        current=$(selected_target)
        [ "$current" = ".deployments/$app_name/releases/$release_id" ] || recovery_status=1
        if [ "$recovery_status" -eq 0 ]; then
            read_value commit
            [ "$(sed -n 's/^commit=//p' "$candidate/.deploy-release" | head -1)" = "$REPLY" ] || recovery_status=1
        fi
        if [ "$recovery_status" -eq 0 ]; then require_serving "$php" "$candidate" "$memory" || recovery_status=1; fi
        if [ "$recovery_status" -ne 0 ]; then echo "::error::Committed release no longer proves the exact selected, serving candidate." >&2; fi
    elif [ "$risk_started" = true ]; then
        if [ "$policy" = rollback ] && [ "$previous" != none ]; then
            current=$(selected_target)
            if [ "$current" = ".deployments/$app_name/releases/$release_id" ]; then
                artisan_mode "$php" "$candidate" down "$memory" || recovery_status=1
                if [ "$recovery_status" -eq 0 ]; then require_maintenance "$php" "$candidate" "$memory" || recovery_status=1; fi
                if [ "$recovery_status" -eq 0 ]; then switch_stable "$previous" || recovery_status=1; fi
            fi
            current=$(selected_target)
            if [ "$recovery_status" -eq 0 ] && [ "$current" = "$previous" ]; then
                if [ "$recovery_status" -eq 0 ]; then artisan_mode "$php" "$HOME/$previous" up "$memory" || recovery_status=1; fi
                if [ "$recovery_status" -eq 0 ]; then require_serving "$php" "$HOME/$previous" "$memory" || recovery_status=1; fi
                if [ "$recovery_status" -eq 0 ]; then restore_cron || recovery_status=1; fi
            else
                echo "::error::Rollback did not prove that the prior release is selected; refusing artisan up." >&2
                recovery_status=1
            fi
            if [ "$recovery_status" -eq 0 ]; then echo "Rolled back selection to ${previous##*/}; database changes were not rolled back."; fi
        else
            current=$(selected_target)
            if [ "$current" != none ] && [ "$current" != invalid ]; then
                if [ "$current" = legacy ]; then
                    artisan_mode "$php" "$stable" down "$memory" || recovery_status=1
                    if [ "$recovery_status" -eq 0 ]; then require_maintenance "$php" "$stable" "$memory" || recovery_status=1; fi
                else
                    artisan_mode "$php" "$HOME/$current" down "$memory" || recovery_status=1
                    if [ "$recovery_status" -eq 0 ]; then require_maintenance "$php" "$HOME/$current" "$memory" || recovery_status=1; fi
                fi
            fi
            pause_cron || { echo "::error::Could not keep application cron paused." >&2; recovery_status=1; }
            if [ "$recovery_status" -eq 0 ]; then preserve_cron_recovery || recovery_status=1; fi
            echo "Deployment failed after the risk boundary; selected code remains in maintenance."
            if [ "$previous" != none ]; then
                echo "After confirming schema compatibility, restore with: ln -sfn '$previous' '$stable' && cd '$stable' && '$php' artisan up"
            fi
        fi
    elif [ "$recovery_required" = true ]; then
        # No database-mutating phase began. Restore the exact old selection and
        # serving/cron state, including an interrupted first conversion.
        current=$(selected_target)
        if [ "$previous" = legacy ]; then
            if read_value conversion_target; then conversion_target=$REPLY; fi
            if [ -n "$conversion_target" ] && validate_release_target "$conversion_target"; then
                read_value initial_live_commit
                write_release_metadata "$HOME/$conversion_target" "${conversion_target##*/}" "$REPLY" || recovery_status=1
            fi
            if [ "$current" = none ] && [ -n "$conversion_target" ] && [ "$recovery_status" -eq 0 ]; then
                ln -s "$conversion_target" "$stable" || recovery_status=1
                if [ "$recovery_status" -eq 0 ]; then
                    previous=$conversion_target
                    write_value previous_target "$previous"
                fi
            elif [ "$current" != legacy ]; then
                previous=$current
            fi
        fi
        current=$(selected_target)
        if [ "$previous" != none ]; then
            [ "$current" = "$previous" ] || { echo "::error::Pre-risk recovery could not prove the prior selection." >&2; recovery_status=1; }
            if [ "$recovery_status" -eq 0 ]; then
                if [ "$current" = legacy ]; then repair_previous_persistence "$stable" || recovery_status=1
                else repair_previous_persistence "$HOME/$current" || recovery_status=1; fi
            fi
            if [ "$recovery_status" -eq 0 ]; then
                if [ "$current" = legacy ]; then artisan_mode "$php" "$stable" up "$memory" || recovery_status=1
                else artisan_mode "$php" "$HOME/$current" up "$memory" || recovery_status=1; fi
                if [ "$recovery_status" -eq 0 ]; then
                    if [ "$current" = legacy ]; then require_serving "$php" "$stable" "$memory" || recovery_status=1
                    else require_serving "$php" "$HOME/$current" "$memory" || recovery_status=1; fi
                fi
            fi
        fi
        if [ "$recovery_status" -eq 0 ]; then restore_cron || recovery_status=1; fi
        if [ "$recovery_status" -eq 0 ]; then echo "Recovered the pre-risk serving and cron state."; fi
    fi

    report_status "$php" "$memory" || recovery_status=1
    if [ "$recovery_status" -eq 0 ]; then
        write_value phase finalized
        cleanup_releases || recovery_status=$?
    fi
    if [ "$recovery_status" -eq 0 ]; then rm -rf "$transaction" || recovery_status=$?; fi
    if [ "$recovery_status" -eq 0 ]; then release_lock || recovery_status=$?; fi
    if [ "$recovery_status" -ne 0 ]; then echo "::error::Recovery is incomplete; the transaction and lock remain for manual inspection." >&2; fi
    return "$recovery_status"
}

case $command in
    begin) begin "$@" ;;
    capacity) capacity "$@" ;;
    preflight) preflight "$@" ;;
    quiesce) quiesce "$@" ;;
    prepare) prepare "$@" ;;
    risk) risk "$@" ;;
    activate) activate "$@" ;;
    serve) serve "$@" ;;
    restore-cron) restore_cron_command "$@" ;;
    commit) commit_release "$@" ;;
    finalize) finalize "$@" ;;
    status) [ "$#" -le 2 ] || exit 2; report_status "${1:-}" "${2:-}" ;;
    *) echo "::error::Unknown atomic release command '$command'." >&2; exit 2 ;;
esac
