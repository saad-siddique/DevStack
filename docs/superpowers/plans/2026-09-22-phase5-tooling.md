# Phase 5 Tooling Implementation Plan (phpMyAdmin, site-new/import/remove, Xdebug, service control, dashboard)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline; the work mutates this machine and drives Valet/brew through passwordless sudo). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the stack usable day to day: a DB browser, one-command site creation and LocalWP import, an Xdebug toggle, service start/stop, and a dashboard that shows and controls all of it.

**Architecture:** Everything is a `bin/` command with `--json`; the dashboard is a thin PHP page that calls those commands (reads via `stack-status`, writes via `service` and `php-xdebug`). Shared per-site steps (link, isolate, secure, mu-plugin, smoke) move into `bin/lib.sh` as `site_finalize` and are used by `site-new` and `site-import`; `migrate-site` keeps its proven flow untouched.

**Tech Stack:** bash, jq, WP-CLI, Valet, Homebrew (`shivammathur/extensions` for prebuilt Xdebug), phpMyAdmin 5.2.x, PHP for the dashboard (no build step, inline CSS/JS).

**Spec:** the approved design in chat (2026-09-22): importer = LocalWP zip + folder/SQL; phpMyAdmin auto-login as root; Xdebug port 9003 trigger mode; dashboard viewer **with** start/stop + Xdebug toggle.

## Global Constraints

- No Docker. Homebrew formulae only. Third-party web apps (phpMyAdmin) are downloaded by bootstrap into `~/.local/share/local-devstack/`, never committed.
- Sites are linked, never parked. New sites get a per-site DB user, `DB_HOST=127.0.0.1`, the local-SSL mu-plugin, HTTPS.
- Dashboard actions: POST only, require header `X-Devstack: 1` (cross-origin requests cannot add it without a CORS preflight, which is never answered), allowlisted service names and ops only, executed through `bin/service` / `bin/php-xdebug`, never raw shell from request input.
- PHP files: WordPress coding style, tabs, Yoda conditions. Shell: `set -euo pipefail`.
- Everything idempotent. Commit per task; push at the end.

---

### Task 1: Bootstrap additions — Xdebug formulae (installed, off by default), phpMyAdmin, ini settings

**Files:** Modify `Brewfile`, `bootstrap.sh`, `php/zz-uo-dev.ini`.

- [ ] Brewfile: add `tap "shivammathur/extensions"`, `brew "shivammathur/extensions/xdebug@7.4"`, `brew "shivammathur/extensions/xdebug@8.4"`.
- [ ] `php/zz-uo-dev.ini`: append
```ini
; Xdebug (extension is toggled by bin/php-xdebug; these are inert while it is off)
xdebug.mode = debug
xdebug.start_with_request = trigger
xdebug.client_host = 127.0.0.1
xdebug.client_port = 9003
xdebug.log_level = 0
```
- [ ] bootstrap.sh: `ensure_formulae` also taps/trusts `shivammathur/extensions`. New `ensure_xdebug_default_off`: for each version, if `conf.d/20-xdebug.ini` exists and no `.enabled` marker → rename to `20-xdebug.ini.off` (first install only; later runs respect the current state). New `ensure_phpmyadmin`: download `https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip` to `~/.local/share/local-devstack/phpmyadmin` if `index.php` missing; write `config.inc.php` (`auth_type=config`, user root, empty password, `AllowNoPassword`, host 127.0.0.1, `blowfish_secret` random 32 chars, `TempDir` = `<dir>/tmp`); `valet link phpmyadmin` from that dir; `valet secure phpmyadmin`.
- [ ] Verify: `./bootstrap.sh` completes; `/usr/bin/curl -s https://phpmyadmin.test/ | grep -c 'uo_uncanny-automator'` ≥ 1 (auto-login shows DB list); `php -m | grep -c xdebug` → 0; `ls /opt/homebrew/etc/php/{8.4,7.4}/conf.d/20-xdebug.ini.off` both exist.
- [ ] Commit: `Bootstrap: prebuilt Xdebug (off by default), phpMyAdmin with auto-login, Xdebug ini defaults`

### Task 2: `bin/php-xdebug` and `bin/service`

**Files:** Create `bin/php-xdebug`, `bin/service` (executable).

**Interfaces:** `php-xdebug on|off|status [--php 8.4|7.4|all] [--json]` → JSON `{"8.4":true,"7.4":false}`; `service <name> start|stop|restart|status [--json]` → JSON `{name,status,user}`; allowlist `nginx dnsmasq php@8.4 php@7.4 mysql@8.4 mailpit`.

- [ ] `php-xdebug`: state = `conf.d/20-xdebug.ini` present (on) vs `20-xdebug.ini.off` (off). `on`/`off` rename accordingly then `valet restart` once (only if state changed). `status` prints per version. Uses `valet()` from lib.sh.
- [ ] `service`: root-domain services (`nginx dnsmasq php@*`) go through `sudo -n /opt/homebrew/bin/brew services <op> <name>`; user-domain (`mysql@8.4 mailpit`) through plain `brew services`. `status` reads `brew services list --json` from both domains like `stack-status`.
- [ ] Verify: `bin/php-xdebug on --php 8.4 --json` → `{"8.4":true,...}` and `/opt/homebrew/opt/php@8.4/bin/php -m | grep -c xdebug` = 1 and `curl -s 'https://dashboard.test/?api=php' ` (Task 5) later; `bin/php-xdebug off --php 8.4`; `bin/service mailpit stop --json` → status `none`, `bin/service mailpit start --json` → `started`; `bin/service bogus start` → exit 1.
- [ ] Commit: `Add php-xdebug toggle and service control commands`

