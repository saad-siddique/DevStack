#!/usr/bin/env bash
# Issue 8: `devstack login <site> --to <path>` lands on that page instead of the dashboard.
# Two halves: bin/site-login (validates the path, stores it with the one-time token; WP-CLI is a stub that records the
# transient it is asked to set) and mu-plugins/uo-local-autologin.php (redirects there; run through
# tests/lib/autologin-harness.php with stand-ins for WordPress). The path must stay on the site: both halves refuse
# anything that is not a plain "/path?query", and the plugin re-checks because the stored value is only data.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib/assert.sh"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix)}"
HOST_PHP="$BREW_PREFIX/bin/php"
T="$(mktemp -d "${TMPDIR:-/tmp}/devstack-login-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# --- bin/site-login with a stub PHP: answers the four WP-CLI calls it makes and records the transient.
mkdir -p "$T/valet/Sites" "$T/sites/alpha" "$T/brew/bin" "$T/brew/opt/php@8.4/bin"
touch "$T/sites/alpha/wp-config.php"; ln -s "$T/sites/alpha" "$T/valet/Sites/alpha"
printf '#!/bin/sh\n' > "$T/brew/bin/wp"; chmod +x "$T/brew/bin/wp"
cat > "$T/brew/opt/php@8.4/bin/php" <<STUB
#!/bin/sh
case "\$*" in
	*"user list"*) echo admin ;;
	*"user get"*) echo 7 ;;
	*"option get home"*) echo https://alpha.test ;;
	*"transient set"*) printf '%s\n' "\$*" >> "$T/transient-calls" ;;
esac
STUB
chmod +x "$T/brew/opt/php@8.4/bin/php"
login() { : > "$T/transient-calls"; VALET_HOME="$T/valet" BREW_PREFIX="$T/brew" "$REPO/bin/site-login" alpha "$@"; }
stored() { sed -E "s/.*transient set uo_local_autologin ('?)(\{.*\})('?) 60.*/\2/" "$T/transient-calls" | head -1; }

TO='/wp-admin/post.php?post=65&action=edit'
out="$(login --to "$TO" --json 2> "$T/err")"; rc=$?
assert_eq 0 "$rc" "--to: exit 0 ($(cat "$T/err"))"
assert_jq "$TO" '.to' "$out" "--to: json reports the landing path"
assert_match '^https://alpha\.test/\?uo_login=[a-f0-9]{48}$' "$(printf '%s' "$out" | jq -r .url)" "--to: the link itself is unchanged (the path is not in the URL)"
assert_jq "$TO" '.to' "$(stored)" "--to: the path is stored with the token"
token="$(printf '%s' "$out" | jq -r .url | sed 's/.*uo_login=//')"
assert_jq "$(printf '%s' "$token" | shasum -a 256 | cut -d' ' -f1)" '.hash' "$(stored)" "--to: the stored hash is the link's token"
assert_jq 7 '.user' "$(stored)" "--to: the stored user is unchanged"

out="$(login --json 2> /dev/null)"
assert_jq null '.to' "$out" "no --to: json has no landing path"
assert_jq null '.to' "$(stored)" "no --to: nothing extra is stored (today's behaviour)"
assert_match '^https://alpha\.test/\?uo_login=' "$(login --print 2> /dev/null)" "no --to, --print: still prints the link"
assert_eq "$TO" "$(login --to="$TO" --json 2> /dev/null | jq -r .to)" "--to=<path> spelling works"
assert_eq '/' "$(login --to / --json 2> /dev/null | jq -r .to)" "--to / (the front page) is allowed"

# Refused before any token is minted: not a same-site path.
for bad in '//evil.example/x' 'https://evil.example/x' 'evil.example/x' 'wp-admin/' '/\evil.example' '/a\b'  '' "$(printf '/a\nb')" $'/a\n' "$(printf '/a\tb')" "/$(printf 'x%.0s' $(seq 1 2100))"; do
	: > "$T/transient-calls"
	assert_status 1 "--to refuses '$(printf '%s' "$bad" | head -c 30 | tr '\n\t' '  ')' (exit 1)" login --to "$bad" --print
	assert_eq "0" "$(wc -c < "$T/transient-calls" | tr -d ' ')" "...and mints no token for it"
done
assert_status 1 "--to without a value: exit 1" login --to

# --- the mu-plugin
act() { "$HOST_PHP" -n "$REPO/tests/lib/autologin-harness.php" "$1" 2> /dev/null; }
GOOD="$(printf '%s' "abc123" | shasum -a 256 | cut -d' ' -f1)"
# scen <stored json> [token] [host] : one harness scenario.   stored_with <json object> : the valid stored value + extra keys.
scen() { jq -cn --argjson stored "$1" --arg token "${2:-abc123}" --arg host "${3:-alpha.test}" '{stored:$stored, token:$token, host:$host}'; }
stored_with() { jq -cn --arg hash "$GOOD" --argjson extra "$1" '{hash:$hash, user:7} + $extra'; }
with_to() { stored_with "$(jq -cn --arg to "$1" '{to:$to}')"; }
DASH='REDIRECT https://alpha\.test/wp-admin/$'

res="$(act "$(scen "$(stored_with '{}')")")"
assert_match "$DASH" "$res" "plugin, no stored path: lands on the dashboard as before"
assert_match 'COOKIE' "$res" "plugin, no stored path: signs in"
res="$(act "$(scen "$(with_to "$TO")")")"
assert_match 'REDIRECT https://alpha\.test/wp-admin/post\.php\?post=65&action=edit$' "$res" "plugin, stored path: lands there"
assert_match 'DELETED' "$res" "plugin: the token is spent"
res="$(act "$(scen "$(with_to /)")")"
assert_match 'REDIRECT https://alpha\.test/$' "$res" "plugin, stored /: lands on the front page"

# A tampered stored value (the transient is only data) never leaves the site: it falls back to the dashboard.
for bad in '//evil.example/x' 'https://evil.example/x' 'evil.example' '/\evil.example' '/a\b' $'/a\x01b' $'/a\nb' $'/a\n' ''; do
	res="$(act "$(scen "$(with_to "$bad")")")"
	assert_match "$DASH" "$res" "plugin, stored '$(printf '%s' "$bad" | tr -c '[:print:]' '?'): falls back to the dashboard"
done
res="$(act "$(scen "$(stored_with '{"to":["/x"]}')")")"
assert_match "$DASH" "$res" "plugin, stored path that is not a string: falls back to the dashboard"

# Unchanged behaviour around it.
res="$(act "$(scen "$(with_to /x)" wrongtoken)")"
assert_match 'DELETED' "$res" "plugin, wrong token: the stored token is still spent"
assert_match 'DIE 403' "$res" "plugin, wrong token: 403"
assert_eq 0 "$(printf '%s' "$res" | grep -c 'REDIRECT\|COOKIE')" "plugin, wrong token: no sign-in and no redirect"
res="$(act "$(scen null)")"
assert_match 'DIE 403' "$res" "plugin, nothing stored (expired): 403"
res="$(act "$(scen "$(with_to /x)" abc123 example.com)")"
assert_match 'NO-EXIT' "$res" "plugin, a host that is not .test: does nothing at all"

test_summary
