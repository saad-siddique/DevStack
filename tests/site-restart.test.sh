#!/usr/bin/env bash
# bin/site-restart: one site's php-fpm workers are reset, every other site's are not. php-fpm has one pool per PHP
# version shared by all its sites, so "restart a site" means: kill the workers that are serving it right now (the
# master respawns them) and optionally flush its object cache. Stand-ins for php-fpm are real processes that carry
# "php-fpm" in their command line and sit in a site folder, under a parent that does too; PHP and WP-CLI are stubs.
# Nothing here touches the live stack.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-restart-test.XXXXXX")"
PIDS="$T/pids"; : > "$PIDS"
# Every pool this test starts leaves its workers behind when its master is killed (they are not reparented to php-fpm):
# ALL remembers the pids and masters of the pools already replaced, so the exit trap can kill every one of them.
ALL="$T/all-pids"; : > "$ALL"
cleanup() {
	cat "$ALL" "$PIDS" | while read -r _ p; do kill -KILL "$p" 2> /dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT

# Sites: alpha (WordPress, with an admin subfolder), alpha-2 (shares alpha's name as a prefix), beta (not WordPress).
mkdir -p "$T/valet/Sites" "$T/sites/alpha/wp-admin" "$T/sites/alpha-2" "$T/sites/beta"
touch "$T/sites/alpha/wp-config.php"
for s in alpha alpha-2 beta; do ln -s "$T/sites/$s" "$T/valet/Sites/$s"; done
# Stubs for PHP and WP-CLI: the stub php records its arguments and exits with $STUB_PHP_RC.
mkdir -p "$T/brew/bin" "$T/brew/opt/php@8.4/bin"
printf '#!/bin/sh\n' > "$T/brew/bin/wp"; chmod +x "$T/brew/bin/wp"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/php-calls"\nexit "${STUB_PHP_RC:-0}"\n' "$T" > "$T/brew/opt/php@8.4/bin/php"
chmod +x "$T/brew/opt/php@8.4/bin/php"

# A fake pool: master.sh forks one worker per <label>=<dir>, each a "php-fpm: pool test" process in that folder.
# A label starting with "stubborn" ignores SIGTERM (an ignored signal survives exec).
cat > "$T/master.sh" <<'EOF'
#!/bin/bash
pf="$1"; shift
for spec in "$@"; do
	label="${spec%%=*}"; dir="${spec#*=}"
	( case "$label" in (stubborn*) trap '' TERM ;; esac; cd "$dir" && exec -a "php-fpm: pool test" sleep 300 ) &
	echo "$label $!" >> "$pf"
done
wait
EOF
alive() { local s; s="$(ps -o stat= -p "$1" 2> /dev/null | tr -d ' ')"; [ -n "$s" ] && [ "Z" != "${s:0:1}" ]; }
pid_of() { awk -v l="$1" '$1 == l { p = $2 } END { print p }' "$PIDS"; }
state() { if alive "$(pid_of "$1")"; then echo alive; else echo dead; fi; }
start_pool() {
	cat "$PIDS" >> "$ALL"; : > "$PIDS"
	bash -c 'exec -a "php-fpm: master process (test)" bash "$@"' _ "$T/master.sh" "$PIDS" "$@" < /dev/null > /dev/null 2>&1 &
	MASTER=$!; disown "$MASTER"; echo "master $MASTER" >> "$ALL"
	local want=$# i
	for i in $(seq 1 50); do [ "$(wc -l < "$PIDS" | tr -d ' ')" -ge "$want" ] && break; sleep 0.1; done
}
run() { VALET_HOME="$T/valet" BREW_PREFIX="$T/brew" SITE_RESTART_GRACE=1 "$REPO/bin/site-restart" "$@"; }

# 1. only the named site's workers go; a worker in a subfolder counts; a name that is a prefix, an idle worker, another
#    site and a non-php-fpm process in the same folder all stay.
start_pool "a_root=$T/sites/alpha" "a_admin=$T/sites/alpha/wp-admin" "a2=$T/sites/alpha-2" "b=$T/sites/beta" "idle=$T"
( cd "$T/sites/alpha" && exec -a "wp-cli-job" sleep 301 ) < /dev/null > /dev/null 2>&1 &
CLI=$!; disown "$CLI"
out="$(run alpha --json 2> "$T/err")"; rc=$?
assert_eq 0 "$rc" "restart alpha: exit 0 ($(cat "$T/err"))"
assert_eq dead "$(state a_root)" "alpha's worker in the site root is killed"
assert_eq dead "$(state a_admin)" "alpha's worker in wp-admin is killed"
assert_eq alive "$(state a2)" "alpha-2 shares alpha's name as a prefix and is left alone"
assert_eq alive "$(state b)" "beta's worker is left alone"
assert_eq alive "$(state idle)" "an idle worker (no site folder) is left alone"
assert_eq yes "$(alive "$CLI" && echo yes || echo no)" "a process in alpha's folder that is not a php-fpm worker is left alone"
assert_jq alpha '.site' "$out" "json: site"
assert_jq 'php@8.4' '.php' "$out" "json: PHP formula (no .valetrc means the default)"
assert_jq 2 '.killed | length' "$out" "json: two workers reset"
assert_jq "$(pid_of a_root)" '[.killed[].pid] | map(select(. == '"$(pid_of a_root)"')) | .[0]' "$out" "json: lists the pid it killed"
assert_jq skipped '.cache' "$out" "json: no --cache, no flush"
assert_jq true '.ok' "$out" "json: ok"
kill -KILL "$CLI" 2> /dev/null

# 2. a second run with nothing busy is still a success and says so.
out="$(run alpha --json 2> /dev/null)"; rc=$?
assert_eq 0 "$rc" "restart alpha again, nothing running for it: exit 0"
assert_jq 0 '.killed | length' "$out" "json: nothing to reset"
assert_match 'nothing' "$(run alpha 2>&1)" "plain output says nothing was running"

# 3. a worker that ignores SIGTERM is killed after the grace period.
kill -KILL "$MASTER" 2> /dev/null
start_pool "stubborn=$T/sites/alpha"
t0="$(date +%s)"
run alpha > /dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "stubborn worker: exit 0"
assert_eq dead "$(state stubborn)" "a worker that ignores SIGTERM is killed with SIGKILL after the grace period"
assert_match '^[0-4]$' "$(( $(date +%s) - t0 ))" "...within a few seconds"
kill -KILL "$MASTER" 2> /dev/null

# 4. unknown sites and bad names are refused, and nothing is killed.
start_pool "a_root=$T/sites/alpha"
assert_status 1 "unknown site: exit 1" run nosuch
assert_match 'not a linked site' "$(run nosuch 2>&1)" "unknown site: says so"
assert_status 1 "a path as a name: exit 1" run ../sites/alpha
assert_status 1 "no name: exit 1" run
assert_status 1 "unknown flag: exit 1" run alpha --bogus
assert_eq alive "$(state a_root)" "refused runs kill nothing"

# 5. --cache needs a WordPress site, and says so before it kills anything.
start_pool "a_root=$T/sites/alpha" "b=$T/sites/beta"
assert_status 1 "--cache on a site without wp-config.php: exit 1" run beta --cache
assert_match 'WordPress' "$(run beta --cache 2>&1)" "--cache on a non-WordPress site: says why"
assert_eq alive "$(state b)" "...and its worker is still alive"

# 6. --cache flushes the object cache through WP-CLI under the site's PHP, after the workers are reset.
: > "$T/php-calls"
out="$(run alpha --cache --json 2> /dev/null)"; rc=$?
assert_eq 0 "$rc" "--cache: exit 0"
assert_eq dead "$(state a_root)" "--cache: workers still reset"
assert_jq flushed '.cache' "$out" "--cache: json says flushed"
assert_match "--path=$T/sites/alpha .*cache flush" "$(cat "$T/php-calls")" "--cache: wp cache flush ran against the site"

# 7. a failed flush is reported and exits 1, but the workers were already reset.
kill -KILL "$MASTER" 2> /dev/null
start_pool "a_root=$T/sites/alpha"
out="$(STUB_PHP_RC=1 run alpha --cache --json 2> /dev/null)"; rc=$?
assert_eq 1 "$rc" "failed flush: exit 1"
assert_jq failed '.cache' "$out" "failed flush: json says failed"
assert_jq false '.ok' "$out" "failed flush: not ok"
assert_eq dead "$(state a_root)" "failed flush: the workers were reset anyway"

# 8. devstack restart <site> is this command; devstack restart alone is still the whole stack.
err="$(VALET_HOME="$T/valet" BREW_PREFIX="$T/brew" "$REPO/bin/devstack" restart nosuch 2>&1)"; rc=$?
assert_eq 1 "$rc" "devstack restart <site>: routed to site-restart (exit 1 for an unknown site)"
assert_match 'not a linked site' "$err" "devstack restart <site>: site-restart answered"
# (a flag as the first argument is stack-restart's; its argument check dies before it touches any service)
assert_match 'usage: stack-restart' "$(VALET_HOME="$T/valet" BREW_PREFIX="$T/brew" "$REPO/bin/devstack" restart --bogus 2>&1)" "devstack restart --flag: still the whole-stack command"

test_summary
