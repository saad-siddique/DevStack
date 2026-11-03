#!/usr/bin/env bash
# bin/cleanup --pin / --unpin / --drop: pins and the guarded drop.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
source "$REPO/tests/lib/scratch-mysql.sh"
source "$REPO/tests/lib/cleanup-fixtures.sh"

scratch_mysql_start
trap 'release_connection; scratch_mysql_stop' EXIT
cleanup_fixture_env
make_fixtures
CLEANUP="$REPO/bin/cleanup"

# drop_throwaway_run_by_tag
out="$("$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
assert_eq 0 "$rc" "drop run: exits 0"
assert_jq 2 '.dropped | length' "$out" "drop run: both lanes dropped"
assert_jq true '.freed_bytes > 0' "$out" "drop run: freed bytes reported"
assert_jq false '.dry_run' "$out" "drop run: not a dry run"
assert_eq "yes" "$(gone 'suite_pr1_final%' && echo yes || echo no)" "drop run: the lane schemas are gone"
assert_eq "no" "$([ -d "$BACKUP_ROOT/_dropped" ] && echo yes || echo no)" "drop run: a throwaway is dropped without a dump"

# drop_twice_is_ok
out="$("$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
assert_eq 0 "$rc" "drop twice: exits 0"
assert_jq suite_pr1_final '.already_gone[0]' "$out" "drop twice: the target is reported as already gone"
assert_jq 0 '.dropped | length' "$out" "drop twice: nothing dropped the second time"

# drop_refuses_owned_locked_pinned
reset_fixtures
out="$("$CLEANUP" --drop site_one_db --yes --json)"; rc=$?
assert_eq 1 "$rc" "owned: exit 1"
assert_jq owned '.refused[0].reason' "$out" "owned: a linked site's database is refused"
assert_eq "no" "$(gone site_one_db && echo yes || echo no)" "owned: the schema is still there"
out="$("$CLEANUP" --drop inv_only_db --yes --json)"
assert_jq owned '.refused[0].reason' "$out" "owned: an inventory database is refused"

hold_connection suite_pr1_final_single_0 5
out="$("$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
release_connection
assert_eq 1 "$rc" "locked: exit 1"
assert_jq locked '.refused[0].reason' "$out" "locked: a run with a live connection is refused"
assert_eq "no" "$(gone suite_pr1_final_single_1 && echo yes || echo no)" "locked: no lane of a locked run is dropped"

"$CLEANUP" --pin suite_pr1_final > /dev/null
out="$("$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
assert_eq 1 "$rc" "pinned: exit 1"
assert_jq pinned '.refused[0].reason' "$out" "pinned: a pinned run is refused"
out="$("$CLEANUP" --drop suite_pr1_final_single_0 --yes --json)"
assert_jq pinned '.refused[0].reason' "$out" "pinned: a single lane of a pinned run is refused too"
"$CLEANUP" --unpin suite_pr1_final > /dev/null
out="$("$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
assert_eq 0 "$rc" "unpinned: the same drop succeeds"
assert_jq 2 '.dropped | length' "$out" "unpinned: both lanes dropped"

# drop_unknown_dumps_first
reset_fixtures
out="$("$CLEANUP" --drop scratch_notes --yes --json)"; rc=$?
assert_eq 0 "$rc" "unknown: exits 0"
dump="$(ls "$BACKUP_ROOT"/_dropped/*/scratch_notes.sql.zst 2> /dev/null | head -1)"
assert_eq "yes" "$([ -s "$dump" ] && echo yes || echo no)" "unknown: a non-empty compressed dump was written first"
assert_eq "yes" "$(gone scratch_notes && echo yes || echo no)" "unknown: the schema is gone"
assert_match 'CREATE TABLE' "$(zstd -dc "$dump" 2> /dev/null)" "unknown: the dump holds the table definitions"

# drop_dry_run_changes_nothing
reset_fixtures
out="$("$CLEANUP" --drop suite_pr1_final --dry-run --json)"; rc=$?
assert_eq 0 "$rc" "dry run: exits 0 without --yes"
assert_jq true '.dry_run' "$out" "dry run: flagged"
assert_jq 2 '.dropped | length' "$out" "dry run: lists what would drop"
assert_eq "no" "$(gone suite_pr1_final_single_0 && echo yes || echo no)" "dry run: nothing was dropped"
assert_status 2 "drop without --yes or --dry-run exits 2" "$CLEANUP" --drop suite_pr1_final

# drop_handles_hyphenated_database
out="$("$CLEANUP" --drop hyphen-db_single_0 --yes --json)"; rc=$?
assert_eq 0 "$rc" "hyphen: exits 0"
assert_jq hyphen-db_single_0 '.dropped[0].name' "$out" "hyphen: dropped by its full name"
assert_eq "yes" "$(gone 'hyphen-db_single_0' && echo yes || echo no)" "hyphen: the schema is gone"
reset_fixtures
out="$("$CLEANUP" --drop hyphen-db --yes --json)"
assert_jq hyphen-db_single_0 '.dropped[0].name' "$out" "hyphen: dropped by its run tag"

