# local-devstack

Native (no Docker, no VM) local WordPress dev stack for macOS on Apple Silicon:
Laravel Valet + Homebrew PHP (8.4 default, 7.4 for compatibility sites) + `mysql@8.4` + Mailpit + WP-CLI,
plus the scripts that migrate sites off MAMP PRO and, later, a small menu-bar app that drives the same scripts.

**Status:** planning complete, nothing built yet. Start with `docs/mamp-to-valet-migration-handoff-v2.md`
(section 0 is the summary, section 6 the phases, section 10 the decisions).

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

## Quick start (to be filled in during Phase 1)

```bash
git clone <this repo> ~/Work/local-devstack
cd ~/Work/local-devstack && ./bootstrap.sh
```
