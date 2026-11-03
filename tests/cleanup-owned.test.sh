#!/usr/bin/env bash
# Final review #6: which database a site owns is read the way WordPress finds its wp-config.php (docroot, else the parent
# folder), ignoring commented-out lines; a site whose wp-config names DB_NAME without a literal cannot be resolved, so the
# listing says so and trusts only the strictest throwaway signal meanwhile.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
source "$REPO/tests/lib/scratch-mysql.sh"
source "$REPO/tests/lib/cleanup-fixtures.sh"

scratch_mysql_start
trap 'scratch_mysql_stop' EXIT
cleanup_fixture_env
CLEANUP="$REPO/bin/cleanup"
run_of() { printf '%s' "$1" | jq -c --arg t "$2" '.runs[] | select(.tag == $t)'; }

S="$SCRATCH_ROOT/sitefolders"
# site-two: the wp-config sits one level above the docroot the site is linked to.
mkdir -p "$S/site-two/public"
printf '<?php\ndefine( "DB_NAME", "site_two_db" );\n' > "$S/site-two/wp-config.php"
ln -sfn "$S/site-two/public" "$VALET_HOME/Sites/site-two"
# site-three: commented-out defines come before the real one.
mkdir -p "$S/site-three"
cat > "$S/site-three/wp-config.php" <<'PHP'
<?php
// define( 'DB_NAME', 'old_db' );
# define( 'DB_NAME', 'older_db' );
 * define( 'DB_NAME', 'oldest_db' );
define( 'DB_NAME', 'site_three_db' );
PHP
ln -sfn "$S/site-three" "$VALET_HOME/Sites/site-three"

mk_db site_one_db wp_options
mk_db site_two_db wp_options
mk_db site_three_db wp_options
mk_db old_db notes
mk_db older_db notes
mk_db env_db test_options
for d in site_one_db site_two_db site_three_db old_db older_db env_db; do age_db "$d" 2; done

base="$("$CLEANUP" --json)"
assert_jq 3 '.mysql.owned' "$base" "owned: the docroot, parent-folder and after-comments layouts all resolve"
assert_jq null '[.runs[].databases[]] | index("site_two_db")' "$base" "parent wp-config: site_two_db is owned, not listed"
assert_jq null '[.runs[].databases[]] | index("site_three_db")' "$base" "after comments: site_three_db is owned, not listed"
assert_jq 1 '[.runs[].databases[]] | map(select(. == "old_db")) | length' "$base" "comments: a commented-out define does not own old_db"
assert_jq 1 '[.runs[].databases[]] | map(select(. == "older_db")) | length' "$base" "comments: a # line does not own older_db"
assert_jq '[]' '.warnings | tostring' "$base" "no warnings while every wp-config resolves"
assert_jq throwaway '.kind' "$(run_of "$base" env_db)" "before an unresolvable site: a test options table alone is throwaway"

# site-four: DB_NAME comes from the environment, so no literal exists.
mkdir -p "$S/site-four"
printf '<?php\ndefine( "DB_NAME", getenv( "DB_NAME" ) );\n' > "$S/site-four/wp-config.php"
ln -sfn "$S/site-four" "$VALET_HOME/Sites/site-four"
mk_db lane_x_single_0 test_options; age_db lane_x_single_0 2
warned="$("$CLEANUP" --json)"; rc=$?
assert_eq 0 "$rc" "unresolvable: the listing still succeeds"
assert_jq 1 '.warnings | length' "$warned" "unresolvable: one warning"
assert_match 'site-four' "$(printf '%s' "$warned" | jq -r '.warnings[0]')" "unresolvable: the warning names the site"
assert_jq unknown '.kind' "$(run_of "$warned" env_db)" "unresolvable: a test options table alone is no longer trusted as throwaway"
assert_jq throwaway '.kind' "$(run_of "$warned" lane_x)" "unresolvable: lane suffix AND test options is still throwaway"
assert_jq true '.sweepable' "$(run_of "$warned" lane_x)" "unresolvable: and still sweepable"

test_summary
