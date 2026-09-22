# local-devstack Brewfile — `brew bundle --file=Brewfile`
tap "shivammathur/php"
tap "shivammathur/extensions"

brew "composer"
brew "wp-cli"

# PHP: every 8.x plus 7.4 for compatibility testing. php@8.4 is the CLI default and the Valet default;
# the others stay installed with php-fpm stopped until a site is isolated onto them (valet isolate).
brew "shivammathur/php/php@7.4"
brew "shivammathur/php/php@8.0"
brew "shivammathur/php/php@8.1"
brew "php@8.2"
brew "php@8.3"
brew "php@8.4", link: true            # keg-only; Valet needs /opt/homebrew/bin/php -> php@8.4
brew "php@8.5", link: false           # alias of the `php` formula (not keg-only): never let it steal the php symlink
brew "shivammathur/php/php@8.6"

brew "mysql@8.4"
brew "mailpit"
brew "memcached"
brew "redis"                          # formula, so brew services manages it (the redis cask cannot be)

# Xdebug, prebuilt per version. Installed but switched off by default; bin/php-xdebug toggles it.
brew "shivammathur/extensions/xdebug@7.4"
brew "shivammathur/extensions/xdebug@8.0"
brew "shivammathur/extensions/xdebug@8.1"
brew "shivammathur/extensions/xdebug@8.2"
brew "shivammathur/extensions/xdebug@8.3"
brew "shivammathur/extensions/xdebug@8.4"
brew "shivammathur/extensions/xdebug@8.5"
brew "shivammathur/extensions/xdebug@8.6"
