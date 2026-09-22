#!/usr/bin/env bash
# Shared helpers for local-devstack bin/ scripts. Source, do not execute.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_DIR="${SITES_DIR:-$HOME/Sites}"
SITES_TSV="${SITES_TSV:-$REPO_DIR/sites.tsv}"
LOG_DIR="${LOG_DIR:-$HOME/migration-log}"
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

# php_bin php@7.4 -> /opt/homebrew/opt/php@7.4/bin/php
php_bin() { printf '%s/opt/%s/bin/php\n' "$BREW_PREFIX" "$1"; }

# wp_site <php formula> <site path> <wp args...> : WP-CLI under the site's PHP, core only (mu-plugins still load).
wp_site() {
	local php="$1" path="$2"
	shift 2
	"$(php_bin "$php")" "$BREW_PREFIX/bin/wp" --path="$path" --skip-plugins --skip-themes "$@"
}

mysql_new()     { "$BREW_PREFIX/opt/mysql@8.4/bin/mysql" -uroot "$@"; }
mysql_old()     { "$MAMP_MYSQL_BIN/mysql" "${MAMP_MYSQL_ARGS[@]}" "$@" 2> >(grep -v 'Using a password' >&2); }
mysqldump_old() { "$MAMP_MYSQL_BIN/mysqldump" "${MAMP_MYSQL_ARGS[@]}" "$@" 2> >(grep -v 'Using a password' >&2); }

# sql_quote <string> : escape for a single-quoted MySQL literal.
sql_quote() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }
