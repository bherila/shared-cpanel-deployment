# shared-cpanel-deployment

One GitHub Action that deploys a Laravel application to versioned releases on a **shared cPanel
account**: several applications, one account home, one crontab. The default validates a candidate
before a failure-safe same-filesystem directory activation and preserves the previously selected code. Every step that
touches shared state is scoped to this application: its release tree, stable path, crontab lines and
runtime data.

It replaces the deploy YAML that each application used to carry, and the lessons those copies learned
the hard way are built in rather than remembered.

Atomic-mode framework probes are CI-tested against Laravel 12 and 13. Those are the supported Laravel
majors for the versioned release state machine; older applications should remain pinned to a compatible
action revision or use the explicit in-place escape hatch until upgraded.

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

    - uses: bherila/shared-cpanel-deployment@<full commit sha> # v2
      with:
        ssh-host: ${{ secrets.SSH_HOST }}
        ssh-username: ${{ secrets.SSH_USERNAME }}
        ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
        ssh-known-hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
        deploy-dir: example-laravel
        site-url: https://example.bherila.net
```

That is a complete atomic deploy. With the defaults it:

1. writes the key and **pinned** host key for one SSH alias (nothing else in `~/.ssh/config` changes);
2. adds cPanel's `ea-php85` handler and a LiteSpeed `php_value memory_limit 1024M` to `public/.htaccess`,
   unless the file already sets them;
3. acquires an application-scoped remote lock, enforces upload headroom, and uploads into
   `~/.deployments/example-laravel/releases/<release-id>`;
4. preflights the stable path, persistent data, webroot, filesystem and disk/quota information before
   changing the legacy layout;
5. quiesces a legacy deployment before its one-time runtime-data move, shares `storage`, copies the
   live `.env` forward into the candidate, and checks non-empty `APP_KEY`, `APP_ENV` and `APP_URL`;
6. pauses this application's cron, puts the old selected release in maintenance, runs candidate
   migrations, confirms none remain pending, and runs candidate checks;
7. retains the old real application directory, renames the candidate into its stable place, rebuilds
   Laravel caches from that final path, and runs post-activation work while maintenance remains enabled;
8. brings the candidate up, proves it serves, then installs/restores cron and verifies HTTP, PHP and
   any application verification script before committing
   the release and cleans old releases;
9. always reports which release and commit are selected and whether they are serving or in maintenance.

Pin the action to a full commit SHA. The job holds a key that reaches every application on the account.
Every pre-v2 consumer is SHA-pinned, so moving to v2 is a deliberate layout migration rather than an
implicit behavior change.

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
| `deployment-mode` | `atomic` | Safe v2 versioned releases. `in-place` is the explicit v1 escape hatch. |
| `atomic-layout` | `stable-directory` | Keeps `~/<deploy-dir>` real for cPanel/LiteSpeed. `release-symlink` is the v2.0 compatibility layout for proven hosts. |
| `persistent-paths` | `storage` | Runtime files or directories shared by atomic releases; declare every server-authoritative path. |
| `retain-releases` | `3` | Minimum 2; selected and prior releases are protected. |
| `deploy-lock-timeout` | `21600` | Diagnostic expected duration stored with the lock. v2 never takes over an aged lock automatically. |
| `recovery-release-id` | empty | Explicitly finalize that interrupted transaction before a new deploy, proceeding only after the selected application is proven serving. |
| `failure-policy` | `maintenance` | `rollback` opts into serving prior code after DB changes and requires expand/contract compatibility. |
| `initial-live-commit` | — | Exact revision required for the first conversion of an existing in-place app. |
| **Upload** | | |
| `paths` | the standard Laravel tree | Newline-separated, relative to the checkout. |
| `excludes` | — | Extra rsync excludes, e.g. an application data directory under `storage/app`. |
| `keep-runtime-storage` | `true` | In-place mode only. Atomic mode shares `persistent-paths`. |
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
| `passport-key-directory` | — | Relative path containing Passport's two OAuth keys. Atomic mode requires it to be covered by `persistent-paths`. |
| `branding-source` | — | Private directory below `~/.config/` copied into `public/branding` after upload. Empty skips branding. |
| `branding-files` | four standard files | Plain names required in the source and copied atomically. |
| **Artisan** | | |
| `run-migrations` | `true` | `migrate --force`, followed by an assertion that none remain pending. |
| `migration-order` | `after-upload` | In-place compatibility only. Atomic mode always migrates the candidate and rejects `before-upload`. |
| `artisan-commands` | — | Extra invocations after `config:cache`, e.g. `view:clear`. |
| `quiesce-script` | — | After cron pause/old-code maintenance and before conversion or DB risk; wait for running workers here. Gets `<candidate-path> <php> <stable-path>`. |
| `allow-unverified-quiescence` | `false` | Explicit assertion that an existing app owns no process requiring drain. Fresh installs skip this requirement. |
| `pre-migrate-script` | — | Immediately after the durable DB-risk marker, before migration. Gets `<candidate-path> <php> <stable-path>`. |
| `post-deploy-script` | — | Atomic candidate validation before selection. In-place retains v1 after-cron timing. Same arguments. |
| `pre-activate-script` | — | Final atomic candidate check. Gets `<candidate-path> <php> <stable-path>`. |
| `post-activate-script` | — | Stable-path work after selection and before `artisan up`. It must leave Laravel down and must not start cron/workers. Gets `<stable-path> <php> <candidate-path>`. |
| **Cron** | | |
| `install-cron` | `true` | |
| `cron-memory-limit` | `1G` | Applied to every managed Artisan scheduler and worker line that does not set an explicit limit. The cPanel CLI default is 128M. |
| `scheduler-log` | `/dev/null` | Or a path inside the application, e.g. `storage/logs/scheduler.log` (appended). |
| `cron-lines` | the scheduler line | Replaces the default. Each must `cd "$HOME/<deploy-dir>"` and end in `# JOB:<id>`. Artisan lines inherit `cron-memory-limit`. |
| `extra-cron-lines` | — | Added alongside the scheduler line, same rules. Use this for queue workers; they inherit `cron-memory-limit` too. |
| **Verification** | | |
| `health-path` | `/up` | Empty skips. |
| `verify-web-php` | `true` | |
| `verification-script` | — | Runner-side live checks after `artisan up`, with deployment details in `DEPLOY_*`. |

