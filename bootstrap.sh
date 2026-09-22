#!/usr/bin/env bash
# local-devstack bootstrap: idempotent. Run it again any time.
# Needs your sudo password once (valet install / valet trust); after that brew+valet are passwordless.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix)"
COMPOSER_BIN="$HOME/.composer/vendor/bin"
VALET_BIN="$COMPOSER_BIN/valet"
VALET_HOME="$HOME/.config/valet"
DEFAULT_PHP="php@8.4"
PHP_VERSIONS=(8.4 7.4)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*"; }

ensure_brew() {
	command -v brew > /dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
	xcode-select -p > /dev/null 2>&1 || { echo "Xcode / Command Line Tools missing"; exit 1; }
	ok "Homebrew $(brew --version | head -1 | awk '{print $2}') at $BREW_PREFIX"
}

ensure_formulae() {
	log "Homebrew formulae"
	brew tap shivammathur/php > /dev/null
	if brew help trust > /dev/null 2>&1; then brew trust shivammathur/php > /dev/null 2>&1 || true; fi
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
		dst="$BREW_PREFIX/etc/php/$v/conf.d/zz-uo-dev.ini"
		[ -d "$(dirname "$dst")" ] || { warn "no conf.d for PHP $v (formula not installed?)"; continue; }
		if ! cmp -s "$REPO_DIR/php/zz-uo-dev.ini" "$dst"; then
			cp "$REPO_DIR/php/zz-uo-dev.ini" "$dst"; ok "installed $dst"
		else
			ok "up to date: $dst"
		fi
	done
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
	perl -0pi -e 's/^(\s*)listen 127\.0\.0\.1:(\d+)( ssl)?;/$&\n$1listen [::1]:$2$3;/mg' "$f"
	ok "IPv6 listen added: $f"
}

ensure_valet() {
	log "Laravel Valet"
	if [ ! -x "$VALET_BIN" ]; then
		composer global require laravel/valet --quiet
		ok "valet installed via composer"
	fi
	# Patch stubs before install/secure so every generated conf carries the IPv6 listen.
	local stub
	for stub in valet.conf secure.valet.conf isolated.valet.conf secure.isolated.valet.conf; do
		add_ipv6_listen "$HOME/.composer/vendor/laravel/valet/cli/stubs/$stub"
	done
	if [ ! -f "$VALET_HOME/config.json" ]; then
		warn "valet install needs your sudo password"
		"$VALET_BIN" install
	fi
	if [ ! -f /etc/sudoers.d/valet ]; then
		warn "valet trust needs your sudo password (once)"
		"$VALET_BIN" trust
	fi
	ok "valet $("$VALET_BIN" --version | awk '{print $NF}') installed and trusted"
	add_ipv6_listen "$BREW_PREFIX/etc/nginx/valet/valet.conf"
	local f
	for f in "$VALET_HOME"/Nginx/*; do add_ipv6_listen "$f"; done
	"$VALET_BIN" use "$DEFAULT_PHP" --force > /dev/null
	ok "default PHP $DEFAULT_PHP"
	"$VALET_BIN" restart > /dev/null
}

ensure_services() {
	log "Data services"
	brew services start mysql@8.4 > /dev/null 2>&1 || true
	ok "mysql@8.4 $(brew services list | awk '$1=="mysql@8.4"{print $2}')"
	local owner
	owner="$(lsof -nP -iTCP:1025 -sTCP:LISTEN 2> /dev/null | awk 'NR==2{print $1}')"
	if [ -n "$owner" ] && [ "mailpit" != "$owner" ]; then
		warn "port 1025 is held by $owner (MAMP MailHog?) — Mailpit not started; mail from Valet sites still lands there via SMTP"
	else
		brew services start mailpit > /dev/null 2>&1 || true
		ok "mailpit $(brew services list | awk '$1=="mailpit"{print $2}')"
	fi
}

ensure_dashboard() {
	log "Dashboard"
	if [ ! -L "$VALET_HOME/Sites/dashboard" ]; then
		( cd "$REPO_DIR/dashboard" && "$VALET_BIN" link dashboard > /dev/null )
	fi
	[ -f "$VALET_HOME/Certificates/dashboard.test.crt" ] || "$VALET_BIN" secure dashboard > /dev/null
	ok "https://dashboard.test"
}

ensure_brew
ensure_formulae
ensure_php_linked
ensure_php_ini
ensure_composer_path
ensure_valet
ensure_services
ensure_dashboard
log "Done. Next: bin/migrate-site <host>  (pilot: cleantest, clean-automator)"
