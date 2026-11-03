#!/usr/bin/env bash
# bin/mysql-compact: reclaim mysql.ibd by dump, re-initialise, restore. Runs only against the scratch mysqld.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
source "$REPO/tests/lib/scratch-mysql.sh"
source "$REPO/tests/lib/cleanup-fixtures.sh"

scratch_mysql_start
trap 'release_connection; scratch_mysql_stop' EXIT
cleanup_fixture_env
export MYSQL_STOP_CMD="$REPO/tests/lib/scratch-mysql-stop" MYSQL_START_CMD="$REPO/tests/lib/scratch-mysql-start"
COMPACT="$REPO/bin/mysql-compact"
MYSQL_CLIENT="$BREW_PREFIX/opt/mysql@8.4/bin/mysql"

SYS="'mysql','sys','information_schema','performance_schema'"
counts() { scratch_sql "SELECT (SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ($SYS)), (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ($SYS)), (SELECT COUNT(*) FROM mysql.user)"; }
ibd_size() { stat -f %z "$MYSQL_DATADIR/mysql.ibd"; }
server_up() { "$BREW_PREFIX/opt/mysql@8.4/bin/mysqladmin" --no-defaults -uroot -S "$MYSQL_SOCK" ping > /dev/null 2>&1; }
old_folders() { ls -d "$MYSQL_DATADIR".before-compact-* 2> /dev/null | wc -l | tr -d ' '; }

seed_small() {
	scratch_sql "CREATE DATABASE keep1; CREATE TABLE keep1.t (id INT PRIMARY KEY, v VARCHAR(50)); INSERT INTO keep1.t VALUES (1,'one'),(2,'two');
		CREATE DATABASE keep2; CREATE TABLE keep2.t (id INT PRIMARY KEY);
		CREATE DATABASE keep3; CREATE TABLE keep3.t (id INT PRIMARY KEY, b BLOB); INSERT INTO keep3.t VALUES (1, REPEAT('x', 50000));
		CREATE USER 'wp_keep1'@'localhost' IDENTIFIED BY 'pw-one'; CREATE USER 'wp_keep1'@'127.0.0.1' IDENTIFIED BY 'pw-one';
		GRANT ALL ON keep1.* TO 'wp_keep1'@'localhost', 'wp_keep1'@'127.0.0.1';
		CREATE USER 'wp_keep2'@'localhost' IDENTIFIED BY 'pw-two'; GRANT ALL ON keep2.* TO 'wp_keep2'@'localhost'" > /dev/null
}
# churn : create and drop 60 schemas x 30 tables so mysql.ibd grows past a fresh one.
churn() {
	awk 'BEGIN { for (i = 1; i <= 60; i++) { printf "CREATE DATABASE cyc_%d;\n", i; for (k = 1; k <= 30; k++) printf "CREATE TABLE cyc_%d.t%d (id bigint unsigned auto_increment primary key, a varchar(191) not null default \"\", b longtext, c datetime null, key a (a), key c (c)) ENGINE=InnoDB;\n", i, k } }' > "$SCRATCH_ROOT/create.sql"
	awk 'BEGIN { for (i = 1; i <= 60; i++) printf "DROP DATABASE cyc_%d;\n", i }' > "$SCRATCH_ROOT/drop.sql"
	"$MYSQL_CLIENT" --no-defaults -uroot -S "$MYSQL_SOCK" < "$SCRATCH_ROOT/create.sql"
	"$MYSQL_CLIENT" --no-defaults -uroot -S "$MYSQL_SOCK" < "$SCRATCH_ROOT/drop.sql"
}
# fresh_server : a new scratch server holding only the small data set.
fresh_server() { scratch_mysql_stop; scratch_mysql_start; cleanup_fixture_env; seed_small; }
login_ok() { "$MYSQL_CLIENT" --no-defaults -uwp_keep1 -ppw-one -S "$MYSQL_SOCK" -N -e "SELECT COUNT(*) FROM keep1.t" 2> /dev/null; }

# compact_requires_yes, compact_refuses_when_disk_too_low, compact_refuses_with_other_connections
seed_small
assert_status 2 "requires yes: no --yes exits 2" "$COMPACT"
assert_status 2 "requires yes: --stop-after alone still exits 2" "$COMPACT" --stop-after dump
out="$(COMPACT_FREE_BYTES=1000 "$COMPACT" --yes 2>&1)"; rc=$?
assert_eq 1 "$rc" "disk: refuses when free space is below the requirement"
assert_match 'needs [0-9]+ bytes' "$out" "disk: the message prints the number it needs"
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.json" ] && echo yes || echo no)" "disk: refusal leaves no state file"
hold_connection keep1 8
out="$("$COMPACT" --yes 2>&1)"; rc=$?
release_connection
assert_eq 1 "$rc" "connections: refuses while another client is connected"
assert_match 'connected' "$out" "connections: says why"
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.json" ] && echo yes || echo no)" "connections: no state file"
assert_eq "yes" "$(server_up && echo yes || echo no)" "connections: the server was not touched"
assert_eq '{"step":null,"done":false}' "$("$COMPACT" --status --json | jq -c '{step, done}')" "status: idle when nothing started"

