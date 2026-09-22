# local-devstack Brewfile — `brew bundle --file=Brewfile`
tap "shivammathur/php"
tap "shivammathur/extensions"

brew "composer"
brew "wp-cli"
brew "php@8.4", link: true   # keg-only; Valet needs /opt/homebrew/bin/php -> php@8.4
brew "shivammathur/php/php@7.4"
brew "mysql@8.4"
brew "mailpit"

# Xdebug, prebuilt. Installed but switched off by default; bin/php-xdebug toggles it.
brew "shivammathur/extensions/xdebug@7.4"
brew "shivammathur/extensions/xdebug@8.4"
