# Shared fixtures for the cleanup tests. Source after assert.sh and scratch-mysql.sh, with the scratch server running.
# Names are placeholders on purpose: the repo is public.

# mk_db <name> <options-table> : a schema holding one table of that name (an options table marks a WordPress database).
mk_db() { scratch_sql "CREATE DATABASE \`$1\`; CREATE TABLE \`$1\`.\`$2\` (option_id INT PRIMARY KEY) ENGINE=InnoDB" > /dev/null; }

# fs_name <db> : MySQL stores a schema's folder with every character outside [A-Za-z0-9_] as @ and four hex digits.
fs_name() { printf '%s' "$1" | sed 's/-/@002d/g'; }

# wait_flushed : until InnoDB has no dirty pages. A flush after age_db's touch would refresh the mtimes it set.
wait_flushed() {
	local i
	for i in $(seq 1 60); do
		[ "0" = "$(scratch_sql "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_dirty'" | awk '{ print $2 }')" ] && return 0
		sleep 1
	done
	return 1
}

# age_db <name> <hours> : push every table file back in time so the database reads as idle (UPDATE_TIME stays NULL
# for tables that were only created).
age_db() {
	local ts; ts="$(date -v-"$2"H +%Y%m%d%H%M.%S)"
	wait_flushed
	find "$MYSQL_DATADIR/$(fs_name "$1")" -name '*.ibd' -exec touch -t "$ts" {} +
}

# hold_connection <db> <seconds> : a background client sitting inside the database; HELD_PID is its pid.
hold_connection() {
	"$BREW_PREFIX/opt/mysql@8.4/bin/mysql" --no-defaults -uroot -S "$MYSQL_SOCK" -e "SELECT SLEEP($2)" "$1" > /dev/null 2>&1 &
	HELD_PID=$!
	sleep 1   # let the connection register in the process list
}
# release_connection : wait for the held client to finish (killing it leaves its SLEEP running server-side, still locking).
release_connection() { wait "${HELD_PID:-0}" 2> /dev/null || true; HELD_PID=0; }

# cleanup_fixture_env : point every devstack path at the scratch root; one linked site, one dangling link, one folder
# that is not WordPress, and an inventory row whose database no site links.
cleanup_fixture_env() {
	export VALET_HOME="$SCRATCH_ROOT/valet" SITES_TSV="$SCRATCH_ROOT/sites.tsv" DATA_DIR="$SCRATCH_ROOT/data-dir"
	export LOG_DIR="$SCRATCH_ROOT/logs" BACKUP_ROOT="$SCRATCH_ROOT/backups"
	mkdir -p "$VALET_HOME/Sites" "$DATA_DIR" "$LOG_DIR" "$SCRATCH_ROOT/sitefolders/site-one" "$SCRATCH_ROOT/sitefolders/plain"
	cat > "$SCRATCH_ROOT/sitefolders/site-one/wp-config.php" <<'PHP'
<?php
define( 'DB_NAME', 'site_one_db' );
PHP
	ln -sfn "$SCRATCH_ROOT/sitefolders/site-one" "$VALET_HOME/Sites/site-one"
	ln -sfn "$SCRATCH_ROOT/sitefolders/plain" "$VALET_HOME/Sites/plain"
	ln -sfn "$SCRATCH_ROOT/missing-folder" "$VALET_HOME/Sites/ghost"
	printf '# host\tfolder\tphp\tdb\tprotected\tnotes\ninv.test\tinv\t8.4\tinv_only_db\tyes\t\n' > "$SITES_TSV"
}

# reset_fixtures : drop every non-system schema and the settings file, then make the standard cast again.
reset_fixtures() {
	local d
	for d in $(scratch_sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema')"); do
		scratch_sql "DROP DATABASE \`$d\`" > /dev/null
	done
	rm -rf "$DATA_DIR/cleanup.json" "$BACKUP_ROOT"
	make_fixtures
}

# gone <name> : true when no schema of that name exists.
gone() { [ -z "$(scratch_sql "SHOW DATABASES LIKE '$1'")" ]; }

# make_fixtures : the standard cast, all two hours idle.
make_fixtures() {
	local d
	mk_db suite_pr1_final_single_0 test_options
	mk_db suite_pr1_final_single_1 test_options
	mk_db other_tool_single_0 wp_options
	mk_db suite_odd_lane_0 test_options
	mk_db scratch_notes notes
	mk_db hyphen-db_single_0 test_options
	mk_db site_one_db wp_options
	mk_db inv_only_db wp_options
	for d in suite_pr1_final_single_0 suite_pr1_final_single_1 other_tool_single_0 suite_odd_lane_0 scratch_notes hyphen-db_single_0 site_one_db inv_only_db; do
		age_db "$d" 2
	done
}
