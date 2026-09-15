# shared-cpanel-deployment

One GitHub Action that deploys a Laravel application to its own directory on a **shared cPanel
account**: several applications, one account home, one crontab. Every step that touches shared state is
scoped to this application: its directory, its crontab lines, its `.env`.

It replaces the deploy YAML that each application used to carry, and the lessons those copies learned
the hard way are built in rather than remembered.

## Usage

```yaml
deploy:
  runs-on: ubuntu-24.04-arm
  needs: test
  environment: prod
  steps:
    - uses: actions/checkout@<sha> # v7
      with:
        persist-credentials: false
    - uses: shivammathur/setup-php@<sha> # v2
      with:
        php-version: '8.5'
    - run: composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
    - uses: pnpm/action-setup@<sha> # v6
    - run: pnpm install --frozen-lockfile && pnpm run build

    - uses: bherila/shared-cpanel-deployment@<full commit sha> # v1.0.0
      with:
        ssh-host: ${{ secrets.SSH_HOST }}
        ssh-username: ${{ secrets.SSH_USERNAME }}
        ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
        ssh-known-hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
        deploy-dir: example-laravel
        site-url: https://example.bherila.net
```

That is a complete deploy. With the defaults it:

1. writes the key and **pinned** host key for one SSH alias (nothing else in `~/.ssh/config` changes);
2. adds cPanel's `ea-php85` handler and a LiteSpeed `php_value memory_limit 1024M` to `public/.htaccess`,
   unless the file already sets them;
3. uploads with a **guarded** `rsync --delete` (below), keeping `.env` and runtime storage;
4. checks `.env` has non-empty `APP_KEY`, `APP_ENV` and `APP_URL`;
5. runs `config:clear`, `migrate --force`, verifies no migration remains pending, then runs
   `config:cache`;
6. installs `* * * * * cd "$HOME/example-laravel" && …php -d memory_limit=1G artisan schedule:run … # JOB:example-laravel-scheduler`
   in the account crontab, **replacing only this application's lines**;
7. fails unless `https://example.bherila.net/up` answers, and unless the vhost really serves PHP 8.5 with
   at least 1024M.

Pin the action to a full commit SHA. The job holds a key that reaches every application on the account.

## Inputs

| Input | Default | |
|---|---|---|
| **Connection** | | |
| `ssh-host`, `ssh-username`, `ssh-private-key`, `ssh-known-hosts` | required | Host keys are never trusted on first use. |
| `ssh-alias` | `cpanel-deploy` | Returned as the `ssh-target` output for your own steps. |
| **Application** | | |
| `deploy-dir` | required | Plain directory name under the account home. Never a webroot. |
| `site-url` | required | https URL for the health and PHP checks. |
| `php-version` | `8.5` | Web handler, CLI binary and the PHP check. |
| `php-binary` | `/opt/cpanel/ea-php85/root/usr/bin/php` | Derived from `php-version`. cPanel's default `php` is older. |
| **Upload** | | |
| `paths` | the standard Laravel tree | Newline-separated, relative to the checkout. |
| `excludes` | — | Extra rsync excludes, e.g. an application data directory under `storage/app`. |
| `keep-runtime-storage` | `true` | Keeps `storage/app`, `storage/logs`, framework cache, sessions and views. |
| `set-php-handler` | `true` | |
| `web-memory-limit` | `1024M` | Empty leaves `.htaccess` alone (the PHP check then requires 128M). |
| `webroot-symlink` | — | e.g. `ucadmin.example.com` → `<deploy-dir>/public`. A real directory there fails; it is never deleted. |
| **.env** | | |
| `env-source` | — | File under the account home installed as `.env` (600) each deploy, e.g. `.config/svc/deployment.env`. |
| `app-env`, `app-url`, `app-debug` | — | Set these keys when given; empty leaves them alone. |
| `env-values` | — | `KEY=value` lines to set. **Not for secrets**: use `env-source`. |
| `required-env-keys` | `APP_KEY` `APP_ENV` `APP_URL` | The deploy stops before migrating if any is missing or empty. |
| `env-assert` | — | Exact `KEY=value` lines that must be present after `.env` updates, for deployment-profile and similar boundaries. |
| **Persistent runtime files** | | |
| `passport-key-directory` | — | Relative path containing Passport's two OAuth keys. Keeps a complete pair, creates an absent pair, and refuses a partial pair. |
| `branding-source` | — | Private directory below `~/.config/` copied into `public/branding` after upload. Empty skips branding. |
| `branding-files` | four standard files | Plain names required in the source and copied atomically. |
| **Artisan** | | |
| `run-migrations` | `true` | `migrate --force`, followed by an assertion that none remain pending. |
| `migration-order` | `after-upload` | Use `before-upload` to upload only `database/migrations`, migrate the existing release, verify the result, and then upload application code. |
| `artisan-commands` | — | Extra invocations after `config:cache`, e.g. `view:clear`. |
| `pre-migrate-script` | — | A script in your checkout, run after `.env` and before migration. With `before-upload`, it runs against the previous release before the main upload. Gets `<deploy-dir> <php>`. |
| `post-deploy-script` | — | Same, after artisan and cron. |
| **Cron** | | |
| `install-cron` | `true` | |
| `cron-memory-limit` | `1G` | The cPanel CLI default is 128M. |
| `scheduler-log` | `/dev/null` | Or a path inside the application, e.g. `storage/logs/scheduler.log` (appended). |
| `cron-lines` | the scheduler line | Replaces the default. Each must `cd "$HOME/<deploy-dir>"` and end in `# JOB:<id>`. |
| `extra-cron-lines` | — | Added alongside the scheduler line, same rules. |
| **Verification** | | |
| `health-path` | `/up` | Empty skips. |
| `verify-web-php` | `true` | |

