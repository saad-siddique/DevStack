#!/usr/bin/env bash
# DevStack bootstrap [--app]: idempotent. Run it again any time.
# Needs your sudo password once (valet install / valet trust); after that brew+valet are passwordless.
# --app also builds the menu-bar app from app/ and installs it to /Applications/DevStack.app.
set -euo pipefail
WITH_APP=0; PHP_ONLY="${DEVSTACK_PHP_VERSIONS:-}"
while [ $# -gt 0 ]; do
	case "$1" in
		--app) WITH_APP=1 ;;
		--php) PHP_ONLY="$2"; shift ;; --php=*) PHP_ONLY="${1#--php=}" ;;
		*) echo "unknown flag $1 (bootstrap.sh [--app] [--php 7.4,8.4])"; exit 2 ;;
	esac
	shift
done
# Everything printed also lands in a log, so a stuck-looking run can be inspected from another terminal.
BOOT_LOG="$HOME/Library/Logs/DevStack/bootstrap-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$BOOT_LOG")"; exec > >(tee -a "$BOOT_LOG") 2>&1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

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

# Installs the Brewfile one formula at a time so the run shows what it is doing. `brew bundle` prints "Installing X"
# and then nothing for the whole install, which on a Mac without a bottle (older macOS, Intel) means a silent
# from-source build that looks like a hang. Here every formula reports bottle/source, elapsed time, and failures
# with the log to read. --php 7.4,8.4 (or DEVSTACK_PHP_VERSIONS) limits the PHP versions and their extensions.
ensure_formulae() {
	log "Homebrew ($(uname -m), macOS $(sw_vers -productVersion), $(brew --version | head -1))"
	local t
	for t in shivammathur/php shivammathur/extensions; do
		brew tap "$t" > /dev/null 2>&1 || brew tap "$t"
		if brew help trust > /dev/null 2>&1; then brew trust "$t" > /dev/null 2>&1 || true; fi
	done
	log "brew update (a first run can take a few minutes)"
	brew update -q > /dev/null 2>&1 || warn "brew update failed (offline?); continuing with what Homebrew already knows"

	local -a want=() ; local f short
	while IFS= read -r f; do
		short="${f##*/}"
		if [ -n "$PHP_ONLY" ]; then
			case "$short" in
				php@*|xdebug@*|redis@*|imagick@*|memcached@*)
					printf ',%s,' "$PHP_ONLY" | grep -q ",${short#*@}," || continue ;;
			esac
		fi
		want+=("$f")
	done < <(sed -nE 's/^brew "([^"]+)".*/\1/p' "$REPO_DIR/Brewfile")
	[ -n "$PHP_ONLY" ] && log "PHP versions limited to: $PHP_ONLY"

	local installed n=0 total="${#want[@]}" i=0 t0 secs tag from
	installed="$(brew list --formula --full-name 2> /dev/null | tr '\n' ' ')"
	for f in "${want[@]}"; do
		i=$((i+1)); short="${f##*/}"
		# Fast path: the full-name list. Fallback: ask brew directly (aliases such as php@8.5 → php, tap formulae listed
		# under a different name).
		if printf ' %s ' "$installed" | grep -qE " (${f}|${short}) " || brew list --formula --versions "$f" > /dev/null 2>&1; then
			ok "[$i/$total] $short present"; continue
		fi
		# Bottle or not? `brew --cache` names what Homebrew would download for this Mac: a *.bottle.tar.gz, or the
		# source tarball, which means a compile (minutes for an extension, up to an hour for a PHP version).
		case "$(brew --cache --formula "$f" 2> /dev/null)" in
			*.bottle.*) from="bottle" ;;
			*) from="SOURCE BUILD: no bottle for this Mac, expect a long compile" ;;
		esac
		printf '\033[1;34m==>\033[0m [%d/%d] installing %s (%s)\n' "$i" "$total" "$short" "$from"
		t0="$(date +%s)"; blog="$HOME/Library/Logs/DevStack/brew-$short.log"
		brew install --formula "$f" > "$blog" 2>&1 &
		local bpid=$!
		# Heartbeat while it runs: elapsed time and the last thing Homebrew wrote, so a long install is never silent.
		while kill -0 "$bpid" 2> /dev/null; do
			sleep 10
			kill -0 "$bpid" 2> /dev/null || break
			printf '    … %ds  %s\n' "$(( $(date +%s) - t0 ))" "$(tail -n 1 "$blog" 2> /dev/null | tr -d '\r' | cut -c1-90)"
		done
		if wait "$bpid"; then
			secs=$(( $(date +%s) - t0 )); ok "[$i/$total] $short installed in ${secs}s"; n=$((n+1))
		else
			warn "[$i/$total] $short FAILED — see ~/Library/Logs/DevStack/brew-$short.log (last lines follow)"
			tail -5 "$HOME/Library/Logs/DevStack/brew-$short.log" | sed 's/^/      /'
			case "$short" in php@*|mysql@8.4|nginx|dnsmasq) echo "cannot continue without $short"; exit 1 ;; esac
		fi
	done
	# The `php` formula (php@8.5 alias) must never hold the php symlink; php@8.4 is linked by ensure_php_linked.
	brew unlink php > /dev/null 2>&1 || true
	# mysql@8.4 is keg-only; wp db export/import want mysql/mysqldump on PATH.
	brew link --force --overwrite mysql@8.4 > /dev/null 2>&1 || true
	ok "formulae present ($n newly installed)"
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

