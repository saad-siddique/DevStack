#!/usr/bin/env bash
# run.sh [name-filter] : runs every tests/*.test.sh in its own bash, one line each; non-zero if any failed.
# Tests start a throwaway mysqld on port 33999 (tests/lib/scratch-mysql.sh); the live MySQL is never touched.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
rc=0
for t in *.test.sh; do
	[ -f "$t" ] || continue
	case "$t" in (*"${1:-}"*) ;; (*) continue ;; esac
	if out="$(bash "$t" 2>&1)"; then
		printf '%-24s PASS  %s\n' "${t%.test.sh}" "$(printf '%s\n' "$out" | tail -1 | sed 's/^ *//')"
	else
		printf '%-24s FAIL\n%s\n' "${t%.test.sh}" "$out" | sed 's/^/    /'
		rc=1
	fi
done
exit "$rc"