### Task 3: `site_finalize` in lib.sh, `bin/site-new`, `bin/site-remove`

**Files:** Modify `bin/lib.sh`; create `bin/site-new`, `bin/site-remove`.

**Interfaces:** `site_finalize <host> <path> <php-formula>` (link if missing, `.valetrc` + isolate if php ≠ default, secure if missing, mu-plugin copy if WP, smoke → sets `SMOKE_JSON`); `db_ensure_user <db> <user> <pass>`; `site-new <name> [--php 7.4] [--empty] [--title T] [--admin-user U] [--admin-email E] [--json]`; `site-remove <name> [--yes] [--keep-files] [--keep-db]`.

- [ ] `site-new`: refuse if `~/Sites/<name>` exists or name not `[a-z0-9-]+`; WP path: `wp core download`, DB `wp_<name>` (dashes→underscores), user `wp_<name>` with random 20-char password, `wp config create` (`DB_HOST 127.0.0.1`, extra PHP: `WP_DEBUG true`, `WP_DEBUG_LOG true`, `WP_DEBUG_DISPLAY false`), `wp core install` with `--url=https://<name>.test`, admin user (default `admin`), random password printed once (and in JSON), then `site_finalize`. `--empty`: mkdir + `index.php` placeholder + finalize only.
- [ ] `site-remove`: `valet unsecure`, `valet unlink`, drop DB + user (from wp-config) unless `--keep-db`, `rm -rf` folder unless `--keep-files`; requires `--yes`; refuses protected sites from `sites.tsv`.
- [ ] Verify: `bin/site-new devstack-smoke --php 7.4 --json` → ok true, fpm `PHP/7.4.33`, `wp core version` works under `valet php`; `bin/site-remove devstack-smoke --yes` → folder, link, cert, DB and user gone; `bin/site-new` on an existing name exits 1.
- [ ] Commit: `Add site-new and site-remove with shared site_finalize`

### Task 4: `bin/site-import`

**Files:** Create `bin/site-import`.

**Interfaces:** `site-import <name> <source> [--php 8.4] [--json]`; source = LocalWP export `.zip`, any `.zip` containing a WP root, a folder, or `--sql path` with a folder.

- [ ] Detection: unzip (if zip) to a temp dir; WP root = directory containing `wp-config.php` (fall back to `wp-settings.php`); SQL = `--sql` if given, else the largest `*.sql` in the source (LocalWP: `app/sql/local.sql`). Copy WP root to `~/Sites/<name>` (rsync). Read `DB_USER`/`DB_PASSWORD`/`table_prefix` from wp-config; create DB `wp_<name>` (override wp-config `DB_NAME`), `db_ensure_user`, import SQL (`--force`), `DB_HOST 127.0.0.1`, remove LocalWP-specific `WP_HOME/WP_SITEURL` if they point elsewhere, read old `siteurl` from `<prefix>options`, `wp search-replace <old> https://<name>.test --all-tables --skip-columns=guid` (both `https://` and `http://` variants of the old host), then `site_finalize`.
- [ ] Verify by fabricating a LocalWP-shaped export from `cleantest`: `mkdir -p /tmp/x/app/{public,sql}; rsync ~/Sites/cleantest/ /tmp/x/app/public/; mysqldump wp_cleantest_db > /tmp/x/app/sql/local.sql; zip -r cleantest-export.zip app` → `bin/site-import import-smoke cleantest-export.zip --json` → ok true, `siteurl https://import-smoke.test`, login 200; then `bin/site-remove import-smoke --yes`.
- [ ] Commit: `Add site-import for LocalWP exports and folder+SQL sources`

### Task 5: Dashboard rewrite (load `frontend-design` first)

**Files:** Rewrite `dashboard/index.php`; create `dashboard/app.js`, `dashboard/style.css` (served as static by Valet).

**Interfaces:** `GET /?api=status` → `bin/stack-status` JSON plus `{xdebug:{"8.4":bool,"7.4":bool}, links:{phpmyadmin,mailpit}}`; `POST /?api=service` body `name`, `op` → `bin/service`; `POST /?api=xdebug` body `php`, `op` → `bin/php-xdebug`. All POSTs require header `X-Devstack: 1` else 403; unknown name/op → 400. Shell calls use `escapeshellarg`, absolute paths, `HOME` set.

- [ ] UI: header with stack summary (sites, PHP versions, MySQL version, qps); **Services** grid: pill on/off, start/stop/restart buttons, Xdebug toggle per PHP; **Sites** list/cards: name → https link, PHP badge, HTTPS badge, wp-admin link when WP, path; **Tools**: phpMyAdmin, Mailpit. Filter box for sites. Auto-refresh every 5 s (paused while an action runs). Light/dark via `prefers-color-scheme`. System font stack, no external assets.
- [ ] Verify: `curl -s 'https://dashboard.test/?api=status' | jq .services` works; `curl -X POST 'https://dashboard.test/?api=service' -d 'name=mailpit&op=stop'` → 403; same with `-H 'X-Devstack: 1'` → JSON status `none`, then `op=start` → `started`; screenshot in the built-in browser shows services and sites.
- [ ] Commit: `Dashboard: modern viewer with service control and Xdebug toggle`

### Task 6: Docs + push

- [ ] README: status, new commands, dashboard actions security note, Xdebug usage (browser extension / `XDEBUG_TRIGGER`), phpMyAdmin URL. Handoff: Phase 5 done.
- [ ] `git add -A && git commit && git push`.