# php-fpm pool guards (php/zz-devstack-fpm.conf) for every installed version; restart the ones that run.
ensure_fpm_pool() {
	log "php-fpm pool drop-ins"
	local v dst changed=()
	for v in "${PHP_VERSIONS[@]}"; do
		dst="$BREW_PREFIX/etc/php/$v/php-fpm.d/zz-devstack.conf"
		[ -d "$(dirname "$dst")" ] || continue
		if ! sed "s#__VALET_HOME__#$VALET_HOME#" "$REPO_DIR/php/zz-devstack-fpm.conf" | cmp -s - "$dst"; then
			sed "s#__VALET_HOME__#$VALET_HOME#" "$REPO_DIR/php/zz-devstack-fpm.conf" > "$dst"; changed+=("$v"); ok "installed $dst"
		else ok "up to date: $dst"; fi
	done
	mkdir -p "$VALET_HOME/Log"
	for v in "${changed[@]+"${changed[@]}"}"; do
		local formula="php@$v"; [ -d "$BREW_PREFIX/opt/$formula" ] || formula="php"
		if sudo -n "$BREW_PREFIX/bin/brew" services list --json 2> /dev/null | jq -e --arg n "$formula" '.[] | select(.name == $n and .status == "started")' > /dev/null; then
			"$REPO_DIR/bin/service" "php@$v" restart > /dev/null 2>&1 && ok "restarted php-fpm $v" || warn "could not restart php-fpm $v"
		fi
	done
}