# drop_refuses_database_written_after_listing
reset_fixtures
listing="$("$CLEANUP" --json)"
assert_jq idle '.runs[] | select(.tag == "suite_pr1_final") | .state' "$listing" "toctou: idle when listed"
scratch_sql "INSERT INTO suite_pr1_final_single_0.test_options VALUES (1)" > /dev/null
out="$("$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
assert_eq 1 "$rc" "toctou: exit 1"
assert_jq locked '.refused[0].reason' "$out" "toctou: a write after the listing locks it at drop time"
assert_eq "no" "$(gone suite_pr1_final_single_0 && echo yes || echo no)" "toctou: the schema is still there"

# drop_rejects_bad_names
reset_fixtures
out="$("$CLEANUP" --drop 'a;b' --yes --json)"; rc=$?
assert_eq 1 "$rc" "bad name: exit 1"
assert_jq bad_name '.refused[0].reason' "$out" "bad name: refused as bad_name"
assert_eq 3 "$(scratch_sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'suite%'")" "bad name: nothing was dropped"

# Final review #2: lanes whose run tag equals an owned database's name must be droppable, and the owned database must survive.
reset_fixtures
mk_db site_one_db_single_0 test_options; age_db site_one_db_single_0 2
out="$("$CLEANUP" --drop site_one_db --yes --json)"; rc=$?
assert_eq 0 "$rc" "tag equals owned name: exits 0"
assert_jq '["site_one_db_single_0"]' '[.dropped[].name] | tostring' "$out" "tag equals owned name: the lane is dropped"
assert_eq "no" "$(gone site_one_db && echo yes || echo no)" "tag equals owned name: the owned database is untouched"
out="$("$CLEANUP" --drop site_one_db --yes --json)"; rc=$?
assert_eq 1 "$rc" "owned name with no lanes: still refused"
assert_jq owned '.refused[0].reason' "$out" "owned name with no lanes: reason owned"

# Final review #3: a DROP that fails (here: a client holds a metadata lock on a table without USE-ing the database, so
# the lock guard cannot see it) is refused as drop_failed, never reported as dropped, and the other lane still goes.
reset_fixtures
"$BREW_PREFIX/opt/mysql@8.4/bin/mysql" --no-defaults -uroot -S "$MYSQL_SOCK" -e "BEGIN; SELECT COUNT(*) FROM suite_pr1_final_single_0.test_options; SELECT SLEEP(9)" > /dev/null 2>&1 &
HELD_PID=$!; sleep 1
out="$(CLEANUP_LOCK_WAIT=2 "$CLEANUP" --drop suite_pr1_final --yes --json)"; rc=$?
release_connection
assert_eq 1 "$rc" "drop failure: exit 1"
assert_jq drop_failed '.refused[0].reason' "$out" "drop failure: refused as drop_failed"
assert_jq suite_pr1_final_single_0 '.refused[0].name' "$out" "drop failure: names the lane that failed"
assert_jq '["suite_pr1_final_single_1"]' '[.dropped[].name] | tostring' "$out" "drop failure: only the lane that went is listed as dropped"
assert_jq true '.freed_bytes == ([.dropped[].bytes] | add)' "$out" "drop failure: freed bytes count only what was dropped"
assert_eq "no" "$(gone suite_pr1_final_single_0 && echo yes || echo no)" "drop failure: the failed lane is still there"
assert_eq "yes" "$(gone suite_pr1_final_single_1 && echo yes || echo no)" "drop failure: the other lane is gone"

# Final review #3, second half: when MySQL answers the liveness probe but then fails, the scan must fail the run, not come
# back empty and report every target as already gone. A stub mysql answers only `SELECT 1`.
FAKE="$SCRATCH_ROOT/fake-brew"; mkdir -p "$FAKE/opt/mysql@8.4/bin"
cat > "$FAKE/opt/mysql@8.4/bin/mysql" <<'SH'
#!/bin/bash
[ "$*" = "-uroot -e SELECT 1" ] && exit 0
echo "ERROR 2013: Lost connection to MySQL server" >&2
exit 1
SH
chmod +x "$FAKE/opt/mysql@8.4/bin/mysql"
out="$(BREW_PREFIX="$FAKE" MYSQL_SOCK="" "$CLEANUP" --drop suite_pr1_final --yes --json 2> /dev/null)"; rc=$?
assert_eq 1 "$rc" "scan failure: exits 1 instead of reporting everything as already gone"
assert_eq "" "$(printf '%s' "$out" | jq -r '.already_gone[]? // empty' 2> /dev/null)" "scan failure: nothing is reported as already gone"

# pin_is_idempotent
reset_fixtures
"$CLEANUP" --pin suite_pr1_final > /dev/null
"$CLEANUP" --pin suite_pr1_final > /dev/null
assert_eq '["suite_pr1_final"]' "$(jq -c '.pinned' "$DATA_DIR/cleanup.json")" "pin: pinning twice leaves one entry"
assert_jq true '.runs[] | select(.tag == "suite_pr1_final") | .pinned' "$("$CLEANUP" --json)" "pin: the listing shows the run as pinned"
"$CLEANUP" --unpin suite_pr1_final > /dev/null
assert_eq '[]' "$(jq -c '.pinned' "$DATA_DIR/cleanup.json")" "pin: unpin empties the list"
assert_status 2 "pin without a target exits 2" "$CLEANUP" --pin

test_summary
