#!/usr/bin/env bash
# Shared helpers for DevStack bin/ scripts. Source, do not execute.
set -euo pipefail

# Never let a leftover MAMP PATH entry (old shells, IDE terminals) leak into brew/valet/php resolution.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | /usr/bin/grep -v '^/Applications/MAMP' | paste -sd: -)"; export PATH
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_DIR="${SITES_DIR:-$HOME/Sites}"
# sites.tsv is the committed example; sites.local.tsv (git-ignored) holds the real inventory when it exists.
if [ -z "${SITES_TSV:-}" ]; then SITES_TSV="$REPO_DIR/sites.tsv"; [ -f "$REPO_DIR/sites.local.tsv" ] && SITES_TSV="$REPO_DIR/sites.local.tsv"; fi
DATA_DIR="${DATA_DIR:-$HOME/.local/share/devstack}"   # phpMyAdmin, upgrades.json
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/DevStack}"   # command logs; migrate-site also parks its pre-migration dumps here
VALET_HOME="${VALET_HOME:-$HOME/.config/valet}"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix)}"
VALET_BIN="${VALET_BIN:-$BREW_PREFIX/bin/valet}"   # the sudoers alias written by `valet trust` matches this path only
DEFAULT_PHP="${DEFAULT_PHP:-php@8.4}"
TLD="${TLD:-test}"

# MAMP PRO's MySQL 8.0 (source of the data). Read-only use.
MAMP_MYSQL_BIN="/Applications/MAMP/Library/bin/mysql80/bin"
MAMP_MYSQL_ARGS=(-uroot -proot -h127.0.0.1 -P8889)

DRY="${DRY:-0}"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
run() { if [ "1" = "$DRY" ]; then log "DRY: $*"; else "$@"; fi; }

# valet <args> : see bootstrap.sh; goes through sudo -n when trusted so it works without a TTY.
valet() {
	if sudo -n -l "$VALET_BIN" > /dev/null 2>&1; then
		sudo -n USER="$USER" --preserve-env "$VALET_BIN" "$@"
	else
		"$VALET_BIN" "$@"
	fi
}

# wait_for_site <url> : poll until nginx+php-fpm answer with something other than 000/502/503/504 (max ~15s).
wait_for_site() {
	local i code
	for i in $(seq 1 15); do
		code="$(/usr/bin/curl -4 -s -o /dev/null -m 5 -w '%{http_code}' "$1/" || true)"
		case "$code" in 000|502|503|504) sleep 1 ;; *) return 0 ;; esac
	done
	log "warning: $1 still answering $code after 15s"
}

# site_row <host> : load one inventory row into SITE_* variables.
site_row() {
	local row
	row="$(awk -F'\t' -v h="$1" '$0 !~ /^#/ && $1 == h { print; exit }' "$SITES_TSV")"
	[ -n "$row" ] || die "unknown site '$1' (not in $SITES_TSV)"
	IFS=$'\t' read -r SITE_HOST SITE_FOLDER SITE_PHP SITE_DB SITE_PROTECTED SITE_NOTES <<<"$row"
	SITE_PATH="$SITES_DIR/$SITE_FOLDER"
	SITE_URL="https://$SITE_HOST.$TLD"
}

# all_hosts : print every host in inventory order.
all_hosts() { awk -F'\t' '$0 !~ /^#/ && NF >= 5 { print $1 }' "$SITES_TSV"; }

# is_protected <host> : true when sites.tsv marks the site protected (never removed, never batch-migrated).
is_protected() { awk -F'\t' -v h="$1" '$0 !~ /^#/ && $1 == h && $5 == "yes" { f=1 } END { exit !f }' "$SITES_TSV"; }

# site_php <path> : the PHP formula a linked site runs on (.valetrc written by site_finalize, else the default).
site_php() { local p; p="$(sed -n 's/^php=//p' "$1/.valetrc" 2> /dev/null | head -1)"; printf '%s' "${p:-$DEFAULT_PHP}"; }

