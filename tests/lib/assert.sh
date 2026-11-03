# Tiny assertions for tests/*.test.sh. Source, do not execute. Expected value always comes first (Yoda).
PASS=0; FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3" >&2; }

# assert_eq <expected> <actual> <label>
assert_eq() { if [ "$1" = "$2" ]; then _pass; else _fail "$3" "$1" "$2"; fi; }

# assert_match <extended regex> <actual> <label>
assert_match() { if printf '%s' "$2" | grep -Eq -- "$1"; then _pass; else _fail "$3" "matches /$1/" "$2"; fi; }

# assert_status <expected exit code> <label> <command...> : output is discarded.
assert_status() {
	local want="$1" label="$2" rc=0
	shift 2
	"$@" > /dev/null 2>&1 || rc=$?
	assert_eq "$want" "$rc" "$label"
}

# assert_jq <expected> <jq filter> <json> <label> : compares the filter's raw output.
assert_jq() { assert_eq "$1" "$(printf '%s' "$3" | jq -r "$2" 2> /dev/null || echo "<jq error>")" "$4"; }

# test_summary : prints the counts as the last line (tests/run.sh shows it) and fails the script on any failure.
test_summary() {
	printf '%d passed, %d failed\n' "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}
