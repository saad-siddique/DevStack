#!/usr/bin/env bash
# Smoke: the scratch MySQL starts, mysql_new follows MYSQL_SOCK, mysql_datadir answers.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
source "$REPO/tests/lib/scratch-mysql.sh"

scratch_mysql_start
trap scratch_mysql_stop EXIT
scratch_sql "CREATE DATABASE smoke_db" > /dev/null
source "$REPO/bin/lib.sh"

assert_eq "smoke_db" "$(mysql_new -N -e "SHOW DATABASES LIKE 'smoke_db'")" "mysql_new follows MYSQL_SOCK"
assert_match '/$' "$(mysql_datadir)" "datadir ends with a slash"
assert_eq "$MYSQL_DATADIR/" "$(mysql_datadir)" "mysql_datadir is the scratch data folder"
test_summary
