#!/usr/bin/env bash
# A tail that cannot check for mail tells her after an hour, then daily; a working check clears it.
set -u
here="$(dirname "$0")/.."
. "$here/scooter-watch-fail.sh"
f="$(mktemp)"; rm -f "$f"; trap 'rm -f "$f"' EXIT
fail=0; alerts=""
note() { alerts="$alerts $1"; }
for _ in 1 2 3; do check_failed "$f" note >/dev/null; done
[ -z "$alerts" ] || { echo "FAIL: alerted before an hour of failures:$alerts"; fail=1; }
check_failed "$f" note >/dev/null
[ "$alerts" = " 4" ] || { echo "FAIL: no alert at the 4th failed check (got:$alerts)"; fail=1; }
for _ in $(seq 5 100); do check_failed "$f" note >/dev/null; done
[ "$alerts" = " 4 100" ] || { echo "FAIL: daily repeat wrong (got:$alerts)"; fail=1; }
check_ok "$f"; alerts=""
for _ in 1 2 3; do check_failed "$f" note >/dev/null; done
[ -z "$alerts" ] || { echo "FAIL: a working check did not clear the count"; fail=1; }
echo junk > "$f"; check_failed "$f" note >/dev/null; [ "$(cat "$f")" = "1" ] || { echo "FAIL: a bad count file was not reset"; fail=1; }
# The watcher: no D1 call outside the vault runner, and both failure exits are counted.
w="$here/scooter-watch.sh"
bare="$(grep -n 'npx wrangler d1 execute' "$w" | grep -v 'vault' | grep -v '^[0-9]*:#' || true)"
[ -z "$bare" ] || { echo "FAIL: a D1 call runs without the vault token: $bare"; fail=1; }
[ "$(grep -c 'check_failed "$CHECK_FAILS" check_alert' "$w")" -eq 2 ] || { echo "FAIL: a failed check exits uncounted"; fail=1; }
grep -q '^check_ok "$CHECK_FAILS"' "$w" || { echo "FAIL: a working check does not clear the count"; fail=1; }
# The tail agent is sent to its own worktree: the runners' checkout must stay on main.
grep -q 'worktree add $HOME_DIR/GitHub/.wt-tail-$STAMP' "$w" || { echo "FAIL: the tail agent is not given its own worktree"; fail=1; }
# Known friction is read from OPEN issues, so a fixed one must be closed or the next tail re-reads it.
grep -q 'gh issue close <n>' "$w" || { echo "FAIL: the tail agent is not told to close a fixed issue"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-fail: OK (10 cases)"; exit $fail
