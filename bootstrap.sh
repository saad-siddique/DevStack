#!/usr/bin/env bash
# local-devstack bootstrap: idempotent. Run it again any time.
# Needs your sudo password once (valet install / valet trust); after that brew+valet are passwordless.
set -euo pipefail

# Never let a leftover MAMP PATH entry (old shells, IDE terminals) leak into brew/valet/php resolution.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | /usr/bin/grep -v '^/Applications/MAMP' | paste -sd: -)"; export PATH
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix)"
COMPOSER_BIN="$HOME/.composer/vendor/bin"
VALET_BIN="$BREW_PREFIX/bin/valet"   # the sudoers alias written by `valet trust` matches this path only
VALET_HOME="$HOME/.config/valet"
DEFAULT_PHP="php@8.4"
# Every PHP version Homebrew has an etc/php/<v> dir for (filled after ensure_formulae).
PHP_VERSIONS=()
php_versions_installed() { PHP_VERSIONS=(); local d; for d in "$BREW_PREFIX"/etc/php/*/; do [ -d "$d/conf.d" ] && PHP_VERSIONS+=("$(basename "$d")"); done; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*"; }

# valet <args> : Valet's wrapper re-execs itself via sudo; without a TTY that prompt cannot be answered.
# Once `valet trust` has run, go through sudo -n directly (same command the wrapper would run).
valet() {
	if sudo -n -l "$VALET_BIN" > /dev/null 2>&1; then
		sudo -n USER="$USER" --preserve-env "$VALET_BIN" "$@"
	else
		"$VALET_BIN" "$@"
	fi
}

ensure_brew() {
	command -v brew > /dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
	xcode-select -p > /dev/null 2>&1 || { echo "Xcode / Command Line Tools missing"; exit 1; }
	ok "Homebrew $(brew --version | head -1 | awk '{print $2}') at $BREW_PREFIX"
}

ensure_formulae() {
	log "Homebrew formulae"
	local t
	for t in shivammathur/php shivammathur/extensions; do
		brew tap "$t" > /dev/null
		if brew help trust > /dev/null 2>&1; then brew trust "$t" > /dev/null 2>&1 || true; fi
	done
	brew bundle install --file="$REPO_DIR/Brewfile" --no-upgrade
	# mysql@8.4 is keg-only; wp db export/import want mysql/mysqldump on PATH.
	brew link --force --overwrite mysql@8.4 > /dev/null 2>&1 || true
	ok "formulae present"
}

ensure_php_linked() {
	log "CLI PHP = $DEFAULT_PHP"
	local target
	target="$(readlink "$BREW_PREFIX/bin/php" 2> /dev/null || true)"
	case "$target" in
		*"/Cellar/$DEFAULT_PHP/"*) ok "$BREW_PREFIX/bin/php -> $DEFAULT_PHP" ;;
		*) brew unlink php > /dev/null 2>&1 || true
		   brew link --force --overwrite "$DEFAULT_PHP" > /dev/null
		   ok "linked $DEFAULT_PHP as $BREW_PREFIX/bin/php" ;;
	esac
}

ensure_php_ini() {
	log "PHP conf.d drop-ins"
	local v dst
	for v in "${PHP_VERSIONS[@]}"; do
		# A hand-made ext-redis.ini (pre-tap pecl build) double-loads redis once the tap's 20-redis.ini exists.
		if [ -f "$BREW_PREFIX/etc/php/$v/conf.d/20-redis.ini" ] && [ -f "$BREW_PREFIX/etc/php/$v/conf.d/ext-redis.ini" ]; then
			rm "$BREW_PREFIX/etc/php/$v/conf.d/ext-redis.ini"; ok "PHP $v: removed duplicate ext-redis.ini (tap build takes over)"
		fi
		dst="$BREW_PREFIX/etc/php/$v/conf.d/zz-uo-dev.ini"
		[ -d "$(dirname "$dst")" ] || { warn "no conf.d for PHP $v (formula not installed?)"; continue; }
		if ! cmp -s "$REPO_DIR/php/zz-uo-dev.ini" "$dst"; then
			cp "$REPO_DIR/php/zz-uo-dev.ini" "$dst"; ok "installed $dst"
		else
			ok "up to date: $dst"
		fi
	done
}

# Xdebug formulae drop conf.d/20-xdebug.ini (always on). First time we see one, switch it off; after that
# bin/php-xdebug owns the state (marker file .xdebug-managed).
ensure_xdebug_default_off() {
	log "Xdebug default state"
	local v d
	for v in "${PHP_VERSIONS[@]}"; do
		d="$BREW_PREFIX/etc/php/$v/conf.d"
		[ -d "$d" ] || continue
		if [ -f "$d/20-xdebug.ini" ] && [ ! -f "$d/.xdebug-managed" ]; then
			mv "$d/20-xdebug.ini" "$d/20-xdebug.ini.off"; touch "$d/.xdebug-managed"
			ok "PHP $v: xdebug installed, off (bin/php-xdebug on --php $v to enable)"
		elif [ -f "$d/20-xdebug.ini" ]; then ok "PHP $v: xdebug ON"
		elif [ -f "$d/20-xdebug.ini.off" ]; then ok "PHP $v: xdebug off"
		else warn "PHP $v: xdebug not installed"
		fi
	done
}

PMA_DIR="$HOME/.local/share/local-devstack/phpmyadmin"
ensure_phpmyadmin() {
	log "phpMyAdmin"
	if [ ! -f "$PMA_DIR/index.php" ]; then
		local tmp; tmp="$(mktemp -d)"
		curl -fsSL -o "$tmp/pma.zip" "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip"
		unzip -q "$tmp/pma.zip" -d "$tmp/x"
		mkdir -p "$(dirname "$PMA_DIR")"; rm -rf "$PMA_DIR"
		mv "$tmp"/x/phpMyAdmin-* "$PMA_DIR"; rm -rf "$tmp"
		ok "downloaded phpMyAdmin $(sed -nE "s/.*VERSION = '([^']+)'.*/\1/p" "$PMA_DIR/libraries/classes/Version.php" 2> /dev/null | head -1)"
	fi
	mkdir -p "$PMA_DIR/tmp"
	if [ ! -f "$PMA_DIR/config.inc.php" ]; then
		cat > "$PMA_DIR/config.inc.php" <<PHP
<?php
// local-devstack: local-only phpMyAdmin, auto-login as the Homebrew MySQL root (no password).
declare(strict_types=1);
\$cfg['blowfish_secret'] = '$(openssl rand -base64 24)';
\$cfg['TempDir'] = __DIR__ . '/tmp';
\$i = 1;
\$cfg['Servers'][\$i]['host']            = '127.0.0.1';
\$cfg['Servers'][\$i]['port']            = '3306';
\$cfg['Servers'][\$i]['auth_type']       = 'config';
\$cfg['Servers'][\$i]['user']            = 'root';
\$cfg['Servers'][\$i]['password']        = '';
\$cfg['Servers'][\$i]['AllowNoPassword'] = true;
\$cfg['ShowPhpInfo']   = true;
\$cfg['MaxNavigationItems'] = 250;
PHP
		ok "config.inc.php written"
	fi
	[ -L "$VALET_HOME/Sites/phpmyadmin" ] || ( cd "$PMA_DIR" && valet link phpmyadmin > /dev/null )
	[ -f "$VALET_HOME/Certificates/phpmyadmin.test.crt" ] || valet secure phpmyadmin > /dev/null
	ok "https://phpmyadmin.test"
}

