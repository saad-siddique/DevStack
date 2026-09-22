# Phase 7 — `devstack` global command, backups, DevStack menu-bar app

**Built 2026-09-22.** Record of the design decisions and what shipped; the README documents usage.

## Why

Every `bin/` script required `cd ~/Work/local-devstack` first. Teammates wanted the commands from any terminal and,
for the common ones (new site, import, remove, back up, start/stop, Xdebug), from a GUI. The handoff (section 11)
had already decided: same repo, SwiftUI `MenuBarExtra`, the app is a skin over `bin/*` and never talks to
brew/valet/mysql itself.

## Design

1. **`bin/devstack` dispatcher**, symlinked by `bootstrap.sh` to `/opt/homebrew/bin/devstack`. It follows the
   symlink back to the repo, forces `/opt/homebrew/bin` to the front of `PATH` (GUI apps start with a bare
   environment), and maps verbs to scripts: `new import backup backups remove sites open migrate migrate-all status
   service xdebug logs logs-prune bootstrap update app path`. Any `bin/` name also works. `completions/_devstack`
   is linked into `share/zsh/site-functions`.
2. **`bin/site-backup <site>`** → `~/Backups/local-devstack/<site>/<stamp>/{files/, db.sql.gz, manifest.json}`.
   `files/` is `cp -Rc` (APFS clone, instant, shares blocks); the dump uses `mysqldump --force` (stale Automator
   views) and gzip. `--list` prints every backup with live size. It is read-only on the site, so it is the one
   command allowed on the protected site. `site-import` gained `.sql.gz` support and reads the manifest's PHP
   version, so a backup folder is a valid import source (restore, or clone under a new name). `site-remove --backup`
   backs up first and aborts on failure.
3. **`bin/app`**: `swift build -c release` (Swift Package, no Xcode project), bundle assembly (Info.plist template,
   `Tools/MakeIcon.swift` renders the icon, `codesign --sign -` or `--sign IDENTITY`), `install` to
   `/Applications/DevStack.app` and relaunch, `snapshot` to render the UI to `docs/img/*.png`, `status`, `uninstall`.
   It prefers Xcode's toolchain when `xcodebuild -checkFirstLaunchStatus` passes, else the Command Line Tools.
4. **`app/`** (macOS 14+):
   - `Runner.swift` — the only way out: runs `/opt/homebrew/bin/devstack …`, captures or streams lines, decodes
     `--json` with `convertFromSnakeCase`.
   - `Models.swift` — mirrors `stack-status` JSON (`services`, `php[]`, `sites[]` incl. the new `protected` flag,
     `ports`, `mysql`, `mail`) and the job result (`url`, `admin_user`, `admin_password`, `path`).
   - `AppState.swift` — status, cadence (60 s while the panel is open, 300 s while closed, CPU samples only while
     open), quick actions (service/fpm toggle, restart, Xdebug) and jobs (new/import/backup/remove) streamed into a
     `TaskLog`. Login item via `SMAppService`.
   - `UsageSampler.swift` — `ps -axo pcpu,rss,comm` filtered to php-fpm, nginx, mysqld, redis-server, memcached,
     mailpit, dnsmasq; 60 samples.
   - `PanelView.swift` — header + quick-open buttons, `UsageChart` (Swift Charts), segmented Sites / Services /
     PHP. `ModalViews.swift` — New site, Import (NSOpenPanel), Remove (backup-first default, protected disabled),
     Task log with result card. `Snapshot.swift` — `--snapshot DIR` renders each window without activating the app.

## Gotchas met

- The 2026 SDK's `@State` is a macro; the Command Line Tools lack the `SwiftUIMacros` plugin. Replaced `@State`
  with a `FormModel: ObservableObject` (`@StateObject`), which builds on both toolchains.
- `.foregroundStyle(cond ? .secondary : .red)` does not type-check (HierarchicalShapeStyle vs Color); spell both as
  `Color`.
- The first snapshot run activated the app and captured a keystroke meant for another app. Snapshot now uses
  `orderFrontRegardless()` without activating. Own-window capture via `CGWindowListCreateImage` needs no
  screen-recording permission.
- zsh expands `=word` to a command path; `echo =====` fails. Quote separators in shell one-liners.

## Verified

- `devstack version|path|help|sites` from `/`; `devstack backup cleantest` (43 tables, 10 546 files, 2.7 s);
  `devstack import cleantest-restore <backup>` → smoke ok (ipv4/ipv6 200, siteurl rewritten, loopback OK);
  `devstack remove cleantest-restore --yes --backup` → backup, drop, unsecure, unlink, delete, site answers 404.
- `devstack app build` (Command Line Tools, Swift 6.4), `devstack app snapshot` → `docs/img/{panel,new-site,import,
  remove,task}.png`, `devstack app install` → `/Applications/DevStack.app` running as a menu-bar item.

## Follow-up the same afternoon: admin defaults and one-click login

- `site-new` takes `--admin-user/--admin-password/--admin-email` (defaults `admin` / `admin1` / `admin@example.test`);
  the New site form exposes them. The password is no longer random, so "shown once" is gone.
- `mu-plugins/uo-local-autologin.php` + `bin/site-login` (`devstack login <site>`): one-time token (48 hex, 60 s,
  SHA-256 stored as a transient via WP-CLI), `.test` host check, `hash_equals`, `wp_set_auth_cookie`, redirect to
  wp-admin, 403 on reuse. `install_mu_plugins` in lib.sh now copies every repo mu-plugin (site_finalize,
  migrate-site, site-login on demand). Verified with curl on `cleantest` (302 → wp-admin, "Howdy, admin", reuse 403)
  and on a fresh `logintest` (also password login admin/admin1 → 302 wp-admin).
- App: key icon and "Log in to wp-admin" per site, "Log in to wp-admin" on the task result card after New site.

## Later the same day: repo updates, stack upgrades, icon, guards

- `bin/update` (repo: --check / pull + bootstrap / app rebuild when app/ changed) and `bin/stack-upgrade`
  (Homebrew: --check / --auto patch / --all; --nightly obeys settings.json auto_upgrade, default off = report only;
  LaunchAgent com.devstack.upgrade 03:30). Saad's call: prompt, never auto-apply by default; opt-in for patches.
- Icon: app/Icon.svg → AppIcon.icns, favicon.png, apple-touch-icon.png, MenuBarIcon(.Alert) template images.
- Guards found by looking at the machine: `.diag` resource reports (mysqld 34 GB dirtied, php-fpm 2 GB) had been
  counted as crashes → `logs crashes` now classifies crash vs resource; php-fpm hit `pm.max_children = 5` →
  `php/zz-devstack-fpm.conf` (20 workers, max_requests 500, terminate 300 s, slowlog 15 s) merged over Valet's pool;
  MySQL binlog 7.1 GB → `mysql/zz-devstack.cnf` (disable_log_bin, flush 2, 512 M pool, 256 M packet) and stale
  binlogs removed; `bin/doctor`; `bin/site-php`; app: notifications, runaway watch (sampler always on: 3 s / 60 s),
  reports line, site php-fpm-stopped warning, PHP version submenu, Open in editor/terminal, Run doctor.
- bash 3.2 bit twice: `mapfile` and `case` patterns inside `$( )` (write `(*.ips)`).
