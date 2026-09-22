# CLAUDE.md — local-devstack

Read `docs/mamp-to-valet-migration-handoff-v2.md` before changing anything; it is the spec and holds the
live inventory of the 24 MAMP hosts, the decisions (section 10) and the gotchas (section 9).

## Conventions
- KISS first. Bash for `bin/*` (`set -euo pipefail`, `--json` flag on every command, exit non-zero on failure).
- PHP (`dashboard/`, `drivers/`, `mu-plugins/`): WordPress coding standards, tabs, **Yoda conditions**.
- Every script must be idempotent and safe to re-run on an already-migrated site.
- Nothing here ever edits `php.ini` in place; PHP settings go in `php/zz-uo-dev.ini` copied to `conf.d/`.
- Valet machine-local state (`~/.config/valet`) and SQL dumps are never committed.

## Hard rules
- `uncanny-automator` is a protected site (handoff 6.1): `migrate-all` skips it; `migrate-site` refuses without
  the explicit backup flag. Do not weaken this.
- `automator-platform` is out of scope (Docker-only). Do not link, park or list it.
- Do not uninstall or modify MAMP while any site still depends on it; the rollback is "start MAMP".
- No Docker anywhere in this repo.

## Environment facts (verified 2026-09-22, macOS 27, Apple Silicon)
- Homebrew has `arm64_golden_gate` bottles for php@8.4, nginx, dnsmasq, mysql@8.4, mailpit; `shivammathur/php`
  provides php@7.4 with bottles (`brew trust shivammathur/php` required).
- Valet 4.12.0 needs the IPv6 `listen [::1]` workaround (handoff 9.7) until the next release.
- The macOS 27 ObjC fork crash affects MAMP php-cgi, not Homebrew php-fpm (handoff 9.1).
