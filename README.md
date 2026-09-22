# local-devstack

Native (no Docker, no VM) local WordPress dev stack for macOS on Apple Silicon:
Laravel Valet + Homebrew PHP (8.4 default, 7.4 for compatibility sites) + `mysql@8.4` + Mailpit + WP-CLI,
plus the scripts that migrate sites off MAMP PRO and, later, a small menu-bar app that drives the same scripts.

**Status (2026-09-22):** Phase 1 (base stack) and Phase 2 (tooling) built; pilots `cleantest` (php@8.4) and
`clean-automator` (php@7.4) migrated and green. All other sites still run on MAMP PRO. Not built yet:
`bin/site-new`, `bin/site-import`, `bin/php-xdebug`, the `app/` menu-bar app, phpMyAdmin.

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
bin/                  THE CONTRACT — every command supports --json
                      site-new  site-import  migrate-site  migrate-all  php-xdebug  php-switch  stack-status
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
- Mail from Valet sites reaches MAMP's MailHog on :1025 until MAMP is stopped; MailHog's UI/API live under
  `http://localhost:8025/mailhog/`. Mailpit takes over the same ports afterwards (bootstrap starts it when free).
- `wp search-replace` skips `guid` on purpose; a handful of `https://<host>:8890` GUIDs remain and that is fine.
