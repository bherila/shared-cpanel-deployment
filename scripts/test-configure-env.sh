#!/usr/bin/env bash
# Local harness for configure-env.sh, against a fake $HOME.
# Usage: test-configure-env.sh
# shellcheck disable=SC2016,SC2034,SC2317,SC2329 # Checks are eval'd strings; what they call looks unused (SC2317 on older shellcheck).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/configure-env.sh"
fails=0

setup() {
    root=$(mktemp -d)
    export HOME="$root/home"
    mkdir -p "$HOME/app"
    printf 'APP_NAME=Example\nAPP_KEY=base64:abc\nexport APP_ENV=local\nAPP_URL=\nDB_PASSWORD="s3cr#t"\n' >"$HOME/app/.env"
}
run() { bash "$script" "$@" >"$root/out" 2>&1; }
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
env_has() { grep -Fqx -- "$1" "$HOME/app/.env"; }
backups() { find "$HOME/.env-backups" -type f 2>/dev/null | wc -l | tr -d ' '; }

# 1. SET replaces existing assignments (including `export` ones) in place and appends new keys.
setup
run app '' 'SET:APP_ENV=production' 'SET:APP_URL=https://example.test' 'SET:APP_DEBUG=false'; status=$?
check "sets succeed" '[ "$status" -eq 0 ]'
check "an export assignment is replaced in place" 'env_has APP_ENV=production && [ "$(sed -n 3p "$HOME/app/.env")" = APP_ENV=production ]'
check "an empty assignment is filled" 'env_has APP_URL=https://example.test'
check "a new key is appended" '[ "$(tail -1 "$HOME/app/.env")" = APP_DEBUG=false ]'
check "untouched lines are kept verbatim" 'env_has "DB_PASSWORD=\"s3cr#t\"" && env_has APP_NAME=Example'
check "the previous .env is backed up outside the app" '[ "$(backups)" = 1 ]'
check "no value is printed" '! grep -q "https://example.test" "$root/out"'
check ".env stays private" '[ -n "$(find "$HOME/app/.env" -perm 600)" ]'

# 2. Running again with the same values changes nothing and takes no backup.
chmod 644 "$HOME/app/.env"
run app '' 'SET:APP_ENV=production' 'SET:APP_URL=https://example.test' 'SET:APP_DEBUG=false'; status=$?
check "an unchanged run takes no backup and restores private mode" '[ "$status" -eq 0 ] && [ "$(backups)" = 1 ] && [ -n "$(find "$HOME/app/.env" -perm 600 -print)" ]'

# 3. Values dotenv would split are quoted and escaped.
setup
run app '' 'SET:APP_NAME=My "App" #1 $HOME'; status=$?
check "a value with spaces, quotes, # and \$ is quoted" '[ "$status" -eq 0 ] && env_has "APP_NAME=\"My \\\"App\\\" #1 \\\$HOME\""'

# 4. REQUIRE fails on missing or empty keys, after SETs, before anything else.
setup
run app '' 'REQUIRE:APP_KEY' 'REQUIRE:APP_URL' 'REQUIRE:MAIL_HOST'; status=$?
check "missing and empty required keys fail and are named" '[ "$status" -eq 1 ] && grep -q "APP_URL MAIL_HOST" "$root/out"'
setup
run app '' 'SET:APP_URL=https://example.test' 'REQUIRE:APP_URL' 'REQUIRE:APP_KEY' 'REQUIRE:APP_ENV'; status=$?
check "a key set in the same run satisfies REQUIRE, as does an export line" '[ "$status" -eq 0 ]'
setup
printf 'APP_KEY=""\n' >"$HOME/app/.env"
run app '' 'REQUIRE:APP_KEY'; status=$?
check "an empty quoted value fails REQUIRE" '[ "$status" -eq 1 ]'

# 5. ASSERT requires one exact unquoted assignment and never prints its expected value.
setup
run app '' 'ASSERT:APP_NAME=Example' 'ASSERT:APP_ENV=local'; status=$?
check "exact assertions succeed" '[ "$status" -eq 1 ] && grep -Fq "APP_ENV" "$root/out" && ! grep -Fq "APP_ENV=local" "$root/out"'
run app '' 'SET:APP_ENV=production' 'ASSERT:APP_ENV=production'; status=$?
check "assertions evaluate the post-update environment" '[ "$status" -eq 0 ] && env_has APP_ENV=production'
printf 'APP_ENV=staging\n' >>"$HOME/app/.env"
run app '' 'ASSERT:APP_ENV=production'; status=$?
check "an assertion rejects duplicate assignments" '[ "$status" -eq 1 ]'
setup
before=$(cat "$HOME/app/.env")
run app '' 'SET:APP_URL=https://example.test' 'ASSERT:APP_ENV=production'; status=$?
check "a failed assertion leaves .env untouched" '[ "$status" -eq 1 ] && [ "$(cat "$HOME/app/.env")" = "$before" ] && ! grep -Fq production "$root/out"'
mkdir -p "$HOME/.config/app"
printf 'APP_KEY=replacement\nAPP_ENV=staging\nAPP_URL=https://example.test\n' >"$HOME/.config/app/deployment.env"
run app .config/app/deployment.env 'ASSERT:APP_ENV=production'; status=$?
check "a failed assertion does not install env-source" '[ "$status" -eq 1 ] && [ "$(cat "$HOME/app/.env")" = "$before" ]'