# php_bin php@7.4 -> /opt/homebrew/opt/php@7.4/bin/php
php_bin() {
	# Homebrew's current `php` formula carries the newest version and is only *aliased* php@X.Y (no opt/php@X.Y link).
	if [ -x "$BREW_PREFIX/opt/$1/bin/php" ]; then printf '%s/opt/%s/bin/php\n' "$BREW_PREFIX" "$1"; return; fi
	if [ -x "$BREW_PREFIX/opt/php/bin/php" ] && [ "php@$("$BREW_PREFIX/opt/php/bin/php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" = "$1" ]; then printf '%s/opt/php/bin/php\n' "$BREW_PREFIX"; return; fi
	printf '%s/opt/%s/bin/php\n' "$BREW_PREFIX" "$1"
}

# php_broken_ext <php binary> : extensions that fail to load at startup, one per line. Usually a module API mismatch
# after Homebrew rebuilt PHP or the extension on its own; bin/php-repair fixes that.
php_broken_ext() {
	"$1" -v 2>&1 | sed -nE \
		-e 's/.*PHP Startup: ([A-Za-z0-9_]+): Unable to initialize module.*/\1/p' \
		-e 's/.*Cannot load module "([A-Za-z0-9_]+)".*/\1/p' \
		-e 's/^([A-Za-z]+) requires Zend Engine API version.*/\1/p' \
		-e "s/.*Unable to load dynamic library '([^']*\\/)?([A-Za-z0-9_]+)(\\.so)?'.*/\\2/p" \
		| tr '[:upper:]' '[:lower:]' | sort -u || true
}

# wp_site <php formula> <site path> <wp args...> : WP-CLI under the site's PHP, core only (mu-plugins still load).
# WP-CLI resets error_reporting itself, so on PHP 8.5/8.6 its own deprecations reach stdout; strip those lines
# (never data) and keep WP-CLI's exit status.
wp_site() {
	local php="$1" path="$2" out rc=0
	shift 2
	out="$("$(php_bin "$php")" -d display_errors=stderr "$BREW_PREFIX/bin/wp" --path="$path" --skip-plugins --skip-themes "$@")" || rc=$?
	[ -z "$out" ] || printf '%s\n' "$out" | /usr/bin/grep -vE '^(Deprecated|Warning|Notice|Strict Standards): |^$' || true
	return "$rc"
}

mysql_new()     { "$BREW_PREFIX/opt/mysql@8.4/bin/mysql" -uroot "$@"; }
mysql_old()     { "$MAMP_MYSQL_BIN/mysql" "${MAMP_MYSQL_ARGS[@]}" "$@" 2> >(grep -v 'Using a password' >&2); }
mysqldump_old() { "$MAMP_MYSQL_BIN/mysqldump" "${MAMP_MYSQL_ARGS[@]}" "$@" 2> >(grep -v 'Using a password' >&2); }

# sql_quote <string> : escape for a single-quoted MySQL literal.
sql_quote() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }

# db_ensure_user <db> <user> <pass> : create the MySQL user (localhost + 127.0.0.1) and grant it the schema.
# An existing user gets this password too (a retried import writes a new one to wp-config). Never root.
db_ensure_user() {
	local d u p
	[ "root" != "$2" ] || die "db_ensure_user: refusing to manage the MySQL root user"
	d="$(printf '%s' "$1" | sed 's/`/``/g')"; u="$(sql_quote "$2")"; p="$(sql_quote "$3")"
	mysql_new -e "CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$p'; CREATE USER IF NOT EXISTS '$u'@'127.0.0.1' IDENTIFIED BY '$p'; ALTER USER '$u'@'localhost' IDENTIFIED BY '$p', '$u'@'127.0.0.1' IDENTIFIED BY '$p'; GRANT ALL ON \`$d\`.* TO '$u'@'localhost', '$u'@'127.0.0.1'; FLUSH PRIVILEGES;"
}

