#!/usr/bin/env bash
# bin/cleanup --enable-sweep / --disable-sweep / --older-than / --sweep: the nightly sweep and its settings.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
source "$REPO/tests/lib/scratch-mysql.sh"
source "$REPO/tests/lib/cleanup-fixtures.sh"

scratch_mysql_start
trap 'release_connection; scratch_mysql_stop' EXIT
cleanup_fixture_env
CLEANUP="$REPO/bin/cleanup"
SWEEP_LOG="$LOG_DIR/cleanup-sweep.log"

# sweep_cast : one database for every way the sweep must treat a database.
sweep_cast() {
	reset_fixtures
	mk_db old_a_single_0 test_options;    age_db old_a_single_0 49       # sweepable, past 48 h
	mk_db young_b_single_0 test_options;  age_db young_b_single_0 47     # sweepable, not old enough
	mk_db pinned_c_single_0 test_options; age_db pinned_c_single_0 100   # old but pinned
	mk_db held_d_single_0 test_options;   age_db held_d_single_0 100     # old but connected
	age_db other_tool_single_0 100      # lane suffix, wp_ options: not sweepable
	age_db suite_odd_lane_0 100         # test options, no lane suffix: not sweepable
	age_db scratch_notes 100            # unknown
	age_db site_one_db 100              # owned
	"$CLEANUP" --pin pinned_c > /dev/null
}
exists() { [ -n "$(scratch_sql "SHOW DATABASES LIKE '$1'")" ]; }

# sweep_is_silent_and_inert_when_disabled
sweep_cast
out="$("$CLEANUP" --sweep)"; rc=$?
assert_eq 0 "$rc" "disabled: exits 0"
assert_eq "" "$out" "disabled: prints nothing"
assert_eq "yes" "$(exists old_a_single_0 && echo yes || echo no)" "disabled: the old lane is still there"
assert_eq "no" "$([ -e "$SWEEP_LOG" ] && echo yes || echo no)" "disabled: no sweep log written"

# the listing says what tonight's sweep would drop once it is on (a held connection protects its run)
"$CLEANUP" --enable-sweep > /dev/null
hold_connection held_d_single_0 9
listing="$("$CLEANUP" --json)"
assert_jq true '.sweep.enabled' "$listing" "settings: --enable-sweep switches it on"
assert_jq 48 '.sweep.older_than_hours' "$listing" "settings: threshold still 48 hours"
assert_jq '["old_a"]' '.sweep.next | tostring' "$listing" "listing: only the old, unpinned, unlocked, sweepable run is next"

# sweep_drops_only_old_sweepable_lane_with_test_options
out="$("$CLEANUP" --sweep --json)"; rc=$?
release_connection
assert_eq 0 "$rc" "sweep: exits 0"
assert_jq '["old_a_single_0"]' '[.dropped[].name] | tostring' "$out" "sweep: drops exactly the old sweepable lane"
assert_eq "no" "$(exists old_a_single_0 && echo yes || echo no)" "sweep: old lane gone"
assert_eq "yes" "$(exists young_b_single_0 && echo yes || echo no)" "sweep: 47 h lane kept"
assert_eq "yes" "$(exists other_tool_single_0 && echo yes || echo no)" "sweep: lane suffix without test options kept"
assert_eq "yes" "$(exists suite_odd_lane_0 && echo yes || echo no)" "sweep: test options without lane suffix kept"
assert_eq "yes" "$(exists scratch_notes && echo yes || echo no)" "sweep: unknown kept"
assert_eq "yes" "$(exists pinned_c_single_0 && echo yes || echo no)" "sweep: pinned kept"
assert_eq "yes" "$(exists held_d_single_0 && echo yes || echo no)" "sweep: connected kept"
assert_eq "yes" "$(exists site_one_db && echo yes || echo no)" "sweep: owned kept"
assert_match 'old_a_single_0 [0-9]+' "$(cat "$SWEEP_LOG" 2> /dev/null)" "sweep: the drop is logged with name and bytes"
assert_match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$(cat "$SWEEP_LOG" 2> /dev/null)" "sweep: the log line starts with an ISO time"

# older_than_setting_changes_threshold
"$CLEANUP" --older-than 1 > /dev/null
assert_jq true '.sweep.next | index("young_b") != null' "$("$CLEANUP" --json)" "threshold: --older-than 1 makes the 47 h run sweepable"
out="$("$CLEANUP" --sweep --json)"
assert_jq true '[.dropped[].name] | index("young_b_single_0") != null' "$out" "threshold: and the sweep drops it"
assert_jq true '[.dropped[].name] | index("other_tool_single_0") == null and index("scratch_notes") == null and index("pinned_c_single_0") == null' "$out" "threshold: a lower threshold still never reaches non-sweepable, unknown or pinned"
"$CLEANUP" --older-than 48 > /dev/null

# sweep_dry_run_lists_without_dropping, and listing_sweep_next_matches_what_sweep_drops
mk_db old_e_single_0 test_options; age_db old_e_single_0 60
next="$("$CLEANUP" --json | jq -c '[.sweep.next[] | . + "_single_0"] | sort')"
out="$("$CLEANUP" --sweep --dry-run --json)"
assert_jq true '.dry_run' "$out" "dry run: flagged"
assert_eq "$next" "$(printf '%s' "$out" | jq -c '[.dropped[].name] | sort')" "dry run: lists exactly the runs the listing calls next"
assert_eq "yes" "$(exists old_e_single_0 && echo yes || echo no)" "dry run: nothing dropped"
out="$("$CLEANUP" --sweep --json)"
assert_eq "$next" "$(printf '%s' "$out" | jq -c '[.dropped[].name] | sort')" "sweep: drops exactly what the listing called next"

# --disable-sweep makes the sweep inert again
mk_db old_f_single_0 test_options; age_db old_f_single_0 60
"$CLEANUP" --disable-sweep > /dev/null
out="$("$CLEANUP" --sweep)"
assert_eq "" "$out" "disabled again: prints nothing"
assert_eq "yes" "$(exists old_f_single_0 && echo yes || echo no)" "disabled again: nothing dropped"
assert_jq 48 '.sweep.older_than_hours' "$("$CLEANUP" --json)" "settings survive: the threshold is still 48"

# older_than_rejects_non_numbers
assert_status 2 "older-than abc exits 2" "$CLEANUP" --older-than abc
assert_status 2 "older-than 0 exits 2" "$CLEANUP" --older-than 0
assert_status 2 "older-than with no value exits 2" "$CLEANUP" --older-than

test_summary
