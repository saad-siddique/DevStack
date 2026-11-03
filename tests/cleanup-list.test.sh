#!/usr/bin/env bash
# bin/cleanup (default action): scan, classify and list databases no site owns.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
source "$REPO/tests/lib/scratch-mysql.sh"
source "$REPO/tests/lib/cleanup-fixtures.sh"

scratch_mysql_start
trap 'release_connection; scratch_mysql_stop' EXIT
cleanup_fixture_env
make_fixtures

CLEANUP="$REPO/bin/cleanup"
run_of() { printf '%s' "$1" | jq -c --arg t "$2" '.runs[] | select(.tag == $t)'; }

base="$("$CLEANUP" --json)"; rc=$?
assert_eq 0 "$rc" "list: exits 0 with a dangling site link and a non-WordPress folder present"

# list_classifies_every_fixture
r="$(run_of "$base" suite_pr1_final)"
assert_jq 2 '.lanes' "$r" "classify: two lanes make one run"
assert_jq throwaway '.kind' "$r" "classify: lane suffix + test options is throwaway"
assert_jq true '.sweepable' "$r" "classify: lane suffix + test options is sweepable"
assert_jq idle '.state' "$r" "classify: two-hour-old files are idle"
assert_jq null '.locked_reason' "$r" "classify: idle has no locked reason"
r="$(run_of "$base" other_tool)"
assert_jq throwaway '.kind' "$r" "classify: lane suffix alone is throwaway"
assert_jq false '.sweepable' "$r" "classify: lane suffix without test options is not sweepable"
r="$(run_of "$base" suite_odd_lane_0)"
assert_jq throwaway '.kind' "$r" "classify: test options alone is throwaway"
assert_jq false '.sweepable' "$r" "classify: test options without lane suffix is not sweepable"
assert_jq 1 '.lanes' "$r" "classify: a non-lane database is its own run"
r="$(run_of "$base" scratch_notes)"
assert_jq unknown '.kind' "$r" "classify: neither signal is unknown"
assert_jq false '.sweepable' "$r" "classify: unknown is not sweepable"
assert_jq null '[.runs[].databases[]] | index("site_one_db")' "$base" "classify: a linked site's database is never listed"
assert_jq null '[.runs[].databases[]] | index("inv_only_db")' "$base" "classify: an inventory database is never listed"
assert_jq 2 '.mysql.owned' "$base" "summary: two owned databases counted"
assert_jq 6 '.mysql.unowned' "$base" "summary: six unowned databases"
assert_jq 8 '.mysql.databases' "$base" "summary: eight non-system databases"
assert_jq true '[.runs[].last_write] == ([.runs[].last_write] | sort)' "$base" "list: runs sorted oldest last write first"
assert_jq true '.disk_free_bytes > 0 and .mysql.catalog_bytes > 0 and .mysql.catalog_free_bytes >= 0' "$base" "summary: disk and catalog sizes present"
assert_jq false '.sweep.enabled' "$base" "summary: sweep is off by default"
assert_jq 48 '.sweep.older_than_hours' "$base" "summary: default threshold is 48 hours"
assert_jq '[]' '.sweep.next | tostring' "$base" "summary: nothing queued for the sweep yet"
assert_jq true '.runs[] | select(.tag == "suite_pr1_final") | .files_bytes > 0' "$base" "classify: files_bytes comes from the table files"

# list_handles_hyphenated_database_name
r="$(run_of "$base" hyphen-db)"
assert_jq hyphen-db_single_0 '.databases[0]' "$r" "hyphen: the decoded database name is listed"
assert_jq true '.files_bytes > 0' "$r" "hyphen: its @002d folder is found for sizing"
assert_jq idle '.state' "$r" "hyphen: its aged files read as idle"

# list_marks_locked_by_connection
hold_connection suite_pr1_final_single_0 5
held="$("$CLEANUP" --json)"
release_connection
r="$(run_of "$held" suite_pr1_final)"
assert_jq locked '.state' "$r" "lock: a live connection locks the run"
assert_jq connection '.locked_reason' "$r" "lock: the reason is the connection"

# list_marks_locked_by_recent_write
mk_db recent_single_0 test_options
age_db recent_single_0 2
scratch_sql "INSERT INTO recent_single_0.test_options VALUES (1)" > /dev/null
recent="$("$CLEANUP" --json)"
r="$(run_of "$recent" recent)"
assert_jq locked '.state' "$r" "lock: a write after the files were aged locks the run"
assert_jq recent_write '.locked_reason' "$r" "lock: the reason is the recent write"

# list_reports_error_when_mysql_down
down="$(MYSQL_SOCK=/nonexistent "$CLEANUP" --json)"; rc=$?
assert_eq 1 "$rc" "down: exits 1 when MySQL does not answer"
assert_jq "mysql not answering" '.error' "$down" "down: JSON error message"

test_summary
