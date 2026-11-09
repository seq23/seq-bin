#!/bin/bash
# Behaviour test for handoff-on-compact.sh against a fake HOME (HANDOFF_TEST_SUMMARY stands in for the
# model). Proves: a same-day hand-written status is kept above the notes; a session's own older note is
# replaced, not stacked; other sessions' notes survive a busy day (up to 6, the rest named); a FAILED
# summary never replaces that session's good note; a new day drops old notes but carries the newest
# status once, and drops it the day after; PINNED text is never touched.
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/handoff-on-compact.sh"
T=$(mktemp -d); export HOME="$T"; fail=0; bad(){ echo "FAIL: $1"; fail=1; }
today=$(date '+%Y-%m-%d'); H="$T/HANDOFF.md"
run(){ echo "{\"session_id\":\"$1\",\"trigger\":\"auto\"}" | HANDOFF_TEST_SUMMARY="${2:-}" bash "$S" >/dev/null 2>&1; }
cat > "$H" <<MD
# HANDOFF
## PINNED
PINNED-LINE-STAYS
## Today
<!-- TODAY:START -->
<!-- day:$today -->
_Some day_

CURATED-STATUS-LINE with a table | a | b |

### Session note — earlier
<!-- compaction:x trigger:auto session:sess-1 -->
OLD-NOTE-FROM-SESS-1
<!-- TODAY:END -->
MD
run sess-1 "## In flight
- NEW-NOTE-SESS-1"
out=$(cat "$H")
grep -q 'CURATED-STATUS-LINE' <<<"$out" || bad "same day: the hand-written status was overwritten"
grep -q 'OLD-NOTE-FROM-SESS-1' <<<"$out" && bad "same session: the old note was stacked, not replaced"
grep -q 'NEW-NOTE-SESS-1' <<<"$out" || bad "the new note is missing"
c=$(grep -n 'CURATED-STATUS-LINE' <<<"$out" | cut -d: -f1); n=$(grep -n '### Session note' <<<"$out" | head -1 | cut -d: -f1)
[ -n "$c" ] && [ -n "$n" ] && [ "$c" -lt "$n" ] || bad "the hand-written status must sit above the notes"
[ "$(grep -c 'day:' <<<"$out")" = 1 ] || bad "the day marker was duplicated"
# A failed summary keeps the session's good note.
run sess-1 ""
grep -q 'NEW-NOTE-SESS-1' "$H" || bad "a failed summary replaced the session's good note"
grep -q 'could not summarise' "$H" || bad "a failed summary left no stamp"
# Busy day: 7 more sessions; notes from sessions 2..6 survive, the oldest are named as dropped.
for i in 2 3 4 5 6 7 8; do run "sess-$i" "## In flight
- NOTE-SESS-$i"; done
out=$(cat "$H")
for i in 4 5 6 7 8; do grep -q "NOTE-SESS-$i" <<<"$out" || bad "busy day: session $i's note was lost"; done
grep -q 'older session note(s) from today dropped' <<<"$out" || bad "busy day: dropped notes were not named"
grep -q 'CURATED-STATUS-LINE' <<<"$out" || bad "busy day: the hand-written status was lost"
# New day: old notes dropped, newest status carried once.
sed -i.bak "s/<!-- day:$today -->/<!-- day:2000-01-01 -->/" "$H"
run sess-9 "## In flight
- NOTE-SESS-9"
out=$(cat "$H")
grep -q 'NOTE-SESS-8' <<<"$out" && bad "new day: yesterday's session notes were kept"
grep -q 'Carried over from 2000-01-01' <<<"$out" || bad "new day: nothing was carried over"
grep -q 'CURATED-STATUS-LINE' <<<"$out" || bad "new day: yesterday's status was not carried"
grep -q 'NOTE-SESS-9' <<<"$out" || bad "new day: today's note is missing"
# Same day again: the carried block stays; the day after, it goes.
run sess-9 "## In flight
- NOTE-SESS-9b"
grep -q 'Carried over from 2000-01-01' "$H" || bad "same day: the carried block was dropped too early"
sed -i.bak "s/<!-- day:$today -->/<!-- day:2000-01-02 -->/" "$H"
run sess-10 "## In flight
- NOTE-SESS-10"
grep -q 'Carried over from 2000-01-01' "$H" && bad "the carried block survived a second day"
grep -q 'PINNED-LINE-STAYS' "$H" || bad "PINNED text was touched"
rm -rf "$T"
[ $fail = 0 ] && echo "PASS test-handoff-keeps-curated" || exit 1