Outputs: `ssh-target` (the alias) and `php-binary`.

## What the guards refuse

**Upload** (`scripts/rsync-deploy.sh`). `--delete` removes whatever the upload does not contain, and the
account home holds other applications and cPanel's own directories.

- An empty, hidden, `.`/`..`, or non-plain `deploy-dir`, or one cPanel owns (`public_html`, `www`, `mail`,
  `etc`, `logs`, `tmp`, `ssl`…). Empty would make the destination the account home.
- Absolute upload paths, `..`, and paths missing from the checkout.
- A destination that is not **absent, empty, or already contains `artisan`**. It is inspected over SSH
  first, so a typo that names another application's directory, a symlink, or a file stops the deploy.
- `.env` is always excluded.

**Crontab** (`scripts/install-cron.sh`). Piping `crontab -l` into `crontab -` has replaced a whole account
crontab when the read came back empty under CageFS. So the installer takes a lock, reads to a file and
stops if the read fails, keeps a backup in `~/.crontab-backups/`, replaces only lines that run from this
application's directory or carry its job ids, installs from a file, and reads back. A hand-installed
legacy line for the application is replaced rather than left running beside the managed one.

**`.env`** (`scripts/configure-env.sh`). Changes are applied to a copy and installed only when something
changed, after the previous file is saved to `~/.env-backups/<deploy-dir>/` (outside the deploy
directory, where `--delete` would remove it). Exact assertions fail before the candidate `.env` is
installed. Values are never printed.

**Persistent Passport and branding files.** Passport setup keeps an existing complete signing pair,
creates keys only when neither file exists, and refuses a half-present pair. A configured branding
source must be a real directory below `~/.config/`; every named source must be a nonempty regular file.
Files are copied through same-directory temporary files into `public/branding`, and the private source
remains outside the guarded application upload.

**Webroot symlink** (`scripts/ensure-webroot-symlink.sh`). Creates or repoints a symlink; never removes
a real file or directory, which may be another domain's document root or its AutoSSL challenge files.

**Migration-first deployments** (`migration-order: before-upload`). The action accepts this only for
an existing Laravel deployment. It verifies that the application and migration directories are real,
uploads candidate migration files without `--delete`, installs the configured environment, runs the
pre-migrate hook and migrations against the previous release, and confirms none remain pending before
the main upload begins. Migrations used this way must remain compatible with the previous release.

## Application-specific steps

Keep them in the application's repository and pass them as hooks, or run them in your own workflow steps
against the `ssh-target` output:

```yaml
    - id: deploy
      uses: bherila/shared-cpanel-deployment@<sha>
      with:
        # …
        env-source: .config/svc/deployment.env
        excludes: |
          svc-blobs
          /storage/app/private/oauth/
        pre-migrate-script: scripts/deploy/ensure-passport-keys.sh
    - run: ssh ${{ steps.deploy.outputs.ssh-target }} "cd ~/svc-laravel && …"
```

An existing identity provider that needs schema expansion before code, persistent Passport keys and
an optional private branding bundle can keep that policy declarative:

```yaml
    - uses: bherila/shared-cpanel-deployment@<sha>
      with:
        # connection, deploy-dir and site-url omitted
        migration-order: before-upload
        env-source: .config/identity/deployment.env
        env-assert: AUTH_MANAGER_PROFILE=resource
        passport-key-directory: storage/app/private/oauth
        branding-source: ${{ vars.BRANDING_SOURCE }}
        excludes: |
          .db-credentials
          /public/branding/
```

Set `artisan-memory-limit: 1G` when migrations or application-specific Artisan commands exceed the
host's CLI default. The limit applies to migration execution, the pending-migration assertion,
config caching, and every command in `artisan-commands`.

Leave `BRANDING_SOURCE` empty for the application's default theme. When set, point it at a directory
such as `.config/identity/branding`; keep the canonical files there rather than inside the rsync target.

## Migrating an existing deploy job

- Delete the `Append to .htaccess` step and `htaccess-append.txt`, or leave them: an existing handler for
  the same PHP is kept, and a handler for a different PHP fails the deploy rather than adding a second.
- Delete the SSH, rsync, artisan and cron steps. Move per-app rsync excludes to `excludes`.
- If the account crontab has a hand-installed line for the app, the first deploy replaces it with the
  tagged line; `~/.crontab-backups/` has the previous crontab.
- If an existing deploy ran `migrate` without `--force`, check `APP_ENV` first.

## Development

```sh
shellcheck scripts/*.sh
bash scripts/test-install-cron.sh
bash scripts/test-rsync-deploy.sh
bash scripts/test-rsync-migrations.sh
bash scripts/test-htaccess.sh
bash scripts/test-configure-env.sh
bash scripts/test-assert-no-pending-migrations.sh
bash scripts/test-remote-artisan.sh
bash scripts/test-ensure-passport-keys.sh
bash scripts/test-install-branding.sh
```

Release by tagging `vX.Y.Z`; callers pin the tag's commit SHA.