# compact_refuses_a_second_concurrent_run, and a stale lock does not block
sleep 60 &
LIVE_PID=$!
echo "$LIVE_PID" > "$DATA_DIR/mysql-compact.lock"
out="$("$COMPACT" --yes --stop-after preflight 2>&1)"; rc=$?
kill "$LIVE_PID" 2> /dev/null; wait "$LIVE_PID" 2> /dev/null
assert_eq 1 "$rc" "lock: a second run is refused while the first holds the lock"
assert_match 'already running' "$out" "lock: says why"
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.json" ] && echo yes || echo no)" "lock: the refused run wrote no state"
echo 999999 > "$DATA_DIR/mysql-compact.lock"
"$COMPACT" --yes --stop-after preflight > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "lock: a lock left by a dead process does not block"
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.lock" ] && echo yes || echo no)" "lock: released when the run ends"
"$COMPACT" --rollback > /dev/null 2>&1
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.json" ] && echo yes || echo no)" "lock: state cleared again before the real runs"

# compact_reclaims_catalog_and_preserves_data
churn
before_counts="$(counts)"; before_size="$(ibd_size)"
out="$("$COMPACT" --yes --json 2>/dev/null)"; rc=$?
assert_eq 0 "$rc" "full run: exits 0"
assert_jq verify '.step' "$out" "full run: ends at the verify step"
assert_eq "1" "$(old_folders)" "full run: the old data folder is kept until --finish"
assert_eq "$before_counts" "$(counts)" "full run: schema, table and user counts equal the counts before"
assert_eq "2" "$(scratch_sql "SELECT COUNT(*) FROM keep1.t")" "full run: rows survive"
assert_eq "50000" "$(scratch_sql "SELECT LENGTH(b) FROM keep3.t")" "full run: a large value survives"
assert_eq "2" "$(login_ok)" "full run: a restored user logs in with its old password"
"$COMPACT" --finish > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "finish: exits 0"
assert_eq "0" "$(old_folders)" "finish: the old data folder is deleted"
assert_eq "true" "$([ "$(ibd_size)" -lt "$before_size" ] && echo true || echo false)" "full run: mysql.ibd is smaller than before ($before_size -> $(ibd_size))"
assert_jq true '.done' "$("$COMPACT" --status --json)" "finish: status says done"

# compact_resumes_after_interruption_at_every_step
for s in dump stop move init start restore; do
	fresh_server
	want="$(counts)"
	"$COMPACT" --yes --stop-after "$s" > /dev/null 2>&1; rc=$?
	assert_eq 0 "$rc" "resume after $s: --stop-after exits 0"
	assert_eq "$s" "$("$COMPACT" --status --json | jq -r '.step')" "resume after $s: status reports the step"
	"$COMPACT" --yes > /dev/null 2>&1; rc=$?
	assert_eq 0 "$rc" "resume after $s: re-running finishes the job"
	assert_jq verify '.step' "$("$COMPACT" --status --json)" "resume after $s: reached verify"
	assert_eq "$want" "$(counts)" "resume after $s: counts equal the counts before"
	assert_eq "2" "$(login_ok)" "resume after $s: a restored user logs in"
	"$COMPACT" --finish > /dev/null 2>&1
done

# compact_rolls_back_on_count_mismatch
fresh_server
scratch_sql "CREATE TABLE keep1.marker (id INT PRIMARY KEY); INSERT INTO keep1.marker VALUES (7)" > /dev/null
want="$(counts)"
out="$(COMPACT_TAMPER_PRE=1 "$COMPACT" --yes 2>&1)"; rc=$?
assert_eq 1 "$rc" "mismatch: exits 1"
assert_match 'rolled back|rollback' "$out" "mismatch: says it rolled back"
assert_eq "yes" "$(server_up && echo yes || echo no)" "mismatch: the original server answers again"
assert_eq "7" "$(scratch_sql "SELECT id FROM keep1.marker")" "mismatch: the original data is back (marker row)"
assert_eq "$want" "$(counts)" "mismatch: counts are the original counts"
assert_eq "0" "$(old_folders)" "mismatch: no leftover old folder"
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.json" ] && echo yes || echo no)" "mismatch: state file cleared"

# rollback_after_interruption_restores_old_folder
fresh_server
scratch_sql "CREATE TABLE keep1.marker (id INT PRIMARY KEY); INSERT INTO keep1.marker VALUES (9)" > /dev/null
"$COMPACT" --yes --stop-after move > /dev/null 2>&1
assert_eq "no" "$(server_up && echo yes || echo no)" "rollback: the server is down after the move step"
"$COMPACT" --rollback > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "rollback: exits 0"
assert_eq "yes" "$(server_up && echo yes || echo no)" "rollback: the original server answers"
assert_eq "9" "$(scratch_sql "SELECT id FROM keep1.marker")" "rollback: the original data is back"
assert_eq "0" "$(old_folders)" "rollback: no old folder left"
assert_eq "no" "$([ -e "$DATA_DIR/mysql-compact.json" ] && echo yes || echo no)" "rollback: state file cleared"
assert_status 1 "finish with nothing to finish exits 1" "$COMPACT" --finish