# db_clear_transients <db> <table prefix> : delete every transient (each site's options table on multisite, plus
# sitemeta) and print how many went. Transients are caches, and some plugins store absolute paths in them that point
# at the old install after an import (Uncanny Automator's integration map, then a fatal). SQL, because WP-CLI has to
# load WordPress first.
db_clear_transients() {
	local db d pre t n=0 c
	db="$(sql_quote "$1")"; d="$(printf '%s' "$1" | sed 's/`/``/g')"; pre="$(sql_quote "$2")"
	for t in $(mysql_new -N -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND (TABLE_NAME = '${pre}options' OR TABLE_NAME REGEXP '^${pre}[0-9]+_options\$')"); do
		c="$(mysql_new -N -e "DELETE FROM \`$d\`.\`$t\` WHERE option_name LIKE '\\_transient\\_%' OR option_name LIKE '\\_site\\_transient\\_%'; SELECT ROW_COUNT();")"
		n=$(( n + c ))
	done
	if [ -n "$(mysql_new -N -e "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND TABLE_NAME='${pre}sitemeta'")" ]; then
		c="$(mysql_new -N -e "DELETE FROM \`$d\`.\`${2}sitemeta\` WHERE meta_key LIKE '\\_site\\_transient\\_%'; SELECT ROW_COUNT();")"
		n=$(( n + c ))
	fi
	printf '%s' "$n"
}

# db_name_for <site> : wp_<site> with dashes as underscores (MySQL-safe, readable in phpMyAdmin).
db_name_for() { printf 'wp_%s' "$(printf '%s' "$1" | tr '-' '_')"; }

# random_secret [len] : URL-safe random string.
random_secret() {
	# No early-closing pipe here: under pipefail, `tr | head -c` aborts the caller with SIGPIPE.
	# LC_ALL=C belongs on tr: in a UTF-8 locale it rejects random bytes ("Illegal byte sequence").
	local s; s="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
	printf '%s' "${s:0:${1:-20}}"
}
# install_mu_plugins <site path> : copy every repo mu-plugin (local SSL trust, one-time login) into the site, once.
install_mu_plugins() {
	local f dst
	mkdir -p "$1/wp-content/mu-plugins"
	for f in "$REPO_DIR"/mu-plugins/*.php; do
		dst="$1/wp-content/mu-plugins/$(basename "$f")"
		cmp -s "$f" "$dst" || cp "$f" "$dst"
	done
}

SMOKE_JSON='{"ok":false}'   # set by site_finalize

# site_finalize <host> <path> <php formula> : link, isolate, secure, mu-plugin, smoke. Sets SMOKE_JSON.
site_finalize() {
	local host="$1" path="$2" php="$3" url="https://$1.$TLD"
	if [ ! -L "$VALET_HOME/Sites/$host" ]; then ( cd "$path" && valet link "$host" >&2 ); log "link: linked"; else log "link: already"; fi
	if [ "$php" != "$DEFAULT_PHP" ]; then
		[ "$(cat "$path/.valetrc" 2> /dev/null)" = "php=$php" ] || printf 'php=%s\n' "$php" > "$path/.valetrc"
		if valet isolated 2> /dev/null | /usr/bin/grep -qE "^\| *$host(\.$TLD)? "; then log "php: already $php"; else valet isolate "$php" --site="$host" >&2; log "php: isolated $php"; fi
	else
		log "php: default"
	fi
	if [ ! -f "$VALET_HOME/Certificates/$host.$TLD.crt" ]; then valet secure "$host" >&2; log "https: secured"; else log "https: already"; fi
	[ -f "$path/wp-config.php" ] && install_mu_plugins "$path"
	wait_for_site "$url"
	local code4 code6 fatal siteurl="" loop="" fpm
	code4="$(/usr/bin/curl -4 -s -o /dev/null -m 15 -w '%{http_code}' "$url/" || true)"
	code6="$(/usr/bin/curl -6 -s -o /dev/null -m 15 -w '%{http_code}' "$url/" || true)"
	fatal="$(/usr/bin/curl -s -m 15 "$url/" | /usr/bin/grep -cE 'Fatal error|Parse error|Uncaught (Error|Exception)' || true)"
	fpm="$(/usr/bin/curl -sI -m 15 "$url/" | awk 'tolower($1)=="x-powered-by:"{print $2}' | tr -d '\r' || true)"
	if [ -f "$path/wp-config.php" ]; then
		siteurl="$(wp_site "$php" "$path" option get siteurl 2> /dev/null | tail -1 | sed 's#/$##')"
		loop="$(wp_site "$php" "$path" eval 'echo is_wp_error( wp_remote_get( home_url( "/wp-json/" ) ) ) ? "ERR" : "OK";' 2> /dev/null | tail -1)"
	fi
	local ok=true
	[ "200" = "$code4" ] && [ "200" = "$code6" ] && [ "0" = "$fatal" ] || ok=false
	if [ -f "$path/wp-config.php" ]; then [ "$siteurl" = "$url" ] && [ "OK" = "$loop" ] || ok=false; fi
	log "smoke: ipv4=$code4 ipv6=$code6 fatal=$fatal siteurl=${siteurl:--} fpm=${fpm:--} loopback=${loop:--} ok=$ok"
	SMOKE_JSON="$(jq -n --arg url "$url" --arg fpm "$fpm" --argjson ipv4 "$code4" --argjson ipv6 "$code6" --argjson fatal "$fatal" --arg siteurl "$siteurl" --arg loop "$loop" --argjson ok "$ok" \
		'{url:$url,fpm:$fpm,ipv4:$ipv4,ipv6:$ipv6,php_fatal:$fatal,siteurl:$siteurl,loopback:$loop,ok:$ok}')"
	[ "true" = "$ok" ]
}
