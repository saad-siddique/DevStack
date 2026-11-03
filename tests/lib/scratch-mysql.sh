# A throwaway MySQL 8.4 for tests. Source, do not execute. The live MySQL is never touched.
#   scratch_mysql_start : initialise a data folder under a fresh $SCRATCH_ROOT, start the server, export MYSQL_SOCK,
#                         MYSQL_DATADIR, SCRATCH_ROOT, MYSQLD_BIN and BREW_PREFIX
#   scratch_mysql_stop  : shut it down and delete everything (also run it from `trap … EXIT`)
#   scratch_sql <sql>   : run SQL as root, tab-separated without headers
# The socket lives under $HOME because macOS caps socket paths at 104 characters; the port is 33999.

SCRATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scratch_mysql_start() {
	BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix)}"
	SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devstack-test.XXXXXX")"
	MYSQL_SOCK="$HOME/.devstack-test.sock"
	MYSQL_DATADIR="$SCRATCH_ROOT/data"
	MYSQLD_BIN="$SCRATCH_LIB_DIR/scratch-mysqld"
	export BREW_PREFIX SCRATCH_ROOT MYSQL_SOCK MYSQL_DATADIR MYSQLD_BIN
	rm -f "$MYSQL_SOCK"
	"$MYSQLD_BIN" --initialize-insecure --datadir="$MYSQL_DATADIR" --log-error="$SCRATCH_ROOT/init.log" \
		|| { echo "scratch mysqld: initialise failed" >&2; tail -5 "$SCRATCH_ROOT/init.log" >&2; return 1; }
	"$MYSQLD_BIN" --datadir="$MYSQL_DATADIR" --log-error="$SCRATCH_ROOT/err.log" < /dev/null > /dev/null 2>&1 &
	local i
	for i in $(seq 1 60); do
		"$BREW_PREFIX/opt/mysql@8.4/bin/mysqladmin" --no-defaults -uroot -S "$MYSQL_SOCK" ping > /dev/null 2>&1 && return 0
		sleep 1
	done
	echo "scratch mysqld did not start" >&2; tail -5 "$SCRATCH_ROOT/err.log" >&2
	return 1
}

scratch_mysql_stop() {
	local i
	"$BREW_PREFIX/opt/mysql@8.4/bin/mysqladmin" --no-defaults -uroot -S "$MYSQL_SOCK" shutdown > /dev/null 2>&1 || true
	for i in $(seq 1 30); do [ -S "$MYSQL_SOCK" ] || break; sleep 1; done
	rm -f "$MYSQL_SOCK"
	[ -n "${SCRATCH_ROOT:-}" ] && rm -rf "$SCRATCH_ROOT"
	return 0
}

scratch_sql() { "$BREW_PREFIX/opt/mysql@8.4/bin/mysql" --no-defaults -uroot -S "$MYSQL_SOCK" -N -e "$1"; }
