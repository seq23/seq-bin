#!/bin/bash
# Behaviour test for handoff-on-compact.sh against a fake HOME (no transcript → no model call).
# Proves: (1) a hand-written status in Today, above the first session note, is KEPT on the same day
# and stays above the new note; (2) the same session's older note is replaced, not stacked;
# (3) on a new day the hand-written status and old notes are dropped; (4) PINNED text is never touched.
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/handoff-on-compact.sh"
T=$(mktemp -d); export HOME="$T"; fail=0; bad(){ echo "FAIL: $1"; fail=1; }
today=$(date '+%Y-%m-%d')
cat > "$T/HANDOFF.md" <<MD
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
echo '{"session_id":"sess-1","trigger":"auto"}' | bash "$S" >/dev/null 2>&1
out=$(cat "$T/HANDOFF.md")
grep -q 'CURATED-STATUS-LINE' <<<"$out" || bad "same day: the hand-written status was overwritten"
grep -q 'OLD-NOTE-FROM-SESS-1' <<<"$out" && bad "same session: the old note was stacked, not replaced"
[ "$(grep -c '### Session note' <<<"$out")" = 1 ] || bad "expected exactly one session note"
c=$(grep -n 'CURATED-STATUS-LINE' <<<"$out" | cut -d: -f1); n=$(grep -n '### Session note' <<<"$out" | cut -d: -f1)
[ -n "$c" ] && [ -n "$n" ] && [ "$c" -lt "$n" ] || bad "the hand-written status must sit above the new note"
[ "$(grep -c 'day:' <<<"$out")" = 1 ] || bad "the day marker was duplicated"
grep -q 'PINNED-LINE-STAYS' <<<"$out" || bad "PINNED text was touched"
# New day: everything in Today is dropped.
sed -i.bak "s/<!-- day:$today -->/<!-- day:2000-01-01 -->/" "$T/HANDOFF.md"
echo '{"session_id":"sess-2","trigger":"auto"}' | bash "$S" >/dev/null 2>&1
out=$(cat "$T/HANDOFF.md")
grep -q 'CURATED-STATUS-LINE' <<<"$out" && bad "new day: yesterday's hand-written status was kept"
grep -q 'PINNED-LINE-STAYS' <<<"$out" || bad "PINNED text was touched on a new day"
rm -rf "$T"
[ $fail = 0 ] && echo "PASS test-handoff-keeps-curated" || exit 1
