# CLAUDE.md — DevStack

Read `README.md` first: it documents every command, the guards and the things learned the hard way. The MAMP
migration is described in `docs/migrating-from-mamp.md`; the real site inventory lives in the git-ignored
`sites.local.tsv` (the committed `sites.tsv` is an example) and internal runbooks in the git-ignored `docs/private/`.
The repo is public: never commit site names, database names, hostnames, tokens or screenshots of real data
(`devstack app snapshot` renders fixtures for a reason).

## Conventions
- KISS first. Bash for `bin/*` (`set -euo pipefail`, `--json` flag on every command, exit non-zero on failure).
- `bin/devstack` is the public surface: a new `bin/` script gets a verb there, a line in `completions/_devstack`
  and in the README's command block. Scripts resolve their own paths (`lib.sh`) and never assume the cwd.
- `app/` (Swift, tabs): the app only ever runs `devstack …` and decodes `--json`; no brew/valet/mysql calls, no
  `@State` (the SDK macro needs Xcode; use the `FormModel` ObservableObject pattern), no self-activation in unattended
  code. Check UI changes with `devstack app snapshot` and look at `docs/img/*.png`. Build with `devstack app build`.
- PHP (`dashboard/`, `drivers/`, `mu-plugins/`): WordPress coding standards, tabs, **Yoda conditions**.
- Every script must be idempotent and safe to re-run on an already-migrated site.
- Never `nohup` in `bin/` or the dashboard: without a console (php-fpm, LaunchAgents) macOS's nohup exits instead of
  running the command. Background with `cmd < /dev/null > log 2>&1 &` and `disown`.
- bash 3.2 (macOS) only: no `mapfile`, no `declare -A`; `case` patterns inside `$( … )` must be written `(pattern)`.
- Nothing here ever edits `php.ini` in place; PHP settings go in `php/zz-uo-dev.ini` copied to `conf.d/`.
- Valet machine-local state (`~/.config/valet`) and SQL dumps are never committed.
- `mu-plugins/*.php` must stay inert off `.test` hosts (check `HTTP_HOST`) and PHP 7.4-compatible; `install_mu_plugins`
  in `bin/lib.sh` copies all of them, so a new one needs no wiring.

## Hard rules
- Sites marked `protected=yes` in `sites.local.tsv` are never removed, archived or batch-migrated; `migrate-site`
  refuses them without the explicit backup flag. Do not weaken this.
- Docker-only applications that happen to live under ~/Sites are out of scope: never link, park or list them.
- `site-remove` (and the app's Remove) must keep refusing protected sites; `site-backup` is the one write-free command
  allowed on them.
- Do not uninstall or modify MAMP while any site still depends on it; the rollback is "start MAMP".
- No Docker anywhere in this repo.

## Environment facts (verified 2026-09-22, macOS 27, Apple Silicon)
- Homebrew has `arm64_golden_gate` bottles for php@8.4, nginx, dnsmasq, mysql@8.4, mailpit; `shivammathur/php`
  provides php@7.4 with bottles (`brew trust shivammathur/php` required).
- Valet 4.12.0 needs the IPv6 `listen [::1]` workaround (handoff 9.7) until the next release.
- The macOS 27 ObjC fork crash affects MAMP php-cgi, not Homebrew php-fpm.
- Xcode.app may be installed but unusable until its licence is accepted; `bin/app` checks
  `xcodebuild -checkFirstLaunchStatus` and falls back to the Command Line Tools, which build everything except that
  the SDK's `@State` macro plugin is missing (hence the `FormModel` pattern in `app/`).
