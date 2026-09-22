# local-devstack

Native (no Docker, no VM) local WordPress dev stack for macOS on Apple Silicon:
Laravel Valet + Homebrew PHP (8.4 default, 7.4 for compatibility sites) + `mysql@8.4` + Mailpit + WP-CLI,
plus the scripts that migrate sites off MAMP PRO and, later, a small menu-bar app that drives the same scripts.

**Status (2026-09-22):** **All 24 hosts run on Valet**, including the protected `uncanny-automator` (Phase 4b done
from a restore-tested backup). PHP 7.4 hosts: `clean-automator`, `automator-docs`, `elearning-docs`. Multisite: `wpmu`.
Non-WP: `automator-api`, `uo-ap-edd-licensing`, `basecamp`, `learndash-docs`. Mailpit owns :1025/:8025.
MAMP PRO is still installed and still holds the original copy of every database as rollback; Phase 6 (decommission)
waits a working week. Not built yet: `bin/site-new`, `bin/site-import`, `bin/php-xdebug`, the `app/` menu-bar app.

Plan and inventory: `docs/mamp-to-valet-migration-handoff-v2.md` (section 0 summary, 6 phases, 10 decisions).
Execution log of the pilot: `docs/superpowers/plans/2026-09-22-phase1-3-pilot.md`.

## Layout (target — see handoff section 11)

```
Brewfile              php@8.4, shivammathur/php/php@7.4, mysql@8.4, mailpit, wp-cli, composer
bootstrap.sh          idempotent; the only thing a teammate must run (`--app` also builds the menu-bar app)
php/                  zz-uo-dev.ini drop-in, copied into each /opt/homebrew/etc/php/<v>/conf.d/
drivers/              LocalValetDriver for the subdirectory multisite (wpmu)
mu-plugins/           uo-local-ssl.php (https_ssl_verify → false, local only)
dashboard/            interim dashboard.test (one PHP file), retired once app/ exists
bin/                  THE CONTRACT — every command supports --json where output is consumed by tooling
                      migrate-site  migrate-all  stack-status  mamp-backout   (built)
                      site-new  site-import  php-xdebug  php-switch          (not yet)
app/                  SwiftUI MenuBarExtra + Swift Charts (macOS 13+), Swift Package; only ever calls bin/*
docs/                 the handoff/plan and, later, runbooks
```

## Ground rules

- No Docker for WordPress. Homebrew formulae and native binaries only.
- `bootstrap.sh` never depends on `app/`. The app never talks to brew/valet/mysql directly; it calls `bin/*`.
- `uncanny-automator` is a **protected site**: never in a batch, never first, only with a verified fresh backup
  and an explicit flag. See handoff section 6.1.
- `automator-platform` (Docker-only Laravel) is out of scope and must not be served by Valet.
- Scripts are idempotent: re-running on a migrated site is a no-op.

## Quick start

```bash
git clone git@github.com:saad-siddique/local-devstack.git ~/Work/local-devstack
cd ~/Work/local-devstack && ./bootstrap.sh        # asks for sudo twice on a fresh Mac (valet install, valet trust)
bin/migrate-site cleantest --json                 # one site: link → isolate → secure → DB copy → DB_HOST → URLs → smoke
bin/migrate-all                                   # everything in sites.tsv except protected sites
bin/stack-status | jq .                           # services, sites, ports, MySQL qps, mail catcher
bin/mamp-backout                                  # after MAMP PRO is stopped: hosts entries, helper daemon, shell hooks
```

`bootstrap.sh` is idempotent and safe to re-run. After `valet trust` it is fully non-interactive, so agents and
scripts can run it too.

## Things learned the hard way (see handoff section 9 for the rest)

- `brew bundle` un-links keg-only `php@8.4`; the Brewfile pins `link: true` and bootstrap re-links before Valet runs.
- Valet's `valet` wrapper re-execs itself through `sudo`; the sudoers alias from `valet trust` matches
  `/opt/homebrew/bin/valet` only, and in a non-TTY shell the wrapper's own sudo hop still prompts. `valet()` in
  `bin/lib.sh` goes through `sudo -n` directly once trust exists.
- Valet 4.12.0 answers `.test` with `::1` but its nginx stubs only listen on `127.0.0.1`; bootstrap patches the stubs
  and the generated confs (`listen [::1]:…`) so Safari does not 404.
- Mail from Valet sites reaches whatever listens on :1025. While MAMP's MailHog runs, that is MailHog (UI under
  `http://localhost:8025/mailhog/`). After disabling MailHog in MAMP PRO, run `brew services start mailpit` (or
  re-run `bootstrap.sh`); the sites need no change because `sendmail_path` already points at `mailpit sendmail`.
- Right after `valet secure`/`isolate`, nginx and php-fpm restart; a smoke test fired immediately sees 502/503.
  `wait_for_site` in `bin/lib.sh` polls first.
- `WP_HOME`/`WP_SITEURL` constants in wp-config override the database; `migrate-site` rewrites them when they
  point at the MAMP host. `display_errors=On` sends CLI warnings to stdout, so WP-CLI is run with
  `-d display_errors=stderr` whenever its output is captured.
- `wp search-replace` skips `guid` on purpose; a handful of `https://<host>:8890` GUIDs remain and that is fine.
- A stale `VIEW` whose base table is gone makes `mysqldump` abort. The dump runs with `--force`, the import compares
  base tables only and reports missing views; Automator rebuilds its `*_uap_*_logs_view` via
  `wp eval 'Automator_DB::create_views();'`.
- Several sites move wp-login.php (`/login/`, `/frontend-login/`); the login-form smoke check is informational only.
- View `DEFINER`s must exist before `CREATE VIEW` runs on import: `migrate-site` creates the site's DB user first, and
  any extra definer (e.g. the Codeception DB user) must be created by hand beforehand.
- MAMP's vhost serves the *same* folder, so after migration it too reads the new database through the rewritten
  wp-config. Rollback for a site is: restore its wp-config.php from `~/migration-log/*-files-pre.tgz`; MAMP's database
  copy was never touched.
- MAMP PRO rewrites `~/.profile` (PATH + `php`/`mysql`/`python` aliases) every time it runs, even on quit. `bin/mamp-backout`
  strips it and appends a guard to `~/.zshrc` that un-aliases and de-paths anything MAMP re-adds.
- "Class not found" fatals after switching plugin branches are a stale Composer classmap: `composer dump-autoload`
  in the plugin repo, not a stack problem.
