#!/usr/bin/env bash
# bootstrap's ensure_cleanup_agent writes a valid LaunchAgent and reloads it only when it changed; doctor and uninstall
# know the agent. The function is extracted and run with HOME in a scratch folder and launchctl shadowed.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-agent-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PLIST="$T/Library/LaunchAgents/com.devstack.cleanup.plist"
{
	echo 'ok() { :; }; log() { :; }; warn() { :; }'
	echo 'launchctl() { echo "$*" >> "$LC_LOG"; return 0; }'
	sed -n '/^ensure_cleanup_agent() {/,/^}/p' "$REPO/bootstrap.sh"
	echo 'ensure_cleanup_agent'
} > "$T/run-agent.sh"
run_agent() { HOME="$T" REPO_DIR="$REPO" BREW_PREFIX=/opt/homebrew LC_LOG="$T/launchctl.log" bash "$T/run-agent.sh" 2>&1; }

out="$(run_agent)"; rc=$?
assert_eq 0 "$rc" "agent: the function runs (output: $out)"
assert_eq "yes" "$([ -f "$PLIST" ] && echo yes || echo no)" "agent: plist written under ~/Library/LaunchAgents"
assert_status 0 "agent: plist passes plutil -lint" plutil -lint "$PLIST"
plist="$(cat "$PLIST" 2> /dev/null)"
assert_match 'com\.devstack\.cleanup' "$plist" "agent: label"
assert_match "$REPO/bin/cleanup" "$plist" "agent: runs this repo's bin/cleanup"
assert_match '<string>--sweep</string>' "$plist" "agent: passes --sweep"
assert_match '<key>Hour</key><integer>3</integer>' "$plist" "agent: runs at hour 3"
assert_match '<key>Minute</key><integer>0</integer>' "$plist" "agent: minute 0"
assert_match 'devstack-cleanup\.log' "$plist" "agent: logs to devstack-cleanup.log"
assert_match 'bootstrap gui/' "$(cat "$T/launchctl.log" 2> /dev/null)" "agent: first run loads it"

: > "$T/launchctl.log"
run_agent > /dev/null
assert_eq 0 "$(grep -Ec 'bootout|bootstrap' "$T/launchctl.log")" "agent: a second run with an unchanged plist reloads nothing"

assert_eq 1 "$(grep -c '^ensure_cleanup_agent$' "$REPO/bootstrap.sh")" "bootstrap: ensure_cleanup_agent is called once"
assert_match 'logs-prune upgrade watchdog cleanup' "$(grep -h 'logs-prune upgrade watchdog' "$REPO/bin/doctor")" "doctor: checks the cleanup agent"
assert_match 'logs-prune upgrade watchdog cleanup' "$(grep -h 'logs-prune upgrade watchdog' "$REPO/bin/uninstall")" "uninstall: removes the cleanup agent"
assert_status 0 "syntax: bootstrap, doctor, uninstall" bash -c "bash -n '$REPO/bootstrap.sh' && bash -n '$REPO/bin/doctor' && bash -n '$REPO/bin/uninstall'"

test_summary