# Final review #1, scenario A: the server was never stopped after an interrupted dump, so resuming must start over with a
# fresh dump; restoring the old one would silently discard everything written in between.
fresh_server
"$COMPACT" --yes --stop-after dump > /dev/null 2>&1
assert_eq 0 "$(scratch_sql "SELECT @@super_read_only")" "stale dump: the write fence is released when the run stops cleanly"
scratch_sql "INSERT INTO keep1.t VALUES (3,'three')" > /dev/null; rc=$?
assert_eq 0 "$rc" "stale dump: writes work between an interrupted run and its resume"
"$COMPACT" --yes > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "stale dump: the resume completes"
assert_eq "3" "$(scratch_sql "SELECT COUNT(*) FROM keep1.t")" "stale dump: the row written after the interrupted dump survives the resume"
"$COMPACT" --finish > /dev/null 2>&1

# Final review #1, scenario B: a writer that arrives while the dump is running (a wp-admin tab, WP-Cron, a suite starting)
# must fail loudly, not be restored over. The hook runs a client right after the dump, before MySQL is stopped.
fresh_server
want="$(counts)"
COMPACT_HOOK_AFTER_DUMP="'$MYSQL_CLIENT' --no-defaults -uroot -S '$MYSQL_SOCK' -e \"INSERT INTO keep1.t VALUES (99,'late')\" > '$SCRATCH_ROOT/late.out' 2>&1; echo \$? > '$SCRATCH_ROOT/late.rc'" \
	"$COMPACT" --yes > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "late writer: the run still completes"
assert_eq "1" "$(cat "$SCRATCH_ROOT/late.rc" 2> /dev/null)" "late writer: the client's INSERT between dump and stop is refused"
assert_match 'read-only' "$(cat "$SCRATCH_ROOT/late.out" 2> /dev/null)" "late writer: with the read-only error"
assert_eq "0" "$(scratch_sql "SELECT COUNT(*) FROM keep1.t WHERE id = 99")" "late writer: nothing half-written was restored"
assert_eq "$want" "$(counts)" "late writer: counts equal the counts before"
assert_eq 0 "$(scratch_sql "SELECT @@super_read_only")" "late writer: the compacted server accepts writes"
"$COMPACT" --finish > /dev/null 2>&1

# Final review #5: a MySQL started by hand (or by brew services) after the stop step must stop the run before the data
# folder is moved under it.
fresh_server
"$COMPACT" --yes --stop-after stop > /dev/null 2>&1
"$MYSQL_START_CMD"
for _ in $(seq 1 60); do server_up && break; sleep 1; done
out="$("$COMPACT" --yes 2>&1)"; rc=$?
assert_eq 1 "$rc" "running server: the move step refuses"
assert_match 'running' "$out" "running server: says MySQL is running"
assert_eq "0" "$(old_folders)" "running server: no folder was moved"
assert_eq "yes" "$(server_up && echo yes || echo no)" "running server: the hand-started server was left alone"
assert_eq "2" "$(scratch_sql "SELECT COUNT(*) FROM keep1.t")" "running server: its data is intact"
"$MYSQL_STOP_CMD"
"$COMPACT" --yes > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "running server: once stopped again the run completes"
"$COMPACT" --finish > /dev/null 2>&1

# Final review #5, second half: whatever answers after the start step must be running on the NEW data folder.
fresh_server
scratch_sql "CREATE TABLE keep1.marker (id INT PRIMARY KEY); INSERT INTO keep1.marker VALUES (5)" > /dev/null
want="$(counts)"
cat > "$SCRATCH_ROOT/start-old" <<'SH'
#!/usr/bin/env bash
OLD="$(jq -r .old_datadir "$DATA_DIR/mysql-compact.json")"
"$MYSQLD_BIN" --datadir="$OLD" --log-error="$SCRATCH_ROOT/err-old.log" < /dev/null > /dev/null 2>&1 &
exit 0
SH
chmod +x "$SCRATCH_ROOT/start-old"
out="$(MYSQL_START_CMD="$SCRATCH_ROOT/start-old" "$COMPACT" --yes 2>&1)"; rc=$?
assert_eq 1 "$rc" "wrong server: the run stops"
assert_match 'not running on the new data folder' "$out" "wrong server: says the answering MySQL is on another folder"
"$COMPACT" --rollback > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "wrong server: rollback works"
assert_eq "5" "$(scratch_sql "SELECT id FROM keep1.marker")" "wrong server: the original data is back"
assert_eq "$want" "$(counts)" "wrong server: counts are the original counts"
assert_eq "0" "$(old_folders)" "wrong server: no old folder left"

test_summary
