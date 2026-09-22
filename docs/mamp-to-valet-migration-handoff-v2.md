# Handoff v2: MAMP PRO 7.2.8 → Laravel Valet (native Homebrew) — reviewed against the live machine

Reviewed 2026-09-21/22 on the actual MacBook (macOS 27.0 / Darwin 27, Apple Silicon, Homebrew 7.0.6). External facts (Valet, Herd, tap bottles, Mailpit, CA trust) verified against upstream sources on 2026-09-22; see 9.5.
Everything marked ✅ was verified on this machine today. ⚠️ = verify during the build. ❌ = v1 assumption that was wrong.

---

## 0. Executive summary (read this if nothing else)

The v1 plan is directionally right (Valet, `.test`, per-site PHP, Mailpit, WP-CLI, one pilot then batch). It over-builds in three places and misses five real gotchas.

**Cut from scope**
- ❌ `.site.conf` schema + reader. Valet already has a per-project `.valetrc` (`php=php@8.4`) that `valet isolate` reads. Use it. ✅ (confirmed in Valet `Site.php`)
- ❌ Per-site opcache / xdebug / redis / memcached toggles. Current MAMP reality: Xdebug is loaded in **zero** PHP versions, opcache is on everywhere, and exactly one site (`wpmu`) has an object-cache drop-in. Parity is "opcache on, redis extension available". Xdebug becomes an optional Phase 5.
- ❌ Six PHP versions. Only **two** are in use: `php8.4.1` (21 hosts) and `php7.4.33` (3 hosts: `automator-docs`, `elearning-docs`, `clean-automator`).