# 6. Invalid input is refused without writing.
setup
before=$(cat "$HOME/app/.env")
run app '' 'SET:app_env=x'; lower=$?
run app '' 'SET:NOEQUALS'; noeq=$?
run app '' 'ASSERT:bad=x'; bad_assert=$?
run 'app/../x' '' 'REQUIRE:APP_KEY'; traversal=$?
run app '/etc/passwd'; abs=$?
check "invalid keys, pairs, assertions, dirs and sources are refused" '[ "$lower" -eq 2 ] && [ "$noeq" -eq 2 ] && [ "$bad_assert" -eq 2 ] && [ "$traversal" -eq 2 ] && [ "$abs" -eq 2 ]'
check "refusals leave .env untouched" '[ "$(cat "$HOME/app/.env")" = "$before" ] && [ "$(backups)" = 0 ]'

# 7. env-source installs the file first; a missing .env or source fails.
setup
mkdir -p "$HOME/.config/app"
printf 'APP_KEY=fromsource\nAPP_ENV=production\nAPP_URL=https://example.test\n' >"$HOME/.config/app/deployment.env"
run app .config/app/deployment.env 'REQUIRE:APP_KEY'; status=$?
check "env-source is installed" '[ "$status" -eq 0 ] && env_has APP_KEY=fromsource'
run app .config/app/missing.env; status=$?
check "a missing env-source fails" '[ "$status" -eq 1 ]'
setup
rm "$HOME/app/.env"
run app '' 'REQUIRE:APP_KEY'; status=$?
check "a missing .env fails" '[ "$status" -eq 1 ]'

# 8. Atomic candidates use the exact managed path grammar and keep a release-local environment.
setup
managed="$HOME/.deployments/app/releases/release-1"
mkdir -p "$managed"
cp "$HOME/app/.env" "$managed/.env"
bash "$script" .deployments/app/releases/release-1 '' 'SET:APP_ENV=production' >"$root/out" 2>&1; status=$?
check "a managed atomic candidate environment can be configured" \
    '[ "$status" -eq 0 ] && grep -Fqx APP_ENV=production "$managed/.env" && grep -Fqx "export APP_ENV=local" "$HOME/app/.env"'

# 9. Backup identity is application-scoped, not release-scoped, and timestamps never collide.
setup
mkdir -p "$root/bin"
cat >"$root/bin/date" <<'SH'
#!/usr/bin/env bash
printf '20261008T120000Z\n'
SH
chmod +x "$root/bin/date"
for index in 1 2; do
    managed="$HOME/.deployments/app/releases/release-$index"
    mkdir -p "$managed"
    printf 'APP_KEY=before-%s\n' "$index" >"$managed/.env"
    PATH="$root/bin:$PATH" run ".deployments/app/releases/release-$index" '' "SET:APP_KEY=after-$index"
done
check "same-second releases preserve distinct backups in the application namespace" \
    '[ "$(find "$HOME/.env-backups/app" -maxdepth 1 -type f | wc -l)" -eq 2 ] && grep -lqx APP_KEY=before-1 "$HOME/.env-backups/app"/.env-* >/dev/null && grep -lqx APP_KEY=before-2 "$HOME/.env-backups/app"/.env-* >/dev/null && [ ! -e "$HOME/.env-backups/.deployments" ]'
check "backup directories and files are private" \
    '[ "$(stat -c %a "$HOME/.env-backups")" = 700 ] && [ "$(stat -c %a "$HOME/.env-backups/app")" = 700 ] && [ -z "$(find "$HOME/.env-backups/app" -type f ! -perm 600 -print)" ]'

