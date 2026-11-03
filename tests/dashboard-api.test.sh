#!/usr/bin/env bash
# dashboard/index.php routes for cleanup and mysql-compact, served by PHP's built-in server. Server A runs on the real HOME
# and only reads (a listing, validation failures, a dry run of a name that does not exist). Server B runs on a temporary
# HOME with a fake compaction state file, so finish/rollback/start-gating are tested without touching any MySQL.
# Nothing here drops a database, compacts MySQL or starts a compaction.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix)}"
PORT_A="${DASHBOARD_TEST_PORT:-8099}"; PORT_B=$((PORT_A + 1))
T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-api-test.XXXXXX")"
HOME_B="$T/home"; STATE_B="$HOME_B/.local/share/devstack"
mkdir -p "$STATE_B" "$HOME_B/Library/Logs/DevStack"
"$BREW_PREFIX/bin/php" -S "127.0.0.1:$PORT_A" -t "$REPO/dashboard" > "$T/php-a.log" 2>&1 &
PID_A=$!; disown "$PID_A"
HOME="$HOME_B" "$BREW_PREFIX/bin/php" -S "127.0.0.1:$PORT_B" -t "$REPO/dashboard" > "$T/php-b.log" 2>&1 &
PID_B=$!; disown "$PID_B"
trap 'kill "$PID_A" "$PID_B" 2> /dev/null; rm -rf "$T"' EXIT
for p in "$PORT_A" "$PORT_B"; do
	for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$p/favicon.png" && break; sleep 0.25; done
done

# call <port> <method> <query> [curl args...] : sets CODE and BODY
call() {
	local port="$1" method="$2" query="$3"
	shift 3
	CODE="$(curl -s -o "$T/body" -w '%{http_code}' -X "$method" "$@" "http://127.0.0.1:$port/?$query")"
	BODY="$(cat "$T/body")"
}
H=(-H 'X-Devstack: 1')

# get_cleanup_returns_listing_shape (read-only against the real MySQL)
call "$PORT_A" GET api=cleanup
assert_eq 200 "$CODE" "GET cleanup: 200"
assert_jq array '.runs | type' "$BODY" "GET cleanup: runs is a list"
assert_jq object '.mysql | type' "$BODY" "GET cleanup: mysql summary present"
assert_jq object '.sweep | type' "$BODY" "GET cleanup: sweep settings present"
assert_jq array '.pinned | type' "$BODY" "GET cleanup: pinned list present"

# header, validation and unknown operations
call "$PORT_A" POST api=cleanup --data-urlencode op=pin --data-urlencode 'names[]=x'
assert_eq 403 "$CODE" "POST without X-Devstack is 403"
call "$PORT_A" POST api=cleanup "${H[@]}" --data-urlencode op=drop --data-urlencode 'names[]=a;b'
assert_eq 400 "$CODE" "drop with a bad name is 400"
call "$PORT_A" POST api=cleanup "${H[@]}" --data-urlencode op=drop
assert_eq 400 "$CODE" "drop with no names is 400"
call "$PORT_A" POST api=cleanup "${H[@]}" --data-urlencode op=pin --data-urlencode 'names[]=-x'
assert_eq 400 "$CODE" "a name starting with a hyphen is 400 (it would read as a flag)"
call "$PORT_A" POST api=cleanup "${H[@]}" --data-urlencode op=bogus
assert_eq 400 "$CODE" "unknown op is 400"
call "$PORT_A" POST api=cleanup "${H[@]}" --data-urlencode op=sweep --data-urlencode value=abc
assert_eq 400 "$CODE" "sweep with a bad value is 400"

# post_drop_dry_run_changes_nothing (a name that does not exist, so nothing could change anyway)
call "$PORT_A" POST api=cleanup "${H[@]}" --data-urlencode op=drop --data-urlencode 'names[]=devstack_api_test_nothing' --data-urlencode dry_run=1
assert_eq 200 "$CODE" "dry-run drop: 200"
assert_jq devstack_api_test_nothing '.already_gone[0]' "$BODY" "dry-run drop: reported as already gone"
assert_jq true '.dry_run' "$BODY" "dry-run drop: flagged as a dry run"

# mysql-compact: idle on the real HOME
call "$PORT_A" GET api=mysql-compact
assert_eq 200 "$CODE" "GET mysql-compact: 200"
assert_eq '{"step":null,"done":false}' "$(printf '%s' "$BODY" | jq -c '{step, done}')" "GET mysql-compact: idle"
call "$PORT_A" POST api=mysql-compact --data-urlencode op=finish
assert_eq 403 "$CODE" "mysql-compact POST without X-Devstack is 403"
call "$PORT_A" POST api=mysql-compact "${H[@]}" --data-urlencode op=bogus
assert_eq 400 "$CODE" "mysql-compact unknown op is 400"

# server B (temporary HOME): no state, then a fake finished-verify state
call "$PORT_B" POST api=mysql-compact "${H[@]}" --data-urlencode op=rollback
assert_eq 409 "$CODE" "rollback with nothing to roll back is 409"
call "$PORT_B" POST api=mysql-compact "${H[@]}" --data-urlencode op=finish
assert_eq 409 "$CODE" "finish with nothing to finish is 409"
mkdir -p "$T/fake-old-folder"
printf '{"step":"verify","done":false,"old_datadir":"%s"}\n' "$T/fake-old-folder" > "$STATE_B/mysql-compact.json"
call "$PORT_B" GET api=mysql-compact
assert_jq verify '.step' "$BODY" "GET mysql-compact: reports the stored step"
call "$PORT_B" POST api=mysql-compact "${H[@]}" --data-urlencode op=start
assert_eq 409 "$CODE" "start while a compaction waits for finish or rollback is 409 and spawns nothing"
assert_eq "no" "$([ -e "$HOME_B/Library/Logs/DevStack/mysql-compact.log" ] && echo yes || echo no)" "start gate: no process was spawned"
call "$PORT_B" POST api=mysql-compact "${H[@]}" --data-urlencode op=finish
assert_eq 200 "$CODE" "finish: 200"
assert_eq "no" "$([ -d "$T/fake-old-folder" ] && echo yes || echo no)" "finish: the old folder is deleted"
call "$PORT_B" GET api=mysql-compact
assert_jq true '.done' "$BODY" "finish: status says done"

assert_status 0 "php -l dashboard/index.php" "$BREW_PREFIX/bin/php" -l "$REPO/dashboard/index.php"
test_summary