**Gotchas v1 missed**
1. Old URLs are `https://<bare-hostname>:8890` (MAMP uses `/etc/hosts` names with **no TLD**, Apache on 8888/8890). The search-replace pair is `https://<host>:8890` → `https://<host>.test`. ✅
2. DB is **MySQL 8.0.40** with 16 tables on `utf8mb4_0900_ai_ci` and 5 app users on `mysql_native_password`. Target: **`mysql@8.4` (LTS)**. MariaDB < 11.4.5 rejects the collation (11.4.5+ aliases it), and Homebrew's plain `mysql` formula is 26.x and has removed `mysql_native_password`. 8.4 is the closest match to MAMP's 8.0 and to production. ✅
3. `wpmu` is a **subdirectory multisite** (5 blogs, `DOMAIN_CURRENT_SITE = 'wpmu:8890'`). Valet's core WordPress driver has **no** subdirectory-multisite rewrites — it needs a ~20-line `LocalValetDriver.php`. ✅ (checked driver source)
4. Two hosts whose name ≠ folder: `automator-plugin-platform` → `~/Sites/uncanny_automator_plugin_platform`, `learndash-docs` → `~/Sites/learndsah-docs`. `valet park` alone gives you the wrong hostnames; use `valet link`. ✅
5. `~/.profile` and `~/.zshrc` pin `php`, `mysql`, `mysqldump`, `pecl`, `python` to MAMP binaries via PATH + aliases. `wp --info` **already** reports MAMP's PHP as its binary. If these are not removed, the new stack is silently bypassed on the CLI. ✅
6. **Valet 4.12.0 (current release) has an IPv6 bug on macOS 26/27**: dnsmasq answers `.test` with `::1`, but the released nginx stub only listens on `127.0.0.1`, so Safari (Happy Eyeballs) intermittently 404s. Fixed on `master`, unreleased. One-line nginx workaround in 9.7. ✅ (laravel/valet #1558, source-verified)

**Good news**
- The macOS 27 ObjC fork crash that the other session fixed today is a **MAMP `php-cgi` problem, not a Homebrew php-fpm problem**. Probed on a throwaway port with `curl_exec()` to an **IPv4-only** host (github.com, the case that triggers it) from forked workers: Homebrew `php-fpm` 8.4.25 and 8.5.10 answered 12/12; MAMP's `php-cgi` 7.4.33 without the env fix, same test, died 6/6 and wrote two new `php-cgi-*.ips` crash reports. ✅ Herd's bundled PHP *did* hit this on macOS 27 (fixed in Herd 1.30.1), so keep the fallback in 9.1.
- Homebrew has native bottles for macOS 27 (`arm64_golden_gate`) for php, php@8.2–8.5, mysql@8.4, nginx, dnsmasq, mailpit, memcached. ✅
- Ports 80 and 443 are free. Nothing else on the machine will fight Valet's nginx. ✅
- The Playwright E2E suite already talks to **Mailpit's** API (`tests/e2e/helpers/mailpit.js`) and sets `ignoreHTTPSErrors: true`. Mailpit is a drop-in. ✅

---

## 1. Context (unchanged from v1, with corrections)

- MacBook Pro M4 Pro, 24 GB, **macOS 27.0**. Docker Desktop is installed and stays for `automator-platform` (Laravel, its own compose stack on 8000–8081, Postgres 5432, Redis 6379). WordPress dev moves off Docker and off MAMP.
- Primary workload: Uncanny Automator (free + Pro), WPUnit/Codeception via wp-browser, Playwright E2E. Plugin declares `Requires PHP: 7.4`; CI already runs the 7.4 matrix in Buddy (`wordpress:php7.4-apache`), so local 7.4 is a convenience for `clean-automator`, not a hard requirement.
- Sites live in `~/Sites` as full WP installs (not repos). The repos are the plugins inside `wp-content/plugins/`. This matters for the "share with the team" idea (section 8).

## 2. Goals (re-prioritised)

1. No Docker for WP. Native Homebrew only.
2. Laravel Valet: nginx + dnsmasq + `.test`, HTTPS on every site, per-site PHP via `.valetrc` + `valet isolate`.
3. Zero-regression DB move to `mysql@8.4`.
4. WP-CLI, Mailpit, phpMyAdmin, a one-file dashboard.
5. Idempotent migration scripts; pilot on `cleantest`, then batch, then `uncanny-automator` alone and last (protected site, see 6.1).
6. A clean uninstall of MAMP PRO (license not renewed) with a rollback window.

Non-goals stay as v1 (no GUI app, no Windows/Linux, no DB engine change away from MySQL).

## 3. Live inventory (source of truth — done, Phase 0 is complete)

Source: `~/Library/Application Support/appsolute/MAMP PRO/httpd-ssl.conf` (generated vhosts) + `wp-config.php` + `siteurl` from each DB. The `g_settings.plist` v1 wanted to parse is an NSKeyedArchiver blob — don't bother; the generated Apache conf is the readable inventory.

| MAMP host | Folder under `~/Sites` | PHP | Database | Current `siteurl` | Type / notes |
|---|---|---|---|---|---|
| uncanny-automator | uncanny-automator | 8.4.1 | uo_uncanny-automator | https://uncanny-automator:8890/ | **Primary dev site.** Codeception `test_` tables in same DB. `advanced-cache.php` drop-in present. |
| automator-plugin-platform | **uncanny_automator_plugin_platform** | 8.4.1 | uo_automator-plugin-platform | https://automator-plugin-platform:8890/ | name ≠ folder → `valet link`. `advanced-cache.php` present. |
| automatorplugin | automatorplugin | 8.4.1 | wp_automatorplugin | https://automatorplugin:8890 | `advanced-cache.php` present; stray `%TEST_SITE_WP_DOMAIN%` options rows. |
| automator-app-dev | automator-app-dev | 8.4.1 | wp_automator-app-dev | https://automator-app-dev:8890 | WP |
| automator-docs | automator-docs | **7.4.33** | wp_automator-docs | https://automator-docs:8890 | WP, 7.4 |
| elearning-docs | elearning-docs | **7.4.33** | wp_elearning-docs | https://elearning-docs:8890 | WP, 7.4 |
| clean-automator | clean-automator | **7.4.33** | wp_cleanautomator_db | https://clean-automator:8890 | WP, 7.4 compat testing |
| cleantest | cleantest | 8.4.1 | wp_cleantest_db | https://cleantest:8890 | WP |
| elearning-plugins | elearning-plugins | 8.4.1 | wp_elearningplugins_db | https://elearning-plugins:8890 | WP |
| hrpartner | hrpartner | 8.4.1 | wp_hrpartner_db | https://hrpartner:8890 | WP |
| lindris | lindris | 8.4.1 | wp_lindris_db | https://lindris:8890/ | WP |
| tincanny | tincanny | 8.4.1 | tinstaging2 | https://tincanny:8890/ | WP (staging copy) |
| tincanny-core | tincanny-core | 8.4.1 | tincanny-core | https://tincanny-core:8890 | WP |
| uncanny-ceu | uncanny-ceu | 8.4.1 | uo_uncanny-ceu | https://uncanny-ceu:8890/ | WP |
| uncanny-codes | uncanny-codes | 8.4.1 | uo_uncanny-codes | https://uncanny-codes:8890/ | WP |
| uncanny-groups | uncanny-groups | 8.4.1 | uo_uncanny-groups | https://uncanny-groups:8890/ | WP |
| uncanny-toolkit | uncanny-toolkit | 8.4.1 | uo_uncanny-toolkit | https://uncanny-toolkit:8890/ | WP |
| uncannyowl | uncannyowl | 8.4.1 | dbusfoxzdgjkec | https://uncannyowl:8890 | WP prod copy; a second `*_options` table still says `http://uncannyowl.com` (different prefix, leave it). |
| unito | unito | 8.4.1 | wp_unito_db | https://unito:8890 | WP; second options table says `http://localhost`. |
| **wpmu** | wpmu | 8.4.1 | wp_wpmu_db | https://wpmu:8890 + `/automator` `/toolstaging` `/test` `/groups` | **Subdirectory multisite.** `DB_HOST = localhost` (socket). `object-cache.php` drop-in. Custom `.htaccess` rules. |
| automator-api | automator-api | 8.4.1 | — | — | Laravel app (Procfile/Dockerfile). Check its `.env` `APP_URL`. |
| uo-ap-edd-licensing | uo-ap-edd-licensing | 8.4.1 | — | — | PHP app with `public/` (Caddyfile, `.htaccess` rewrites to `public/`). Valet serves `public/` automatically. |
| basecamp | basecamp | 8.4.1 | — | — | Static export (509 folders). Any driver serves it. |
| learndash-docs | **learndsah-docs** | 8.4.1 | — | — | Static crawl + `index.php`. name ≠ folder → `valet link`. |
| localhost | localhost | 8.4.1 | — | http://localhost:8888 | MAMP default docroot. Drop. |

**Explicitly excluded (decided 2026-09-22): `~/Sites/automator-platform`.** Laravel, runs only under its own Docker Compose stack (api 8000–8002, proxy 8080, adminer 8081, Postgres 5432, Redis 6379). It was never a MAMP vhost; the only MAMP trace is a stale `/etc/hosts` line. Nothing to migrate. Because `valet park ~/Sites` would still expose it as `automator-platform.test` (Laravel booting under Homebrew PHP with a `.env` that points at Docker hostnames = confusing error page), the dashboard's exclude list carries it and nobody should use that hostname; if that is too loose, the alternative is explicit `valet link` per host instead of `park` (see 9.6).

Orphans to decide on: `~/Sites/blueprint` (wp-config + `wp_blueprint_db`, `siteurl https://blueprint:8890`, no MAMP host any more). DBs with no site: `linkatjf`, `uo_parity_current`, `uo_parity_legacy` (test fixtures). Folders that are not sites: `notifications`, `uncannyowl.com`, `staging-uncannyowl` (wp-content backups), `wordpress.6.9.4` (clean core), `mcp-client`, `Uncanny-Automator-Stripe-App`, `demo.new`, `investigate`, `ziarizvi.com` (static HTML — Valet serves it fine if you ever want it).

MySQL facts ✅: 8.0.40 on `127.0.0.1:8889`, `root`/`root`, 29 schemas, 177 MB datadir. Users to recreate: `root`, `mamp`, `wp_root_user`, `wp_wpmu_user`, `uo_uncanny-automator` (all `mysql_native_password`). Collations: 2802 tables `utf8mb4_unicode_520_ci`, 369 `utf8mb4_unicode_ci`, 365 `utf8mb3_general_ci`, **16 `utf8mb4_0900_ai_ci`**, 28 `latin1_swedish_ci`.

PHP ini facts (MAMP, per version) ✅: opcache on; Xdebug loaded nowhere; extensions beyond stock = `pgsql`, `pdo_pgsql`, `imap` (7.4/8.1–8.3), `redis` + `mongodb` on 8.4 (loaded from **Homebrew's** `/opt/homebrew/lib/php/pecl/20240924/` — MAMP was already borrowing Homebrew builds). `memory_limit=128M`, `max_execution_time=30`, `upload_max_filesize=post_max_size=1G`, `sendmail_path` → MailHog's `mhsendmail`.

Already installed via Homebrew ✅: `php` (8.5.10), `php@8.3`, `php@8.4`, `composer` 2.10, `wp-cli` 2.12, `node`, `redis` (cask, 8.8 — **not** `brew services`-manageable), `cloudflared`, `libpq`. **Not** installed: valet, herd, nginx, dnsmasq, mailpit, memcached, any mysql. `~/.composer/vendor/bin` is **not** on PATH yet.

Broken already ✅: `/opt/homebrew/etc/php/8.4/php.ini` lines 1–3 are stray `extension="mongodb.so"` ×2 + `extension="redis.so"` from an old `pecl install`; `mongodb.so` is gone, so every `php@8.4` start prints warnings. Fix in Phase 1.

## 4. Target architecture (concrete)

### 4.1 Base layer
```bash
# PHP — only what is used. 7.4 comes from the shivammathur tap (not in homebrew-core).
brew install php@8.4                       # already present
brew tap shivammathur/php && brew trust shivammathur/php && brew install shivammathur/php/php@7.4   # tap has arm64_golden_gate (macOS 27) bottles; `brew trust` is required since Homebrew 6

# Valet
composer global require laravel/valet
echo 'export PATH="$HOME/.composer/vendor/bin:$PATH"' >> ~/.zshrc      # bin-dir confirmed as ~/.composer/vendor/bin
valet install                              # nginx + dnsmasq (brew), /etc/resolver/test, sudoers entries
valet park ~/Sites

# Data + mail
brew install mysql@8.4 mailpit
brew link --force mysql@8.4                # keg-only; wp db export/import need mysql/mysqldump on PATH
brew services start mysql@8.4
brew services start mailpit
```
Decision: **DB engine = Homebrew `mysql@8.4`**, not DBngin, not MariaDB (see gotcha 2). Keep default port 3306 and default socket `/tmp/mysql.sock`.

### 4.2 Per-PHP-version config = one drop-in, not edited php.ini
Put the same file in `/opt/homebrew/etc/php/8.4/conf.d/zz-uo-dev.ini` and `/opt/homebrew/etc/php/7.4/conf.d/zz-uo-dev.ini` (the tap's 7.4 uses the same layout). Survives `brew upgrade` cleanly, diffable, repo-able.
```ini
; zz-uo-dev.ini — dev parity with MAMP + no stale-file surprises
memory_limit = 512M
max_execution_time = 300
upload_max_filesize = 1G
post_max_size = 1G
opcache.enable = 1
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0          ; every request re-checks mtime: no 2-second stale window on fast-changing repos
sendmail_path = "/opt/homebrew/bin/mailpit sendmail"
; do NOT set curl.cainfo: Homebrew curl falls back to Apple SecTrust (keychain) when no CA file is forced — see 9.3
```
Extensions for 8.4: `pecl install redis` (and `mongodb`, `pgsql` only if a site actually needs them — nothing in `~/Sites` WP configs references mongodb). Do the same under the 7.4 binary only if `clean-automator` needs redis (it does not today).

### 4.3 Per-site config = `.valetrc`
```ini
# ~/Sites/<site>/.valetrc
php=php@7.4
```
`valet isolate` (no argument) inside the folder reads it; `valet php` / `valet composer` proxy to that version. Only the three 7.4 sites need the file; everything else rides the global default (`valet use php@8.4`). No custom reader, no schema.

### 4.4 Multisite subdirectory driver (`wpmu` only)
Valet core's `WordPressValetDriver` only forces a trailing slash on `/wp-admin`; it has no `/<subsite>/wp-admin/` or `/<subsite>/wp-content/` rewrite. Drop this in as `~/Sites/wpmu/LocalValetDriver.php` (Valet auto-loads a `LocalValetDriver.php` from the site root):
```php
<?php
/**
 * Valet driver for a WordPress subdirectory multisite.
 * Mirrors the two .htaccess rules WP core generates for subdirectory installs.
 */
class LocalValetDriver extends WordPressValetDriver {

	/**
	 * Strip the sub-site prefix from core paths: /automator/wp-admin/x -> /wp-admin/x
	 */
	private function strip_subsite_prefix( string $uri ): string {
		$uri = preg_replace( '#^/[_0-9a-zA-Z-]+(/wp-(content|admin|includes)/.*)$#', '$1', $uri );
		return preg_replace( '#^/[_0-9a-zA-Z-]+(/.*\.php)$#', '$1', $uri );
	}

	public function isStaticFile( $sitePath, $siteName, $uri ) {
		return parent::isStaticFile( $sitePath, $siteName, $this->strip_subsite_prefix( $uri ) );
	}

	public function frontControllerPath( $sitePath, $siteName, $uri ) {
		return parent::frontControllerPath( $sitePath, $siteName, $this->strip_subsite_prefix( $uri ) );
	}
}
```
⚠️ Verify in the pilot that `/automator/wp-admin/` and `/automator/wp-login.php` render and that `REQUEST_URI` still carries the prefix (WP uses it to pick the blog). Wildcard subdomains are already covered by Valet (`server_name site.test www.site.test *.site.test`, cert SAN `*.site.test`) ✅ — irrelevant for this subdirectory network but good to know.

### 4.5 SSL
`valet secure <site>`: per-site cert signed by Valet's own CA; Valet runs `security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain`. Chrome, Safari, `/usr/bin/curl` and (via SecTrust fallback) Homebrew PHP's curl trust it. Two things do **not**, and both matter for WordPress:
- **WordPress's own HTTP API** pins `CURLOPT_CAINFO` to `wp-includes/certificates/ca-bundle.crt`, bypassing the keychain. Cron and Site Health loopback are exempt (they pass `https_local_ssl_verify` = false), so wp-admin will not complain, but any plugin code doing `wp_remote_get( home_url( '/wp-json/...' ) )` with default `sslverify` fails with cURL error 60. Fix: a local-only mu-plugin (`wp-content/mu-plugins/uo-local-ssl.php`) with `add_filter( 'https_ssl_verify', '__return_false' );`, or return a bundle path that includes the Valet CA. Detail in 9.3.
- **Node** (`fetch`, `https`) ignores the keychain. Set `NODE_EXTRA_CA_CERTS="$HOME/.config/valet/CA/LaravelValetCASelfSigned.pem"` in `~/.zshrc`. Playwright already sets `ignoreHTTPSErrors: true`.
After the first `valet secure`, run `brew postinstall ca-certificates` once: it merges System-keychain-trusted CAs into Homebrew's `cert.pem`, which is what `openssl.cafile` points at for PHP's non-curl streams.

### 4.6 phpMyAdmin
As v1 (unzip into `~/Sites/phpmyadmin`, set `blowfish_secret`, host `127.0.0.1`), or skip it if you already use TablePlus/Sequel Ace. MAMP PRO also bundles phpMyAdmin 5 at `/Library/Application Support/appsolute/MAMP PRO/phpMyAdmin5` — don't reuse it, it dies with MAMP.

### 4.7 Dashboard
As v1: `~/Sites/dashboard/index.php` scanning `~/Sites` (skip folders without `wp-config.php`, `public/`, or `index.*`; hard exclude list = `automator-platform`, `mcp-client`, `Uncanny-Automator-Stripe-App`, `wordpress.6.9.4`) plus links to `https://phpmyadmin.test` and `http://localhost:8025`. Also list `valet links` output for the two linked names.

### 4.8 Webhook / tunnel testing (replaces the "port override" idea)
No per-site port. Use `valet share` — Valet 4 supports ngrok, expose and **cloudflared** as share tools, and `cloudflared` is already installed. ⚠️ Confirm `valet share-tool cloudflared` on the installed Valet version.

## 5. Migration mechanics

### 5.1 URL mapping
| Old | New |
|---|---|
| `https://<host>:8890` | `https://<host>.test` |
| `http://<host>:8888` | `https://<host>.test` |
| `wpmu:8890` (bare, in `wp_blogs`, `wp_site`, `DOMAIN_CURRENT_SITE`) | `wpmu.test` |
| Codeception `https://uncanny-automator:7890/` | `https://uncanny-automator.test/` — **7890 is MAMP PRO's internal nginx**, not the site; the URL was never really hitting WordPress. |

Run three passes per site so nothing is left behind, all with `--precise --skip-columns=guid --report-changed-only`:
```bash
wp search-replace "https://${HOST}:8890" "https://${HOST}.test" --all-tables
wp search-replace "http://${HOST}:8888"  "https://${HOST}.test" --all-tables
wp search-replace "${HOST}:8890"         "${HOST}.test"         --all-tables   # catches bare-domain rows (multisite, serialized)
```
For `wpmu` add `--network` and run WP-CLI with `--url=https://wpmu.test`, then `wp config set DOMAIN_CURRENT_SITE wpmu.test`.

### 5.2 DB host
Every wp-config says `localhost:8889` or `127.0.0.1:8889` (`wpmu` says `localhost`). Two ways:
- **Recommended:** `wp config set DB_HOST 127.0.0.1` per site inside the migration loop (idempotent, explicit, standard port). Also update `tests/.env.saad` (`TEST_SITE_DB_HOST`, `TEST_DB_HOST`, the DSN).
- Zero-touch fallback: set `port = 8889` in `/opt/homebrew/etc/my.cnf`. Works (PHP treats `localhost:*` as the socket anyway), but leaves a non-standard port for the team story.

### 5.3 DB move (dump/import, not datadir copy)
```bash
# From MAMP (still running), all app schemas:
MAMP_MYSQL=/Applications/MAMP/Library/bin/mysql80/bin
$MAMP_MYSQL/mysqldump -uroot -proot -h127.0.0.1 -P8889 --single-transaction --routines --triggers \
  --default-character-set=utf8mb4 --databases <list of 29 schemas minus mysql/sys/information_schema/performance_schema> \
  > ~/mamp-dump-$(date +%F).sql
# Users + grants (mysqlpump is gone in 8.4; SHOW GRANTS is the portable way):
$MAMP_MYSQL/mysql -uroot -proot -h127.0.0.1 -P8889 -N -e "SELECT CONCAT('SHOW CREATE USER \'',user,'\'@\'',host,'\';SHOW GRANTS FOR \'',user,'\'@\'',host,'\';') FROM mysql.user WHERE user NOT LIKE 'mysql.%'" | $MAMP_MYSQL/mysql -uroot -proot -h127.0.0.1 -P8889 -N > ~/mamp-users.sql
# Into Homebrew mysql@8.4 (root has no password by default; set one or keep it empty — wp-configs use app users anyway):
mysql -uroot < ~/mamp-dump-$(date +%F).sql
```
Verification per schema: table count and `CHECKSUM TABLE` on the options + posts tables before/after. ⚠️ `SHOW CREATE USER` emits `mysql_native_password` hashes; MySQL 8.4 ships that plugin **disabled by default** — either start mysqld with `mysql_native_password=ON` in `my.cnf`, or recreate the 5 users with `caching_sha2_password` (PHP ≥ 7.4 mysqlnd supports it, so 7.4 sites are fine). Recreating is cleaner.

### 5.4 Per-site script (`bin/migrate-site <host> [folder]`) — idempotent order
1. `valet link <host>` if folder ≠ host (skip if `valet links` already lists it).
2. Write `.valetrc` if PHP ≠ default; `valet isolate` (no-op when already isolated).
3. `valet secure <host>` (no-op when already secured).
4. `wp config set DB_HOST 127.0.0.1` (no-op when equal).
5. The three `wp search-replace` passes (each reports 0 changes on re-run).
6. `wpmu` only: `--network`, `DOMAIN_CURRENT_SITE`, drop in `LocalValetDriver.php`.
7. Smoke: `curl -skI https://<host>.test/ | head -1` (expect 200/301), `curl -sk https://<host>.test/wp-login.php | grep -c loginform`, `wp option get siteurl`, `wp eval 'var_dump( is_wp_error( wp_remote_get( home_url( "/wp-json/" ) ) ) );'` → `false` proves same-site HTTPS works with the mu-plugin from 4.5 in place; `curl -6 -skI https://<host>.test/` → 200 proves the IPv6 listen fix.
8. Log to `~/migration-log/<host>.txt`; never abort the batch on one failure.
9. Protected sites (`PROTECTED=(uncanny-automator)`) are skipped by `migrate-all` and require an explicit flag on `migrate-site` (see 6.1).

## 6. Phases (re-cut)

**Phase 0 — Inventory: DONE** (section 3). Just re-export it to CSV from this doc if the script wants a file.

**Phase 1 — Base stack, with MAMP still running** (nothing conflicts except 1025/8025 for Mailpit):
- Clean `~/.profile` (remove the whole MAMP PATH/alias block) and `~/.zshrc` (`/Applications/MAMP/bin/php/php8.3.14/bin` PATH entry). Open a new shell; confirm `which php mysql wp` are all `/opt/homebrew/...`.
- Fix `/opt/homebrew/etc/php/8.4/php.ini` lines 1–3; `pecl install redis` for 8.4; `php -m` prints no warnings.
- Install per 4.1. Start `mysql@8.4` only after MAMP's MySQL is stopped **or** leave MAMP's on 8889 and Homebrew's on 3306 — they coexist, which is exactly what you want for the dump/import.
- `valet park ~/Sites`; confirm `http://uncanny-automator.test` answers over plain HTTP before any `secure`. Then `curl -6 -sI http://uncanny-automator.test` — if that fails while `-4` works, apply the IPv6 workaround in 9.7 now, not after Safari starts 404ing.
- Start Mailpit **after** stopping MAMP's MailHog (both want 1025/8025).

**Phase 2 — Tooling**: `bin/migrate-site`, `bin/migrate-all`, `zz-uo-dev.ini` drop-ins, `LocalValetDriver.php`, dashboard, `bin/php-xdebug on|off` (optional, Phase 5).

**Phase 3 — Pilot #1: `cleantest`** (8.4, single-site, disposable — decided). Then **Pilot #2: `wpmu`** (the only multisite; it is the risky one, do not discover its problems in the batch). Then **Pilot #3: `clean-automator`** (proves the 7.4 isolation path and `valet php` for Codeception).

**Phase 4 — Batch** the remaining hosts **except `uncanny-automator`** (20 hosts: 24 real hosts minus the 3 pilots minus the protected site). `bin/migrate-all` must skip protected sites unless called with `--include-protected`.

**Phase 4b — `uncanny-automator`, alone, last.** Gate: every other site green on the DoD list, and MAMP still fully runnable. Steps, in order:
1. Fresh `mysqldump` of `uo_uncanny-automator` (all tables, including the Codeception `test_*` tables) to `~/migration-log/uo_uncanny-automator-pre.sql`, plus `tar` of `~/Sites/uncanny-automator/wp-config.php`, `wp-content/mu-plugins`, `wp-content/uploads` (code lives in git, uploads and config do not).
2. Import into `mysql@8.4` — do **not** move MAMP's copy; both DBs exist side by side until sign-off.
3. `bin/migrate-site uncanny-automator` (link not needed, 8.4 default, secure, `DB_HOST`, search-replace).
4. Verify: wp-admin login, recipe editor loads, a recipe fires end-to-end, `codecept run wpunit` green with the updated `tests/.env.saad`, Playwright smoke green with `WP_BASE_URL=https://uncanny-automator.test` and `MAILPIT_URL=http://localhost:8025`.
5. Rollback if anything is off: `wp search-replace` reversed is *not* the rollback — the rollback is "start MAMP, the old DB and vhost are untouched". Nothing in Phase 4b deletes or renames anything on the MAMP side.

### 6.1 Protected-site rules (`uncanny-automator`)
- Never in a batch. Never first. Never while MAMP is uninstalled.
- Backup immediately before, verified by restoring the dump into a scratch schema (`uo_uncanny-automator_restoretest`) and counting tables.
- The migration script refuses to run on a protected site without `--i-have-a-backup` (or equivalent explicit flag) so a careless `migrate-all` cannot touch it.
- A full working week on Valet before `/Applications/MAMP` is deleted.

**Phase 5 — Optional**: Xdebug per version (`pecl install xdebug`, `xdebug.mode=debug`, `xdebug.start_with_request=trigger`, browser toggle), Redis object cache via `wp redis enable` where wanted (Redis server: reuse the Docker one on 6379 while `automator-platform` is up, or run the Homebrew cask on 6380 — do not run both on 6379).

**Phase 6 — Decommission MAMP PRO**: stop servers in the app → `sudo launchctl unload /Library/LaunchDaemons/de.appsolute.mampprohelper.plist` → delete the 60-line `# MAMP PRO - Do NOT remove this entry!` block from `/etc/hosts` (bare names never collided with `.test`, but stale) → keep `/Applications/MAMP` and `~/mamp-dump-*.sql` for two weeks as rollback → then trash `/Applications/MAMP`, `/Applications/MAMP PRO.app`, `/Library/Application Support/appsolute`, `~/Library/Application Support/appsolute`.

## 7. Definition of done (updated)

- [ ] 24 hosts (everything in section 3 except `localhost`; `automator-platform` is out of scope) answer at `https://<host>.test` with a cert Chrome/Safari accept silently.
- [ ] `valet isolated` lists exactly `automator-docs`, `elearning-docs`, `clean-automator` on `php@7.4` (or they were intentionally bumped); everything else on `php@8.4`. `curl -sI https://<host>.test | grep -i x-powered-by` matches per site.
- [ ] Per-schema table counts and `CHECKSUM TABLE` on `*_options`/`*_posts` match MAMP.
- [ ] `wp option get siteurl` = `https://<host>.test` everywhere; `wp site list --url=https://wpmu.test` shows 5 blogs on `wpmu.test`.
- [ ] On `uncanny-automator.test`: Site Health shows no loopback/REST error **and** `wp_remote_get( home_url( '/wp-json/' ) )` with default `sslverify` returns no `WP_Error` (the second is the real test; the first passes even without CA trust).
- [ ] `curl -6 -skI https://<host>.test/` returns 200 on every site (Valet 4.12.0 IPv6 workaround applied or a release containing the fix installed).
- [ ] `wp eval 'wp_mail("a@b.test","t","b");'` lands in Mailpit from one 8.4 site and one 7.4 site.
- [ ] `codecept run wpunit` green on `uncanny-automator` with the updated `tests/.env.saad`; Playwright smoke green against `https://uncanny-automator.test`.
- [ ] `https://phpmyadmin.test` (or TablePlus) browses all schemas; `https://dashboard.test` lists all sites.
- [ ] `which php mysql wp` → Homebrew; `php -v` prints no extension warnings; `~/.profile` has no MAMP lines.
- [ ] `bin/migrate-site <host>` re-run is a no-op (0 replacements, "already secured", "already isolated").
- [ ] `uncanny-automator` migrated last, alone, from a verified fresh backup; MAMP's copy of `uo_uncanny-automator` and its vhost untouched until sign-off.
- [ ] MAMP PRO helper daemon unloaded; MAMP kept as rollback for at least one working week after `uncanny-automator` is on Valet; delete date written here: ________.

## 8. Team / "no-brainer" angle — honest take

What is actually shareable is a **tooling repo**, not the sites: `local-devstack/` with `Brewfile`, `bootstrap.sh` (idempotent: brew bundle → composer global valet → `valet install` → `valet park ~/Sites` → services), `php/zz-uo-dev.ini`, `drivers/LocalValetDriver-multisite-subdir.php`, `bin/site-new`, `bin/site-import` (takes a LocalWP export zip: unzip → create DB → import SQL → `wp search-replace <local-url> https://<name>.test` → `valet secure`), `bin/migrate-site`, `dashboard/`. Each site's `.valetrc` is a one-liner anyone can add.

Be candid in the pitch: the speed win vs Docker bind mounts is real; vs LocalWP (also native on macOS) the win is scriptability, one shared MySQL, `.test` HTTPS without per-site toggling, and no Electron app — not raw speed. LocalWP users lose the GUI and one-click site cloning; `bin/site-new` + `wp db export` covers 90% of that.

**Alternative worth one honest look before building: Laravel Herd (free tier).** Verified 2026-09-22 against herd.laravel.com and the herd-community tracker:
- **Free:** bundled PHP 7.4–8.5 (no Homebrew PHP to maintain, no tap for 7.4), nginx, dnsmasq `*.test`, Node, `herd secure` (HTTPS), `herd isolate` (per-site PHP; reads `.valetrc`, its own file is `herd.yml`), WordPress/Bedrock drivers, Xdebug extensions shipped (manual php.ini toggle), a menu-bar app, and it auto-imports existing Valet sites/certs. No commercial-use restriction found anywhere (EULA is silent rather than explicit).
- **Pro, US$99/yr:** Dumps, Mail, Log viewer, Services (MySQL/Redis/etc.), Xdebug auto-detection. None of that is needed: this plan already runs `mysql@8.4` + `mailpit` from Homebrew.
- **Point in Herd's favour:** its PHP builds hit the macOS 27 fork crash (herd-community #1729) and Herd shipped a fix in 1.30.1 within weeks. Homebrew and the shivammathur tap have explicitly declined to ship any workaround, and php-src #11818 is still open, so on Valet you own that fallback yourself if it ever surfaces (it did not in today's probe).
- **Point against:** Herd is a closed app; the "make it a Mac app later" idea already exists as Herd, so the honest question is whether you want to build one at all. Herd's CLI is `herd` not `valet`, so the `bin/` scripts would target it instead. Pick **one** of Valet or Herd; both want 80/443 and dnsmasq.

## 9. Gotchas & runbook notes

**9.1 The ObjC fork crash (today's fix) does not follow you — verified with a positive control.** Cause chain (from the other session, confirmed by herd-community #1729 and php-src #11818, still open upstream): a PHP process that forks workers without `exec()` and then resolves an **IPv4-only** hostname in the child runs Objective-C `+initialize` inside Network.framework → libobjc aborts the child → Apache "incomplete headers" → 500 on wp-admin/wp-login. Probe on this machine (2026-09-22): scratch php-fpm pool on 127.0.0.1:9977, `curl_exec()` HEAD to `https://github.com/` (no AAAA record) from 2 static workers, 6 requests each — **php@8.4 8.4.25: 6/6 OK, php 8.5.10: 6/6 OK**, empty fpm error log, no new `php-fpm*.ips`. Same script against MAMP's `php-cgi` 7.4.33 with `PHP_FCGI_CHILDREN=4` and the env var deliberately unset: **0/6, every worker died**, two new `php-cgi-2026-09-22-*.ips` crash reports. The test discriminates; Homebrew php-fpm is clean today.
If it ever appears on the new stack, know these three facts: (a) `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` only works in the **php-fpm master's** environment; `env[...]` in the pool config is too late. (b) Editing `EnvironmentVariables` in `/Library/LaunchDaemons/homebrew.mxcl.php@8.4.plist` is **wiped by every `valet restart`**, because `brew services` re-copies the formula plist on each start. (c) Durable options: `sudo brew services start php@8.4 --file=/path/to/custom.plist`, a wrapper script in place of the php-fpm binary (what the MAMP fix does), or an `opcache.preload` script that opens one TCP connection in the master before it forks so the ObjC classes initialise in the parent. `fix-objc-fork-crash.sh` in `/Applications/MAMP/fcgi-bin/` dies with MAMP.

**9.2 CLI PHP after cleanup will be 8.5.10**, because the `php` formula is linked at `/opt/homebrew/bin/php`. Either `brew unlink php && brew link --force php@8.4` (recommended: matches 21/24 sites and WP-CLI's tested range) or keep 8.5 and use `valet php` / `valet composer` inside each site for version-correct runs. WP-CLI honours `WP_CLI_PHP=/opt/homebrew/opt/php@8.4/bin/php` if you want to pin it independently.

**9.3 HTTPS trust, layer by layer.** Valet writes its CA into the System keychain and nothing else (`Site.php` never touches `cert.pem`, `openssl.cafile` or `curl.cainfo`). What that covers today:
- Browsers, `/usr/bin/curl`: trusted. ✅
- Homebrew PHP `curl_exec()` with **no** `CURLOPT_CAINFO`: Homebrew `curl` 8.22 is built `--with-apple-sectrust --with-ca-fallback` and no bundled CA file, so verification falls back to the keychain. Trusted (inferred from build flags; confirm in the pilot with the `wp eval` in 5.4).
- PHP OpenSSL streams (`file_get_contents('https://...')`): use `openssl.cafile=/opt/homebrew/etc/openssl@3/cert.pem`; `brew postinstall ca-certificates` merges keychain-trusted CAs into that file. Run it once after the first `valet secure`.
- **WordPress HTTP API**: forces `CURLOPT_CAINFO` to its own `ca-bundle.crt`, so keychain trust is bypassed. Cron and Site Health loopback are exempt via `https_local_ssl_verify` (default false) and work out of the box. Anything else calling the site over HTTPS needs the mu-plugin from 4.5 (`https_ssl_verify` → false, local only).
- Node: `NODE_EXTRA_CA_CERTS=~/.config/valet/CA/LaravelValetCASelfSigned.pem`, or `NODE_USE_SYSTEM_CA=1` on Node ≥ 22.19 / 24.6. Playwright: already `ignoreHTTPSErrors: true`; Chromium on macOS also reads keychain trust, so it would work either way.

**9.4 PHP 7.4 on macOS 27 — resolved.** Not in homebrew-core (`php@8.1` is already deprecated, `php@8.2` deprecates 2026-12-31, `php@8.4` is safe until 2028). The `shivammathur/php` tap ships `php@7.4` 7.4.33 with backported security patches and **`arm64_golden_gate` bottles exist**, so no source build. Homebrew 6+ needs `brew trust shivammathur/php` after tapping. Keeping 7.4 for the three sites is therefore cheap; bumping the two docs sites to 8.4 is a taste decision, not a necessity.

**9.5 External facts, confirmed 2026-09-22** (research agent, upstream sources):
- Valet `.valetrc` = `key=value` lines, `php=php@7.4`; `valet isolate`/`valet use` with no argument read it, then fall back to `composer.json` `platform.php`. Current release v4.12.0 (2026-03-10). — laravel.com/docs/12.x/valet, `cli/app.php`, `cli/Valet/Site.php`
- Valet IPv6 bug: `DnsMasq.php` writes `address=/.test/::1` but v4.12.0 `secure.valet.conf` only has `listen 127.0.0.1:*`; `master` adds `listen [::1]:*`, unreleased. — laravel/valet #1558
- Homebrew 6.0.0 (2026-06-11) made macOS 27 "Golden Gate" tier-1; php, php@8.2–8.5, nginx, dnsmasq, mysql@8.4, mailpit all have `arm64_golden_gate` bottles. — brew.sh, formulae.brew.sh
- shivammathur/homebrew-php: php@7.4/8.0/8.1/8.2 with `arm64_golden_gate` + `arm64_tahoe` bottles; Intel unsupported. — tap README + `Formula/php@7.4.rb`
- Fork crash: php-src #11818 open; homebrew-core #137431 closed "not planned" (no env var in the service block); shivammathur mirrors Homebrew's stance; Herd fixed its builds in 1.30.1. `brew services` re-copies the plist on every start. — php-src, homebrew-core, herd-community #1729, `Library/Homebrew/services/cli.rb`
- Herd free/Pro split and US$99/yr price as summarised in section 8. — herd.laravel.com, herd docs, EULA
- Mailpit: formula `mailpit` 1.31.2; `sendmail_path = "/opt/homebrew/bin/mailpit sendmail"` (append `-S 127.0.0.1:1025` only for a non-default port). — mailpit.axllent.org/docs/install/sendmail
- MariaDB ≥ 11.4.5 aliases `utf8mb4_0900_*` to UCA-14 collations (MDEV-20912; `_bin` variant mis-aliased until 11.4.6). Older → `ERROR 1273`. Not needed since the target is `mysql@8.4`. — mariadb.com release notes
- Valet CA vs PHP/WP/Node: as laid out in 9.3. — laravel/valet #460, Homebrew `curl.rb` + `ca-certificates.rb`, WordPress `class-wp-http.php` / `cron.php` / `class-wp-site-health.php`, nodejs.org docs
- Not verifiable: an explicit "free for commercial use" sentence for Herd (only absence of restriction); empirical proof that PHP-curl-via-SecTrust trusts the Valet CA (pilot will show).

**9.6 Smaller ones**
- Homebrew `redis` is a **cask** (`/opt/homebrew/Caskroom/redis/8.8.0`), so `brew services start redis` will not work; Docker already owns 6379 for `automator-platform`. Decide one Redis, one port.
- `advanced-cache.php` drop-ins on `uncanny-automator`, `automatorplugin`, `uncanny_automator_plugin_platform` are empty stubs from staging exports; harmless, but delete if any page-cache plugin is not installed.
- `.htaccess` is ignored by nginx. Only two sites have non-core rules: `uo-ap-edd-licensing` (rewrite to `public/` — Valet does that natively) and `wpmu` (multisite rules — replaced by the driver above). Nothing else to port.
- `uncannyowl` and `unito` each carry a second `*_options` table with a foreign `siteurl`; `--all-tables` will rewrite them too, which is fine and expected.
- `wp_automatorplugin` has literal `http://%TEST_SITE_WP_DOMAIN%` in an options table (leftover wp-browser fixture). Leave it.
- Mailpit's API is `/api/v1/*`; MailHog's was `/api/v2/*`. The E2E helpers are already on v1 ✅ — only `MAILPIT_URL` (currently `http://localhost:10000`) needs to become `http://localhost:8025`.
- Valet runs nginx, php-fpm and dnsmasq as root via `sudo brew services`; `valet trust` writes sudoers entries so day-to-day commands stop prompting. Teammates need admin on their Macs.
- `valet park` will also expose non-sites as `*.test` (`automator-platform.test`, `mcp-client.test`, `uncanny_automator_plugin_platform.test`, `wordpress.6.9.4.test`). Harmless but noisy, and `automator-platform.test` in particular must not be used (Docker-only app). If it bothers you, park nothing and have `bootstrap.sh` `valet link` the 24 hosts explicitly from the inventory; `bin/site-new` links new sites the same way, so nothing is lost.

**9.7 Valet 4.12.0 IPv6 workaround (until the next tag).** Symptom: Safari (and anything doing Happy Eyeballs) gets nginx 404s or connection refused on `*.test` while Chrome/curl -4 work. Cause: dnsmasq returns `::1`, nginx only listens on `127.0.0.1`. Fix: in `~/.config/valet/Nginx/<site>.test` (secured sites) and in the stub `~/.composer/vendor/laravel/valet/cli/stubs/secure.valet.conf` add `listen [::1]:80;` next to `listen 127.0.0.1:80;`, `listen [::1]:443 ssl;` next to the 443 line, and `listen [::1]:60;` next to the 60 line, then `valet restart`. Re-apply after `composer global update` until a release ≥ 4.13 lands (check the changelog for "IPv6 listen"). Alternative: `composer global require laravel/valet:dev-master`, which already contains the fix, at the cost of tracking master.

## 10. Decisions

**Decided (Saad, 2026-09-22)**
- **PHP 7.4 stays.** It is a requirement: the plugin must be proven to run on 7.4 locally, not only in CI. All three 7.4 hosts keep `php=php@7.4` in `.valetrc`; `bootstrap.sh` installs `shivammathur/php/php@7.4` unconditionally. `valet php` / `valet composer` inside those sites give a 7.4 CLI for Codeception.
- **Mac app ships unsigned for now.** Signing/notarisation only if distribution beyond the team ever needs it (Apple Developer account, US$99/yr).
- **Xcode is present on every machine.** So `bootstrap.sh --app` builds the app locally from `app/` with `swift build -c release`; a locally built `.app` carries no quarantine flag, so unsigned costs nothing. No GitHub Releases binaries needed.

- **Valet, not Herd.** Section 8's Herd comparison stays for the record only.
- **MySQL on the default port 3306**, default socket. Every site gets `wp config set DB_HOST 127.0.0.1` in the migration loop; `tests/.env.saad` is updated to match (`TEST_SITE_DB_HOST=127.0.0.1`, `TEST_DB_HOST=127.0.0.1`, DSN `mysql:host=127.0.0.1;dbname=uo_uncanny-automator`).
- **Pilot on `cleantest` (today `https://cleantest:8890`).** It is disposable; break it freely.
- **`uncanny-automator` is a protected site.** It is the daily-driver dev site and is *not* to be sacrificed to the migration. Rules in 6.1.

**Still open**
1. Date to actually delete `/Applications/MAMP` (only after `uncanny-automator` has run on Valet for a full working week).

## 11. One repo for tooling **and** the Mac app (proposal, not in the migration critical path)

Yes, fold it in. The scripts are the product; the app is a skin. Layout:

```
local-devstack/
├── Brewfile                     # php@8.4, shivammathur/php/php@7.4, mysql@8.4, mailpit, wp-cli, composer
├── bootstrap.sh                 # idempotent; no Xcode needed; this is all a teammate must run
├── php/zz-uo-dev.ini            # copied into each /opt/homebrew/etc/php/<v>/conf.d/
├── drivers/LocalValetDriver-multisite-subdir.php
├── mu-plugins/uo-local-ssl.php  # https_ssl_verify → false, dropped into each site
├── dashboard/index.php          # interim dashboard.test, deleted once the app exists
├── bin/                         # THE CONTRACT. Every command supports --json.
│   ├── site-new  site-import  migrate-site  migrate-all
│   ├── php-xdebug  php-switch
│   └── stack-status             # one JSON blob: services, per-site php, ports, cpu/mem, qps, mail count
└── app/                         # SwiftUI MenuBarExtra + Swift Charts, macOS 13+, Swift Package, no storyboard
    ├── Package.swift
    └── Sources/DevStack/…       # polls `bin/stack-status --json` every 2s, renders, shells out to bin/* for actions
```

Rules that keep it sane:
- `bootstrap.sh` never depends on `app/`. A teammate on LocalWP gets value from `bin/` alone.
- The app **never** talks to brew/valet/mysql directly. It calls `bin/*` and parses JSON. When a script changes, the app does not.
- `bin/stack-status --json` is the graph's data source, cheap to compute: `brew services list`, `valet parked`/`valet links`/`valet isolated`, `ps -o %cpu,%mem -p` for `php-fpm`, `nginx`, `mysqld`, `mailpit`, `mysqladmin status` (queries/uptime → QPS), `curl -s localhost:8025/api/v1/messages | jq .total`, tail count of `~/.config/valet/Log/nginx-error.log`. Sample it, keep the last 60 points in the app, draw with Swift Charts. That is the "fancy bar graph" with zero server-side state.
- Distribution: none. Xcode is on every machine (decided), so `bootstrap.sh --app` runs `swift build -c release` and a ~20-line bundling step (Info.plist + copy binary into `DevStack.app/Contents/MacOS/`) into `/Applications`. Locally built apps are not quarantined, so unsigned is free of friction. Signing/notarisation is deferred until a prebuilt binary must be handed to someone without the repo.
- Not before Phase 4 is green. The dashboard page covers the gap.

---
*Appendix A — throwaway probe used for 9.1 (2026-09-21 with example.com, repeated 2026-09-22 with IPv4-only github.com plus a MAMP php-cgi positive control):* php-fpm started with a scratch pool config (`listen = 127.0.0.1:9977`, `pm = static`, `pm.max_children = 2`), MAMP `php-cgi -b 127.0.0.1:9978` with `PHP_FCGI_CHILDREN=4` and `OBJC_DISABLE_INITIALIZE_FORK_SAFETY` unset as the control; requests issued with MAMP's own `cgi-fcgi -bind -connect` against a script doing `curl_exec()` HEAD to the target host. All files were under the session scratchpad; nothing was installed or changed; the two `php-cgi-2026-09-22-*.ips` reports in `/Library/Logs/DiagnosticReports` are from the control run.
