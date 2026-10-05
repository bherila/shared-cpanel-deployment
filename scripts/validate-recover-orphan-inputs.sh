#!/usr/bin/env bash
# Runs before SSH configuration or host staging, and again on the remote host.
set -euo pipefail
[[ $# == 12 ]] || exit 2
mode=$1 app=$2 release=$3 commit=$4 token=$5 persistent=$6 php=$7 memory=$8 site=$9
confirmation=${10} stopped=${11} verifier=${12}
[[ $mode == resume || $mode == restore ]] || exit 2
[[ $app =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ \
    && $release =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && $release != *..* \
    && $commit =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ && $token =~ ^orphan-[a-f0-9]{32}$ \
    && $php =~ ^/[A-Za-z0-9/._-]+$ && $php != *..* \
    && $memory =~ ^([1-9][0-9]{0,2}M|1024M|1G)$ \
    && $site =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9/._~-]*)?$ \
    && $confirmation == selected-maintenance-source-config && $stopped == true ]] || exit 2
case $app in public_html|www|web|mail|etc|logs|tmp|ssl|cache|bin|lib|perl5|access-logs|lscache|backups) exit 2 ;; esac
[[ -n $persistent && ${#persistent} -le 4096 ]] || exit 2
mapfile -t paths <<<"$persistent"
[[ ${#paths[@]} -le 32 ]] || exit 2
declare -A seen=()
storage=false
for path in "${paths[@]}"; do
    [[ $path =~ ^[A-Za-z0-9_-]+([./][A-Za-z0-9_-]+)*$ && $path != *..* && ! -v seen[$path] ]] || exit 2
    case $path in
        artisan|composer.json|composer.lock|package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|vite.config.*|webpack.mix.js|phpunit.xml|phpunit.xml.dist|\
        app|app/*|bootstrap|bootstrap/*|config|config/*|routes|routes/*|resources|resources/*|vendor|vendor/*|\
        public|public/index.php|public/.htaccess|public/build|public/build/*|\
        database|database/migrations|database/migrations/*|database/seeders|database/seeders/*|database/factories|database/factories/*|\
        *.sqlite|*.sqlite-journal|*.sqlite-wal|*.sqlite-shm) exit 2 ;;
    esac
    seen[$path]=true
    [[ $path != storage ]] || storage=true
done
[[ $storage == true ]] || exit 2
[[ ( $mode == restore && $verifier == - ) || ( $verifier != - && $verifier != /* && $verifier != *..* \
    && $verifier =~ ^[A-Za-z0-9_./-]+$ && -f $verifier && ! -L $verifier ) ]] || exit 2
if [[ $verifier != - ]]; then
    checkout=$(pwd -P)
    resolved=$(realpath -- "$verifier") || exit 2
    [[ $resolved == "$checkout/"* && $resolved == "$checkout/$verifier" ]] || exit 2
fi
