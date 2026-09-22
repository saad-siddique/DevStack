# Migrating sites from MAMP or MAMP PRO

DevStack was built while moving two dozen sites off MAMP PRO. The migration tooling stays in `bin/` for anyone in the
same spot. It never modifies MAMP's copy of anything, so the rollback at every step is "start MAMP again".

## 1. Inventory

Copy `sites.tsv` to `sites.local.tsv` (git-ignored) and list one row per MAMP host:

| column | meaning |
|---|---|
| `host` | the site name; becomes `https://<host>.test` and the Valet link name |
| `folder` | its directory under `~/Sites` (usually equal to `host`) |
| `php` | `php@X.Y` it should run on, 7.4 to 8.6 |
| `db` | the database in MAMP's MySQL to copy, or `-` for a site without WordPress |
| `protected` | `yes` for a site the tooling must never remove, archive or batch-migrate |
| `notes` | free text |

MAMP PRO's own host list is in `~/Library/Application Support/appsolute/MAMP PRO/` if you need to check names, ports
and PHP versions.

## 2. Install DevStack beside MAMP

`./bootstrap.sh --app` while MAMP still runs. Only Mailpit collides (ports 1025/8025) with MAMP's MailHog; disable
MailHog in MAMP PRO or start Mailpit later with `devstack service mailpit start`. MAMP's MySQL stays on 8889, Homebrew's
on 3306, which is exactly what the copy needs.

## 3. Pilot one site, then the rest

```bash
devstack migrate cleantest --json      # one disposable site first
devstack migrate-all                   # everything in sites.local.tsv except protected sites
devstack migrate <protected> --i-have-a-backup   # a protected site: alone, last, with a fresh backup
```

Per site, `migrate-site` links the folder, isolates its PHP version, secures it, creates the database user, dumps the
MAMP database (`mysqldump --force`, so a stale view cannot abort it) and imports it into MySQL 8.4, sets
`DB_HOST 127.0.0.1`, rewrites every old URL (`https://<host>:8890`, `http://<host>:8888`, bare `<host>:8890`) with
`wp search-replace`, replaces `WP_HOME`/`WP_SITEURL` constants that still point at MAMP, installs the mu-plugins and
smoke-tests the result (IPv4 and IPv6 200, no fatal in the body, `siteurl`, loopback). It is idempotent: running it
again on a migrated site is a no-op. Logs land in `~/Library/Logs/DevStack/`, pre-migration dumps beside them.

Subdirectory multisites need `drivers/LocalValetDriver-multisite-subdir.php` copied into the site as
`LocalValetDriver.php`; `migrate-site` does that when it detects a multisite.

## 4. Back MAMP out

When every site is green and you have lived on Valet for a while:

```bash
devstack mamp-backout      # /etc/hosts entries, the privileged helper daemon, ~/.profile PATH and aliases, a ~/.zshrc guard
```

MAMP PRO rewrites `~/.profile` every time it runs, even on quit; the guard appended to `~/.zshrc` neutralises anything
it re-adds. `/Applications/MAMP` and `MAMP PRO.app` are yours to delete once the rollback window has passed.

## Things that bit

See "Things learned the hard way" in the README: view definers, stale views, `WP_HOME` constants, `display_errors`
on stdout, the stray `~/Sites/wp-config.php`, and the IPv6 listen patch Valet 4.12 needs.