Outputs: `ssh-target`, `php-binary`, `release-id`, `live-release`, `live-commit` and `live-state`.

## Atomic release contract

The stable path and cron working directory do not change. By default the path is a real directory,
because some cPanel/LiteSpeed vhosts return a host-level 404 when an application-directory ancestor is
a symlink:

```text
~/example-laravel/                         # selected release; always a real directory when present
~/.deployments/example-laravel/
  releases/<candidate-release-id>/         # before activation
  releases/<retained-prior-release-id>/    # after activation
  shared/storage/
  state/<incomplete-release-id>/
  deploy.lock/
```

The release id contains the source revision, GitHub run id and attempt. Each release also has a
`.deploy-release` metadata file. Final status resolves the real stable directory or compatibility symlink and metadata; it does
not assume that the attempted candidate became live. `live-state` distinguishes `serving`,
`maintenance`, `absent` and `unavailable`.

Before upload, the action compares local candidate size with remote free space and requires twice that
size plus a 256 MiB staging reserve. A reliably numeric account quota is enforced too; otherwise quota
is explicitly report-only while the filesystem gate remains mandatory. On first conversion, the
read-only preflight reports stable/webroot links, persistent types and symlinks, and filesystem devices.
The guarded conversion enters maintenance, pauses cron, drains workers, moves runtime data into
`shared`, and records exact metadata on the unchanged real directory. A candidate failure before the
database-risk boundary restores that same code. Activation is a guarded, recoverable two-rename
transition: it retains the real old directory under `releases/`, then moves the prepared candidate into
the stable name. It is not a single atomic directory exchange; the stable path is briefly absent between
the two same-filesystem renames while the application and its cron are quiesced. Durable state brackets
both boundaries: interruption before the first leaves old code selected down; interruption between them
completes exact candidate selection down; interruption after the second proves the selected candidate.

`atomic-layout: release-symlink` preserves the v2.0 selection mechanism only for hosts where the vhost
has been proven to follow a symlinked application-directory ancestor. A normal `stable-directory`
deployment also migrates an existing managed v2.0 symlink while quiesced: it removes only the proven
managed link and moves its exact target to the stable real path before database risk. If an operator
has already restored a real stable copy while retaining the same managed release as recovery evidence
(the SVC recovery shape), activation preserves that copy and retains the selected directory under a
unique transaction-scoped name; neither is overwritten.

`persistent-paths` accepts existing standalone regular files and directories. Neutral runtime files
such as `runtime/state.bin` and non-code public assets such as `public/ohif` may be declared. Laravel
code roots and entry points (`app`, `bootstrap`, `config`, `routes`, `resources`, `vendor`, public entry
points/builds, migrations, package/build manifests, Composer metadata and `artisan`) are refused. A
declared path absent from both the selected release and candidate is also refused: the action never
guesses whether it should create a file or directory. On later deployments the selected release must
already link every declaration to managed shared state; preparation validates this without a
maintenance blip and refuses unexpected repair or mutation.