ensure_composer_path() {
	log "Composer global bin on PATH"
	local line='export PATH="$HOME/.composer/vendor/bin:$PATH"'
	if ! grep -qF "$line" "$HOME/.zshrc" 2> /dev/null; then
		printf '\n# local-devstack: Laravel Valet\n%s\n' "$line" >> "$HOME/.zshrc"
		ok "added to ~/.zshrc"
	fi
	export PATH="$COMPOSER_BIN:$PATH"
}

# add_ipv6_listen <nginx conf> : Valet 4.12.0 answers dnsmasq with ::1 but only listens on 127.0.0.1 (laravel/valet #1558).
add_ipv6_listen() {
	local f="$1"
	[ -f "$f" ] || return 0
	grep -q 'listen \[::1\]' "$f" && return 0
	perl -0pi -e 's/^(\s*)listen 127\.0\.0\.1:(\d+)([^;\n]*);/$&\n$1listen [::1]:$2$3;/mg' "$f"
	ok "IPv6 listen added: $f"
}

ensure_valet() {
	log "Laravel Valet"
	if [ ! -x "$COMPOSER_BIN/valet" ]; then
		composer global require laravel/valet --quiet
		ok "valet installed via composer"
	fi
	[ -L "$VALET_BIN" ] || ln -s "$COMPOSER_BIN/valet" "$VALET_BIN"
	# Patch stubs before install/secure so every generated conf carries the IPv6 listen.
	local stub
	for stub in valet.conf secure.valet.conf isolated.valet.conf secure.isolated.valet.conf; do
		add_ipv6_listen "$HOME/.composer/vendor/laravel/valet/cli/stubs/$stub"
	done
	# /etc/resolver/test is written by the last-but-one install step (dnsmasq); its absence means an incomplete install.
	# Valet 4.12.0's SUPPORTED_PHP_VERSIONS stops at php@8.5; add newer tap builds so `valet isolate php@8.6` works.
	local brewphp="$HOME/.composer/vendor/laravel/valet/cli/Valet/Brew.php" v
	for v in 8.6 8.7; do
		if [ -d "$BREW_PREFIX/opt/php@$v" ] && ! /usr/bin/grep -q "'php@$v'" "$brewphp"; then
			sed -i '' "s/'php@8.5',/'php@8.5',\n        'php@$v',/" "$brewphp" && ok "valet: added php@$v to supported versions"
		fi
	done
	if [ ! -f "$VALET_HOME/config.json" ] || [ ! -f /etc/resolver/test ]; then
		warn "valet install (asks for sudo unless already trusted)"
		valet install
	fi
	if [ ! -f /etc/sudoers.d/valet ]; then
		warn "valet trust needs your sudo password (once)"
		valet trust
	fi
	ok "valet $("$VALET_BIN" --version | awk '{print $NF}') installed and trusted"
	add_ipv6_listen "$BREW_PREFIX/etc/nginx/valet/valet.conf"
	local f
	for f in "$VALET_HOME"/Nginx/*; do add_ipv6_listen "$f"; done
	valet use "$DEFAULT_PHP" --force > /dev/null
	ok "default PHP $DEFAULT_PHP"
	valet restart > /dev/null
}

ensure_services() {
	log "Data services"
	brew services start mysql@8.4 > /dev/null 2>&1 || true
	ok "mysql@8.4 $(brew services list | awk '$1=="mysql@8.4"{print $2}')"
	brew services start memcached > /dev/null 2>&1 || true
	ok "memcached $(brew services list | awk '$1=="memcached"{print $2}')"
	if [ "started" = "$(brew services list | awk '$1=="redis"{print $2}')" ]; then
		ok "redis started"
	elif lsof -nP -iTCP:6379 -sTCP:LISTEN 2> /dev/null | awk 'NR>1{print $1}' | /usr/bin/grep -q '^com\.docke'; then
		# Homebrew's redis binds 127.0.0.1 and can coexist with Docker's *:6379, so try anyway and report honestly.
		brew services start redis > /dev/null 2>&1 || true
		if [ "started" = "$(brew services list | awk '$1=="redis"{print $2}')" ]; then ok "redis started (beside a Docker redis on *:6379)"; else warn "redis could not start: port 6379 is held by a Docker container"; fi
	else
		brew services start redis > /dev/null 2>&1 || true
		ok "redis $(brew services list | awk '$1=="redis"{print $2}')"
	fi
	local owner
	owner="$(lsof -nP -iTCP:1025 -sTCP:LISTEN 2> /dev/null | awk 'NR==2{print $1}')"
	if [ -n "$owner" ] && [ "mailpit" != "$owner" ]; then
		warn "port 1025 is held by $owner (MAMP MailHog?) — Mailpit not started; mail from Valet sites still lands there via SMTP"
	else
		brew services start mailpit > /dev/null 2>&1 || true
		ok "mailpit $(brew services list | awk '$1=="mailpit"{print $2}')"
	fi
}

# Daily log rotation at 04:00 via a user LaunchAgent (no sudo: nginx's root-owned log is renamed and nginx
# restarted through the trusted brew path). Keeps today + yesterday, so nothing older than 48 h survives.
ensure_log_pruning() {
	log "Log rotation"
	local label="com.local-devstack.logs-prune" plist="$HOME/Library/LaunchAgents/com.local-devstack.logs-prune.plist" tmp
	mkdir -p "$HOME/Library/LaunchAgents" "$BREW_PREFIX/var/log"
	tmp="$(mktemp)"
	cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO_DIR/bin/logs-prune</string></array>
	<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
	<key>RunAtLoad</key><false/>
	<key>StandardOutPath</key><string>$BREW_PREFIX/var/log/local-devstack-prune.log</string>
	<key>StandardErrorPath</key><string>$BREW_PREFIX/var/log/local-devstack-prune.log</string>
	<key>EnvironmentVariables</key><dict><key>PATH</key><string>$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>HOME</key><string>$HOME</string></dict>
</dict></plist>
PLIST
	if ! cmp -s "$tmp" "$plist"; then
		launchctl bootout "gui/$(id -u)/$label" > /dev/null 2>&1 || true
		mv "$tmp" "$plist"
		launchctl bootstrap "gui/$(id -u)" "$plist" && ok "LaunchAgent installed: rotates logs daily at 04:00"
	else
		rm -f "$tmp"
		launchctl print "gui/$(id -u)/$label" > /dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$plist"
		ok "LaunchAgent present: rotates logs daily at 04:00"
	fi
}

ensure_dashboard() {
	log "Dashboard"
	if [ ! -L "$VALET_HOME/Sites/dashboard" ]; then
		( cd "$REPO_DIR/dashboard" && valet link dashboard > /dev/null )
	fi
	[ -f "$VALET_HOME/Certificates/dashboard.test.crt" ] || valet secure dashboard > /dev/null
	ok "https://dashboard.test"
}

ensure_brew
ensure_formulae
php_versions_installed
ensure_php_linked
ensure_php_ini
ensure_xdebug_default_off
ensure_composer_path
ensure_valet
ensure_services
ensure_dashboard
ensure_phpmyadmin
ensure_log_pruning
log "Done. Next: bin/migrate-site <host>  (pilot: cleantest, clean-automator)"
