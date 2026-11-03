#!/usr/bin/env bash
# Issue 7: a plugin symlink re-pointed with `ln -sfn` kept serving the old checkout from php-fpm workers for up to
# two minutes, because PHP caches resolved paths for realpath_cache_ttl seconds (default 120) in every worker.
# This runs real PHP with php/zz-uo-dev.ini as its only configuration: prime the cache through the link, re-point the
# link, wait past the TTL, and the new target must be the one that is resolved AND the one that is included.
# The control run uses PHP's own default and must still serve the old checkout, which shows the test can fail.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix)}"
PHP="$BREW_PREFIX/bin/php"
T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-realpath-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

sed "s#__BREW_PREFIX__#$BREW_PREFIX#g" "$REPO/php/zz-uo-dev.ini" > "$T/dev.ini"
: > "$T/empty.ini"
mkdir -p "$T/copy-a" "$T/copy-b"
printf '<?php echo "A";' > "$T/copy-a/probe.php"
printf '<?php echo "B";' > "$T/copy-b/probe.php"
cat > "$T/repoint.php" <<'EOF'
<?php
// argv[1]: the folder holding link/, copy-a/ and copy-b/. Prints "<folder resolved> <what the include printed>" after the re-point.
$dir = $argv[1];
$probe = $dir . '/link/probe.php';
realpath( $probe );                                     // primes this process's realpath cache while link -> copy-a
exec( 'ln -sfn ' . escapeshellarg( $dir . '/copy-b' ) . ' ' . escapeshellarg( $dir . '/link' ) );
sleep( 3 );
ob_start();
include $probe;
$included = ob_get_clean();
echo basename( dirname( (string) realpath( $probe ) ) ), ' ', $included;
EOF

# run <ini file> : a fresh folder per run, link -> copy-a, then the script above under only that ini.
run() {
	local d; d="$(mktemp -d "$T/run.XXXXXX")"
	cp -R "$T/copy-a" "$T/copy-b" "$d/"; ln -s "$d/copy-a" "$d/link"
	PHP_INI_SCAN_DIR= "$PHP" -n -c "$1" "$T/repoint.php" "$d" 2> /dev/null
}

assert_match 'copy-a A$' "$(run "$T/empty.ini")" "control, PHP's default 120 s TTL: the old checkout is still served after the re-point"
assert_match 'copy-b B$' "$(run "$T/dev.ini")" "zz-uo-dev.ini: the re-pointed checkout is resolved and included within seconds"
assert_match '^realpath_cache_ttl = [1-9][0-9]?$' "$(grep -E '^realpath_cache_ttl' "$REPO/php/zz-uo-dev.ini")" "the ttl is a small positive number (0 would mean never expire)"

test_summary
