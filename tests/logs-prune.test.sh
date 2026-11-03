#!/usr/bin/env bash
# Final review #4: the cleanup sweep's audit log is the one record of what the nightly job deleted, so the 04:00 rotation
# (current -> .1, .1 dropped after 48 h) must leave it alone. Runs bin/logs-prune for real, with every directory it reads
# pointed at a scratch folder.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-prune-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/logs" "$T/valet/Sites" "$T/brew/var/log"

SWEEP="$T/logs/cleanup-sweep.log"
printf '2026-11-02T03:00:01Z old_a_single_0 123456\n2026-11-02T03:00:02Z old_a_single_1 234567\n' > "$SWEEP"
cp "$SWEEP" "$T/sweep.expected"
printf 'something that rotates\n' > "$T/logs/other-command.log"
printf 'yesterday, two days old\n' > "$T/logs/other-command.log.1"
touch -t "$(date -v-3d +%Y%m%d%H%M.%S)" "$T/logs/other-command.log.1"
printf 'an old rotated copy of the sweep log\n' > "$SWEEP.1"
touch -t "$(date -v-3d +%Y%m%d%H%M.%S)" "$SWEEP.1"

out="$(LOG_DIR="$T/logs" VALET_HOME="$T/valet" BREW_PREFIX="$T/brew" "$REPO/bin/logs-prune" --json 2>&1)"; rc=$?
assert_eq 0 "$rc" "logs-prune runs against the scratch directories (output: $out)"
assert_eq "$(cat "$T/sweep.expected")" "$(cat "$SWEEP")" "the sweep log keeps its contents"
assert_eq "an old rotated copy of the sweep log" "$(cat "$SWEEP.1" 2> /dev/null)" "the sweep log is not rotated: its .1 is not replaced either"
assert_eq "0" "$(wc -c < "$T/logs/other-command.log" | tr -d ' ')" "other command logs are still rotated (truncated)"
assert_eq "yes" "$([ -s "$T/logs/other-command.log.1" ] && echo yes || echo no)" "other command logs get a fresh .1"

test_summary
