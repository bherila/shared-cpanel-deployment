# Explicit orphaned-maintenance recovery

Use this separate action only when an exact managed **real stable directory** is in
file maintenance, its canonical `deploy.lock` is absent, and its real transaction
`state/` directory is empty. Ordinary deployment still refuses intentional
maintenance. This operation does not upload application code, migrate a database,
install cron, change `.env`, replace OAuth keys, or select another release.

## Before running

1. Inspect the failed deployment and the selected regular `.deploy-release`. Record
   its exact release and full commit. Prove the owning workflow, prior recovery
   sessions and all application workers have stopped. This is an operator assertion;
   the action never treats age as proof and never takes over an existing lock.
   Keep all selected source, vendor code, configuration, routes and providers
   immutable throughout recovery. Critical-file hashes cover `.deploy-release`,
   `.env` and `.env.*`, `artisan`, `bootstrap/app.php` and `vendor/autoload.php`;
   they do not inventory every application or vendor source file.
2. Prove application cron is paused. The action reads the current account crontab
   before acquisition, before serving and before release; application paths and
   application-prefixed job tags must be absent. Foreign rows are never written.
   Account cron reads that fail or have unknown output are refused. Separately
   inventory nonstandard job ownership spellings and external schedulers/workers.
3. Approve rebuilding configuration from the **selected source and its source
   environment**, including APP_KEY, database location and maintenance driver.
   Cached configuration is replaced; source environment drift is not silently
   carried forward from the old cache. Compare sensitive values privately. The
   confirmation `selected-maintenance-source-config` acknowledges this choice.
4. Supply the same complete `persistent-paths` as the normal deployment, including
   `storage`. All selected links must reach their exact managed shared targets.
   Source/code persistence, unsafe ancestors, symlinked generated-cache files,
   retained `.begin-cleanup-*` uncertainty evidence and nonempty state are refused.
5. Provide a canonical checkout-relative path (without `./` or symlink ancestors)
   to a read-only **host** Bash verifier that proves the
   actual application web responses, identity and assets/OAuth as applicable.
   It receives `<absolute-stable-path> <absolute-php-binary>` and `DEPLOY_*` exact
   identity variables. HTTP 200 from a generic `/up` endpoint is insufficient.
   Verifier output stays private; its successful exit and repeated ownership,
   framework, runtime and cron proofs are required before unlocking.

Initial support is Laravel 12/13, file maintenance, default canonical generated
cache destinations, and an existing real managed runtime tree. Any external or
selected-dotenv `APP_CONFIG_CACHE`, `APP_SERVICES_CACHE`, `APP_PACKAGES_CACHE`,
`APP_ROUTES_CACHE` or `APP_EVENTS_CACHE` override is refused before lock acquisition.
No missing runtime directories are provisioned. The valid maintenance JSON and
optional rendered maintenance file must be regular canonical files of at most 32 KiB.

Generate and retain a unique token such as `orphan-` followed by 32 lowercase
hexadecimal characters. Never reuse a completed token. Keep workflow concurrency
non-cancelling and use a dedicated pinned SSH key/host configuration.

```yaml
- uses: bherila/shared-cpanel-deployment/recover-orphan@<reviewed-full-sha>
  with:
    operation: resume
    deploy-dir: example-laravel
    expected-release: <exact-selected-release>
    expected-commit: <exact-selected-full-commit>
    recovery-token: <retained-orphan-32-hex-token>
    confirmation: selected-maintenance-source-config
    owner-stopped: 'true'
    persistent-paths: storage
    php-binary: /opt/cpanel/ea-php85/root/usr/bin/php
    artisan-memory-limit: 256M
    health-url: https://example.bherila.net/up
    verification-script: scripts/deploy/verify-recovered-app.sh
    ssh-host: ${{ secrets.SSH_HOST }}
    ssh-username: ${{ secrets.SSH_USERNAME }}
    ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
    ssh-known-hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
```

## Preparation and successful serving

The unlocked preflight inspects only filesystem state and writes a private bounded
snapshot. One host session then atomically acquires the canonical lock and re-proves
that snapshot before any Laravel application or provider bootstrap. A private durable
`recovery/<token>/record.json` captures exact lock and selected/storage ancestor
device/inode identity, critical source/environment/metadata hashes, phase and the
original maintenance bytes/modes. These records remain outside release data with
directory mode 0700 and record mode 0600. The durable generation advances to the
recovery token under the lock, superseding older post-finalizer observations.

