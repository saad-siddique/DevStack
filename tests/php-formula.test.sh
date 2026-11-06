#!/usr/bin/env bash
# php_formula maps php@X.Y to the Homebrew formula (and brew services name) behind it. Homebrew's newest PHP is the
# `php` formula; current Homebrew still links opt/php@X.Y for that alias, but into Cellar/php/. Treating that link as its
# own formula made `devstack restart` report the newest PHP as "unknown" (brew services lists it as `php`).
# Runs against a scratch BREW_PREFIX; brew itself is never called.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-php-formula-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/Cellar/php/8.5.12_1" "$T/Cellar/php@8.4/8.4.27_1" "$T/opt/php@8.6"
ln -s ../Cellar/php/8.5.12_1 "$T/opt/php"
ln -s ../Cellar/php@8.4/8.4.27_1 "$T/opt/php@8.4"

export BREW_PREFIX="$T"   # exported, not a prefix: a prefix on `source` is gone once lib.sh returns
source "$REPO/bin/lib.sh"
set +e   # lib.sh turns on errexit; a failing assertion must not end the test early

assert_eq "php@8.4" "$(php_formula php@8.4)" "a versioned formula keeps its own name"
assert_eq "php" "$(php_formula php@8.5)" "the newest PHP without an alias link (older Homebrew) is \`php\`"
ln -s ../Cellar/php/8.5.12_1 "$T/opt/php@8.5"
assert_eq "php" "$(php_formula php@8.5)" "the newest PHP with an alias link into Cellar/php/ is still \`php\`"
assert_eq "php@8.6" "$(php_formula php@8.6)" "a tap formula installed as a plain opt/ folder keeps its own name"
assert_eq "php" "$(php_formula php@8.3)" "a version that is not installed falls back to \`php\`, as before"

test_summary
