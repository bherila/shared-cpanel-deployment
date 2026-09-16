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

echo "failures: $fails"
exit "$fails"