Preparation stays down. Trusted source boots with private configuration, provider,
route/event and real-time facade caches. Source dotenv is selected once; the native
scalar configuration cache is generated from that uncached final-path application.
Only the native Laravel application, default console kernel and default bootstrap
loaders are supported. Custom application/kernel classes, prebound bootstrap
loaders, Laravel 13 `LoadConfiguration::alwaysUse`, custom base/bootstrap/config/
storage/environment paths, and custom dotenv names are refused. Native dotenv
selection may choose a recorded canonical `.env.*` file before reading its bytes.
Only approved generated leaves change: canonical `bootstrap/cache/config.php`,
`packages.php` and `services.php` are atomically replaced with regenerated data;
default `routes-v7.php` and `events.php` are removed; strictly named regular
`storage/framework/cache/facade-<40-hex>.php` files are removed so web bootstrap can
regenerate them from trusted source. File-cache data, locks and other runtime leaves
remain intact. Original configuration/provider/route/event/facade cache PHP is
never executed or restored.

The bounded canonical runtime/database and zero-pending-migrations audit must pass
before `up`. Up intent is persisted first. Actual framework serving, exact selected
identity, runtime, health URL and the required application verifier are proved under
the same owner. Cron remains paused. A successful result reports
`result=serving ... cron=paused lock=released`; schedule a normal verified deployment
to install or restore that application's managed cron. No consumer SHA pins or
production workflows are changed implicitly by publishing this action.

## Failure, cancellation and explicit restore

EXIT/HUP/INT/TERM restores the saved maintenance marker and rendered file directly,
without Laravel bootstrap, only while exact ownership/identity/storage remain
provable. A failed `up` that removed the marker is recoverable. An unexpected new
marker, changed critical source hashes/identity/cache, replaced lock inode/owner, or unsafe storage
retains the lock and private evidence; neither operator state nor foreign locks are
overwritten. Successfully confirmed maintenance restoration alone permits release.
Rebuilt caches remain; original configuration/provider/route/event/facade cache PHP
is never rolled back. The original rendered maintenance PHP remains part of the
saved maintenance marker payload and is restored directly without executing it.
Restore persists a unique temporary-file intent before creation, then persists its
empty 0600 file's inode before writing maintenance bytes. Interrupted partial writes
resume only that proved inode. A kill between creation and inode persistence retains
the referenced empty private file and lock for manual inspection; it never writes
the maintenance secret into an untracked file. Unfinished temporary intent always
prevents lock release, and replacement files are never adopted or removed.

PHP/state calls have finite memory and 10/45-second deadlines; audits have independent
30/60-second PHP/host limits. The host transaction has 240 seconds plus 45 seconds
for TERM rollback before KILL; SSH is bounded to 330 seconds. All output is file
backed and complete bounded fixed records are validated before reporting. A dropped
connection, SSH timeout or SIGKILL is **not** proof of successful rollback or release.

After proving the interrupted session and descendants stopped, rerun the same pinned
action with `operation: restore`, the **same token, selected identity and persistent
paths**, the same explicit confirmation/stopped assertion, and
`verification-script: '-'`. Restore is filesystem-only: it never rebuilds caches,
boots Laravel, calls `up`, installs cron, or resumes service. Its success reports
`result=restored identity=exact maintenance=original cron=paused lock=released`.
Inspect the incident and use a new token for any subsequently approved resume.

A kill between lock creation and persistence of its inode leaves ownership
unprovable. Empty or partial locks are not automatically adopted. A known empty
initialization with a persisted exact inode can be restored; truncated owner bytes,
missing/malformed records or an unknown inode retain the lock. In these cases:

1. Stop and prove all owning workflows/recovery descendants and application workers
   stopped; retain the workflow log and exact recovery token.
2. Inspect the private record, selected metadata, canonical paths, paused cron and
   lock device/inode/inventory locally on the host. Do not print configuration or
   maintenance payloads in CI logs and do not recursively remove control state.
3. If the record does not prove the exact lock, keep it and investigate the competing
   owner/filesystem event. There is no safe automated unlock for uncertain ownership.
   An operator may remove an independently proven abandoned **empty** lock with
   `rmdir` only after that investigation; preserve the private evidence. A partial or
   foreign lock requires its own owner's recovery procedure.

The shell fixtures cover these refusal states, exact byte/mode rollback, TERM during
up/verification, SIGKILL followed by explicit restore, replacement identity/storage/
owner/inode, and malformed initialization. Real Laravel 12/13 fixtures additionally
prove source cache generation, actual local application HTTP identity, forged old
cache isolation, bootstrap-independent restoration and subsequent normal deployment.