# MySQL tuning (mysql/zz-devstack.cnf): binary log off, fewer fsyncs, bigger buffer pool. Homebrew's my.cnf has no
# include line, so one is appended once; existing binary logs are removed after MySQL restarts without binlogging.
ensure_mysql_tuning() {
	log "MySQL tuning"
	local cnf="$BREW_PREFIX/etc/my.cnf" dir="$BREW_PREFIX/etc/my.cnf.d" dst changed=0
	mkdir -p "$dir"; dst="$dir/zz-devstack.cnf"
	if ! grep -qF "!includedir $dir" "$cnf" 2> /dev/null; then printf '\n# DevStack drop-ins\n!includedir %s\n' "$dir" >> "$cnf"; ok "my.cnf includes $dir"; changed=1; fi
	if ! cmp -s "$REPO_DIR/mysql/zz-devstack.cnf" "$dst"; then cp "$REPO_DIR/mysql/zz-devstack.cnf" "$dst"; ok "installed $dst"; changed=1; else ok "up to date: $dst"; fi
	if [ "1" = "$changed" ]; then
		"$BREW_PREFIX/bin/brew" services restart mysql@8.4 > /dev/null 2>&1 && ok "restarted mysql@8.4" || warn "could not restart mysql@8.4"
		local i; for i in $(seq 1 30); do "$BREW_PREFIX/opt/mysql@8.4/bin/mysqladmin" -uroot ping > /dev/null 2>&1 && break; sleep 1; done
	fi
	if [ "OFF" = "$("$BREW_PREFIX/opt/mysql@8.4/bin/mysql" -uroot -N -e "SELECT @@log_bin" 2> /dev/null | sed 's/^0$/OFF/;s/^1$/ON/')" ]; then
		local n; n="$(ls "$BREW_PREFIX"/var/mysql/binlog.* 2> /dev/null | wc -l | tr -d ' ' || true)"   # pipefail: no binlogs = ls fails
		if [ "$n" -gt 0 ]; then
			local size; size="$(du -ch "$BREW_PREFIX"/var/mysql/binlog.* 2> /dev/null | tail -1 | cut -f1)"
			rm -f "$BREW_PREFIX"/var/mysql/binlog.*; ok "removed $n stale binary logs ($size) — binlogging is off"
		fi
	fi
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

PMA_DIR="$HOME/.local/share/devstack/phpmyadmin"
ensure_phpmyadmin() {
	log "phpMyAdmin"
	# Installs from before the DevStack rename live under local-devstack/; move them instead of downloading again.
	local old="$HOME/.local/share/local-devstack/phpmyadmin"
	if [ -d "$old" ] && [ ! -d "$PMA_DIR" ]; then
		mkdir -p "$(dirname "$PMA_DIR")"; mv "$old" "$PMA_DIR"; rmdir "$(dirname "$old")" 2> /dev/null || true
		ok "moved phpMyAdmin to $PMA_DIR"
	fi
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
// DevStack: local-only phpMyAdmin, auto-login as the Homebrew MySQL root (no password).
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
	if [ ! -L "$VALET_HOME/Sites/phpmyadmin" ]; then ( cd "$PMA_DIR" && valet link phpmyadmin > /dev/null )
	elif [ "$(readlink "$VALET_HOME/Sites/phpmyadmin")" != "$PMA_DIR" ]; then ln -sfn "$PMA_DIR" "$VALET_HOME/Sites/phpmyadmin"; ok "re-pointed the phpmyadmin link"; fi
	[ -f "$VALET_HOME/Certificates/phpmyadmin.test.crt" ] || valet secure phpmyadmin > /dev/null
	ok "https://phpmyadmin.test"
}

ensure_composer_path() {
	log "Composer global bin on PATH"
	local line='export PATH="$HOME/.composer/vendor/bin:$PATH"'
	if ! grep -qF "$line" "$HOME/.zshrc" 2> /dev/null; then
		printf '\n# DevStack: Laravel Valet\n%s\n' "$line" >> "$HOME/.zshrc"
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
	local label="com.devstack.logs-prune" plist="$HOME/Library/LaunchAgents/com.devstack.logs-prune.plist" tmp
	mkdir -p "$HOME/Library/LaunchAgents" "$BREW_PREFIX/var/log"
	# Pre-rename agent (com.local-devstack.*): unload and remove so only one rotation runs.
	if [ -f "$HOME/Library/LaunchAgents/com.local-devstack.logs-prune.plist" ]; then
		launchctl bootout "gui/$(id -u)/com.local-devstack.logs-prune" > /dev/null 2>&1 || true
		rm -f "$HOME/Library/LaunchAgents/com.local-devstack.logs-prune.plist"; ok "removed the old com.local-devstack.logs-prune agent"
	fi
	tmp="$(mktemp)"
	cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO_DIR/bin/logs-prune</string></array>
	<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
	<key>RunAtLoad</key><false/>
	<key>StandardOutPath</key><string>$BREW_PREFIX/var/log/devstack-prune.log</string>
	<key>StandardErrorPath</key><string>$BREW_PREFIX/var/log/devstack-prune.log</string>
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

# Nightly Homebrew check of the stack (bin/stack-upgrade --nightly) at 03:30. By default it only reports what is
# outdated (app + dashboard show it with Upgrade buttons); `devstack upgrade --set-auto patch` makes it apply patch
# releases unattended. Missed runs (Mac asleep) fire once on wake.
ensure_stack_upgrades() {
	log "Nightly stack upgrades"
	local label="com.devstack.upgrade" plist="$HOME/Library/LaunchAgents/com.devstack.upgrade.plist" tmp
	tmp="$(mktemp)"
	cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string><string>'$REPO_DIR/bin/stack-upgrade' --nightly --json; '$REPO_DIR/bin/site-sizes' --refresh --json > /dev/null</string></array>
	<key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
	<key>RunAtLoad</key><false/>
	<key>StandardOutPath</key><string>$BREW_PREFIX/var/log/devstack-upgrade.log</string>
	<key>StandardErrorPath</key><string>$BREW_PREFIX/var/log/devstack-upgrade.log</string>
	<key>EnvironmentVariables</key><dict><key>PATH</key><string>$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>HOME</key><string>$HOME</string><key>HOMEBREW_NO_AUTO_UPDATE</key><string>1</string><key>HOMEBREW_NO_ENV_HINTS</key><string>1</string></dict>
</dict></plist>
PLIST
	if ! cmp -s "$tmp" "$plist"; then
		launchctl bootout "gui/$(id -u)/$label" > /dev/null 2>&1 || true
		mv "$tmp" "$plist"
		launchctl bootstrap "gui/$(id -u)" "$plist" && ok "LaunchAgent installed: nightly stack check at 03:30 (devstack upgrade --set-auto patch to apply)"
	else
		rm -f "$tmp"
		launchctl print "gui/$(id -u)/$label" > /dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$plist"
		ok "LaunchAgent present: nightly stack check at 03:30"
	fi
}

# Five-minute watchdog for nginx/dnsmasq (Homebrew's nginx plist has no KeepAlive).
ensure_watchdog() {
	log "Watchdog"
	local label="com.devstack.watchdog" plist="$HOME/Library/LaunchAgents/com.devstack.watchdog.plist" tmp
	tmp="$(mktemp)"
	cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO_DIR/bin/watchdog</string></array>
	<key>StartInterval</key><integer>300</integer>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>/dev/null</string>
	<key>StandardErrorPath</key><string>$BREW_PREFIX/var/log/devstack-watchdog.log</string>
	<key>EnvironmentVariables</key><dict><key>PATH</key><string>$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>HOME</key><string>$HOME</string></dict>
</dict></plist>
PLIST
	if ! cmp -s "$tmp" "$plist"; then
		launchctl bootout "gui/$(id -u)/$label" > /dev/null 2>&1 || true
		mv "$tmp" "$plist"
		launchctl bootstrap "gui/$(id -u)" "$plist" && ok "LaunchAgent installed: nginx/dnsmasq watchdog every 5 minutes"
	else
		rm -f "$tmp"
		launchctl print "gui/$(id -u)/$label" > /dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$plist"
		ok "LaunchAgent present: watchdog every 5 minutes"
	fi
}

# Every linked WordPress site gets the repo's mu-plugins (local SSL trust, one-time login, public share).
ensure_mu_plugins() {
	log "mu-plugins in every WordPress site"
	local l t n=0
	for l in "$VALET_HOME"/Sites/*; do
		[ -L "$l" ] || continue
		t="$(readlink "$l")"; [ -f "$t/wp-config.php" ] || continue
		# shellcheck source=bin/lib.sh
		( source "$REPO_DIR/bin/lib.sh"; install_mu_plugins "$t" ) && n=$((n+1))
	done
	ok "$n WordPress sites carry $(ls "$REPO_DIR"/mu-plugins/*.php | wc -l | tr -d ' ') mu-plugins"
}

# The global `devstack` command (bin/devstack) and its zsh completion. A symlink, so `git pull` updates it.
ensure_cli() {
	log "devstack command"
	ln -sfn "$REPO_DIR/bin/devstack" "$BREW_PREFIX/bin/devstack"
	mkdir -p "$BREW_PREFIX/share/zsh/site-functions"
	ln -sfn "$REPO_DIR/completions/_devstack" "$BREW_PREFIX/share/zsh/site-functions/_devstack"
	ok "$BREW_PREFIX/bin/devstack -> bin/devstack (try: devstack help)"
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
ensure_fpm_pool
ensure_xdebug_default_off
ensure_composer_path
ensure_valet
ensure_services
ensure_mysql_tuning
ensure_dashboard
ensure_phpmyadmin
ensure_log_pruning
ensure_stack_upgrades
ensure_watchdog
ensure_mu_plugins
ensure_cli
if [ "1" = "$WITH_APP" ]; then log "Menu-bar app"; "$REPO_DIR/bin/app" install; fi
log "Done. devstack help lists every command; devstack app install builds the menu-bar app."