Do not persist a lone SQLite file. SQLite may have adjacent `-wal`, `-shm`, or `-journal` sidecars, so
sharing only `database/database.sqlite` can lose committed data during activation or cleanup; `.sqlite`
paths are rejected. Before v2 conversion, quiesce every writer, checkpoint the database, relocate it
into a wholly persistent runtime directory (for example below `storage`), update `DB_DATABASE`, and
persist that directory. Do not share all of `database/`, because it contains release migrations.

`.env` is deliberately **not** shared. With no `env-source`, the selected release's private `.env` is
copied into the candidate before changes and checks. With `env-source`, that server-owned file is
installed into the candidate. Thus configuration changes cannot affect selected old code before
activation.

### Hook phases and paths

Hook paths are safe paths relative to `$HOME`, never arbitrary absolute paths:

- candidate: `.deployments/<deploy-dir>/releases/<release-id>`;
- stable: `<deploy-dir>`.

The atomic order is:

1. for first conversion only, pause cron, put selected old code in maintenance, run
   `quiesce-script <candidate> <php> <stable>`, and convert persistent paths;
2. configure candidate environment, persistent Passport keys and branding;
3. for an already-versioned or fresh app, pause cron/old code now and run `quiesce-script`; first
   conversion remains quiesced from step 1;
4. persist the database-risk marker, then run `pre-migrate-script <candidate> <php> <stable>`;
5. migrate and assert no pending migrations on the candidate; for `release-symlink`, cache config and
   run `artisan-commands` there as before;
6. run `post-deploy-script <candidate> <php> <stable>` and `pre-activate-script` with the same args;
7. re-prove old and candidate maintenance, retain old code and select the candidate with guarded
   same-filesystem renames; for `stable-directory`, rebuild config and run `artisan-commands` from the
   final stable path so Laravel never serves absolute paths cached under the staging release path;
   revalidate/create `webroot-symlink`, then run `post-activate-script <stable> <php> <candidate>` while
   maintenance remains;
8. run `artisan up`, prove Laravel is serving, and only then install or restore application cron;
9. run built-in HTTP/PHP checks, then `verification-script` on the runner.

The runner verification environment includes `DEPLOY_SSH_TARGET`, `DEPLOY_PHP_BINARY`, `DEPLOY_DIR`,
`DEPLOY_STABLE_DIR`, `DEPLOY_CANDIDATE_DIR`, `DEPLOY_SITE_URL`, `DEPLOY_RELEASE_ID`,
`DEPLOY_SOURCE_COMMIT`, `DEPLOY_LIVE_RELEASE`, `DEPLOY_LIVE_COMMIT`, `DEPLOY_LIVE_STATE` and
`DEPLOYMENT_MODE`.

`post-activate-script` is a trusted maintenance-only hook. It must not call `artisan up`, install cron,
or start a scheduler or worker; the action re-proves maintenance when the hook returns. Express managed
scheduled work with `cron-lines` and `extra-cron-lines`, which are installed only after serving is proven.

An existing app must provide `quiesce-script` by default. The five initial consumers use it to wait for
workers or assert that no app-owned PHP process remains. Set `allow-unverified-quiescence:true` only
when the application contract proves it never owns a scheduler, queue worker, or other long-running
process; the explicit acknowledgment is intentionally visible in review. Fresh installs need neither.

### Failure boundary

Failures before the database-risk boundary restore selected code and cron to serving state. Recovery
intent is persisted before either is first changed, including during one-time conversion. An app that
is already intentionally in Laravel maintenance is refused before mutation; v2 never silently brings
it up. Immediately before `pre-migrate-script`, the durable risk marker is written only after cron is
paused, old code is down, and the worker-drain hook passed. From that point until candidate activation
and `artisan up`, no release is intentionally served. A failed or partially applied migration under
the default `failure-policy: maintenance` leaves
the **old selected release** in maintenance. A failure after selection leaves the candidate selected in
maintenance. The paused application cron lines are preserved privately under
`~/.deployments/<deploy-dir>/recovery/<release-id>.cron` for manual recovery, even after the deployment
transaction unlocks. Selection and service state are always reported separately.

`failure-policy: rollback` restores the retained prior directory (or prior stable symlink in the
compatibility layout), prior app cron lines and serving state.
It does not and cannot roll back the database. Use it only when every migration in the release follows
an expand/contract plan compatible with the prior code. Otherwise inspect the failure and schema before
performing a manual code rollback.