# 10. Retention applies across releases and in-place changes, without touching other state.
mkdir -p "$HOME/.env-backups/other-app" "$HOME/.env-backups/.deployments/app/releases/legacy"
printf unrelated >"$HOME/.env-backups/app/.env-unrelated"
printf legacy >"$HOME/.env-backups/.deployments/app/releases/legacy/.env-20200101T000000Z"
printf other-app >"$HOME/.env-backups/other-app/.env-20200101T000000Z"
printf outside >"$root/canary"
ln -s "$root/canary" "$HOME/.env-backups/app/.env-20200101T000000Z"
for index in $(seq 3 14); do
    managed="$HOME/.deployments/app/releases/release-$index"
    mkdir -p "$managed"
    printf 'APP_KEY=before-%s\n' "$index" >"$managed/.env"
    PATH="$root/bin:$PATH" run ".deployments/app/releases/release-$index" '' "SET:APP_KEY=after-$index" || fails=$((fails + 1))
    # Force tied mtimes for the next run: the just-created backup must always survive pruning.
    find "$HOME/.env-backups/app" -maxdepth 1 -type f -name '.env-20261008T120000Z.*' -exec touch -t 202610081200 {} +
done
check "fourteen atomic releases retain ten generated backups" \
    '[ "$(find "$HOME/.env-backups/app" -maxdepth 1 -type f -name ".env-20261008T120000Z.*" | wc -l)" -eq 10 ] && grep -lqx APP_KEY=before-14 "$HOME/.env-backups/app"/.env-20261008T120000Z.* >/dev/null'
run app '' SET:APP_KEY=in-place-change; status=$?
check "in-place changes retain the same bounded namespace" \
    '[ "$status" -eq 0 ] && [ "$(find "$HOME/.env-backups/app" -maxdepth 1 -type f -name ".env-20*T*Z.*" | wc -l)" -eq 10 ]'
check "retention preserves unrelated files, symlinks, applications and legacy release directories" \
    '[ "$(cat "$HOME/.env-backups/app/.env-unrelated")" = unrelated ] && [ -L "$HOME/.env-backups/app/.env-20200101T000000Z" ] && [ "$(cat "$root/canary")" = outside ] && [ "$(cat "$HOME/.env-backups/other-app/.env-20200101T000000Z")" = other-app ] && [ "$(cat "$HOME/.env-backups/.deployments/app/releases/legacy/.env-20200101T000000Z")" = legacy ]'

# 11. Existing real timestamp-only backups count towards retention; aliases are refused.
setup
mkdir -p "$HOME/.env-backups/app"
for index in $(seq -w 1 12); do printf legacy >"$HOME/.env-backups/app/.env-20200101T0000${index}Z"; done
run app '' SET:APP_ENV=production; status=$?
check "legacy in-place backups share the ten-file bound" \
    '[ "$status" -eq 0 ] && [ "$(find "$HOME/.env-backups/app" -maxdepth 1 -type f | wc -l)" -eq 10 ]'
for alias_part in root application; do
    setup
    before=$(cat "$HOME/app/.env")
    mkdir -p "$root/outside"
    printf canary >"$root/outside/canary"
    chmod 755 "$root/outside"
    if [ "$alias_part" = root ]; then
        ln -s "$root/outside" "$HOME/.env-backups"
    else
        mkdir "$HOME/.env-backups"
        ln -s "$root/outside" "$HOME/.env-backups/app"
    fi
    run app '' SET:APP_ENV=production; status=$?
    check "a symlinked $alias_part backup namespace fails before changing secrets or permissions" \
        '[ "$status" -eq 1 ] && [ "$(cat "$HOME/app/.env")" = "$before" ] && [ "$(cat "$root/outside/canary")" = canary ] && [ "$(stat -c %a "$root/outside")" = 755 ] && [ "$(find "$root/outside" -type f | wc -l)" -eq 1 ]'
done
run .deployments/./releases/release-1 '' SET:APP_ENV=production; status=$?
check "an aliased managed application namespace is rejected" '[ "$status" -eq 2 ]'

# 12. Failure to save the previous secrets cannot replace the live environment.
setup
before=$(cat "$HOME/app/.env")
mkdir "$root/bin"
cat >"$root/bin/install" <<'SH'
#!/usr/bin/env bash
case ${!#} in
    "$HOME"/.env-backups/app/.env-*) exit 1 ;;
esac
exec /usr/bin/install "$@"
SH
chmod +x "$root/bin/install"
PATH="$root/bin:$PATH" run app '' SET:APP_ENV=production; status=$?
check "a failed backup copy leaves the live environment and no partial backup" \
    '[ "$status" -eq 1 ] && [ "$(cat "$HOME/app/.env")" = "$before" ] && [ "$(backups)" -eq 0 ] && ! grep -Fq "s3cr#t" "$root/out"'

setup
managed_app=other-application run app '' SET:APP_ENV=production; status=$?
check "an inherited shell variable cannot redirect an in-place backup namespace" \
    '[ "$status" -eq 0 ] && [ -d "$HOME/.env-backups/app" ] && [ ! -e "$HOME/.env-backups/other-application" ]'

echo "failures: $fails"
exit "$fails"