One app-scoped remote transaction is allowed at a time. Automatic age-based takeover is forbidden: a
long migration can outlive any lease, and overlapping it is unsafe. After proving the owning workflow
and remote processes have stopped, an operator must recover/remove an abandoned lock deliberately.
Every successfully finalized failure becomes retention-eligible; cleanup preserves the live release,
the prior release and genuinely incomplete transactions.

## What the guards refuse

**Upload.** Atomic mode (`scripts/rsync-atomic-release.sh`) only writes the exact empty candidate created
by the lock-owning transaction. In-place mode (`scripts/rsync-deploy.sh`) retains the v1 destination
guards. `--delete` removes whatever the upload does not contain, and the account home holds other
applications and cPanel's own directories.

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

**Persistent Passport and branding files.** Atomic mode refuses a Passport directory not covered by a
declared persistent path. Passport setup keeps an existing complete signing pair,
creates keys only when neither file exists, and refuses a half-present pair. A configured branding
source must be a real directory below `~/.config/`; every named source must be a nonempty regular file.
Files are copied through same-directory temporary files into `public/branding`, and the private source
remains outside the guarded application upload.

**Webroot symlink** (`scripts/ensure-webroot-symlink.sh`). Creates or repoints a symlink; never removes
a real file or directory, which may be another domain's document root or its AutoSSL challenge files.

**Legacy migration-first deployments** (`deployment-mode: in-place`, `migration-order: before-upload`). The action accepts this only for
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
        quiesce-script: scripts/deploy/wait-for-workers.sh
    - run: ssh ${{ steps.deploy.outputs.ssh-target }} "cd ~/svc-laravel && …"
```

An existing identity provider that needs schema expansion before code, persistent Passport keys and
an optional private branding bundle can keep that policy declarative:

```yaml
    - uses: bherila/shared-cpanel-deployment@<sha>
      with:
        # connection, deploy-dir and site-url omitted
        env-source: .config/identity/deployment.env
        env-assert: AUTH_MANAGER_PROFILE=resource
        passport-key-directory: storage/app/private/oauth
        branding-source: ${{ vars.BRANDING_SOURCE }}
        excludes: |
          .db-credentials
          /public/branding/
```

Set `artisan-memory-limit: 1G` when the application exceeds the host's CLI default. The limit applies
to atomic maintenance/serving probes, lifecycle `down`/`up`, migration execution, the pending-migration
assertion, config caching, and every command in `artisan-commands`.

Leave `BRANDING_SOURCE` empty for the application's default theme. When set, point it at a directory
such as `.config/identity/branding`; keep the canonical files there rather than inside the rsync target.

## Migrating an existing deploy job to v2

Before repinning, inventory every server-authoritative regular file and directory. Keep `storage` and
add all top-level application data to `persistent-paths`; do not assume an rsync `excludes` pattern is
a persistence declaration. Move candidate-safe validation to `post-deploy-script` or
`pre-activate-script`, stable-path activation/import work to `post-activate-script`, managed scheduled
work to `cron-lines` or `extra-cron-lines`, and live OAuth/MCP/HTTP checks to `verification-script`.
Use `quiesce-script` to wait for non-cancelling
old workers after maintenance and cron pause. Add non-cancelling workflow concurrency so two runs do
not compete before reaching the remote lock.

The initial rollout covers personal-site, SVC, PHR, Games and UC. auth-manager and e-sign remain on
their pinned v1 commits pending their own persistence and identity-profile reviews. Every rollout
should first use `failure-policy: maintenance`, verify the reported live release/commit and state, then
check migrations, cron/scheduler/workers, queues, OAuth/MCP where applicable, `/up`, PHP and memory.

The old checklist remains relevant for the explicit in-place escape hatch:

- Delete the `Append to .htaccess` step and `htaccess-append.txt`, or leave them: an existing handler for
  the same PHP is kept, and a handler for a different PHP fails the deploy rather than adding a second.
- Delete the SSH, rsync, artisan and cron steps. Move per-app rsync excludes to `excludes`.
- If the account crontab has a hand-installed line for the app, the first deploy replaces it with the
  tagged line; `~/.crontab-backups/` has the previous crontab.
- If an existing deploy ran `migrate` without `--force`, check `APP_ENV` first.

## Development

```sh
shellcheck scripts/*.sh
bash scripts/test-atomic-release.sh
bash scripts/test-action-contract.sh
bash scripts/test-install-cron.sh
bash scripts/test-prepare-cron-lines.sh
bash scripts/test-rsync-atomic-release.sh
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
