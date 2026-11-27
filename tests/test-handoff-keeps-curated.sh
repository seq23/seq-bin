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
# DUE lines (24 Nov 2026 review A): every unmarked OUTCOME-CHECK / ENG-CHECK / FORM-PROOF DUE line survives
# any number of day rollovers, once each, until post-land-check marks it; a marked (DONE) line is not carried.
OD='- OUTCOME-CHECK DUE o/r#7 abc1234 — task:job by:2000-01-04 expect:>=3 — outcome: x — check: echo 3'
ED='- ENG-CHECK DUE o/r#8 def5678 — landed under her bypass; a fresh reviewer checks'
FD='- FORM-PROOF DUE o/r#9 0a0b0c0 — forms: contact'
python3 - "$H" "$OD" "$ED" "$FD" <<'PYT'
import sys; p, *ls = sys.argv[1:]; d = open(p).read()
d = d.replace("<!-- JOBS:END -->\n", "<!-- JOBS:END -->\n" + "\n".join(ls) + "\n- ENG-CHECK DONE o/r#6 1111111 — x → https://x\n", 1)
open(p, "w").write(d)
PYT
for day in 2000-01-03 2000-01-04 2000-01-05; do
  sed -i.bak -E "s/<!-- day:[0-9-]+ -->/<!-- day:$day -->/" "$H"
  run "sess-due-$day" "## In flight
- NOTE-$day"
  for l in "$OD" "$ED" "$FD"; do [ "$(grep -cxF -- "$l" "$H")" = 1 ] || bad "DUE carry: after the rollover from $day, '${l:0:30}…' is not there exactly once"; done
done
grep -q 'ENG-CHECK DONE o/r#6' "$H" && bad "DUE carry: a marked DONE line was carried past its day"
# Jobs (22 Nov 2026): Today carries ONE Jobs list from `land-after --status` (open sheets only, line 1 +
# path, never a sheet's body), replaced on every write.
grep -q 'none open' "$H" || bad "jobs: no open sheets did not say 'none open'"
mkdir -p "$T/Work/tasks/done"
printf 'STATUS: building o/r#1 aaa 2026-11-22T09:00\nGoal: SHEET-BODY-A\n' > "$T/Work/tasks/job-a.md"
printf 'STATUS: landing o/r#2 bbb 2026-11-22T09:05\nGoal: SHEET-BODY-B\n' > "$T/Work/tasks/job-b.md"
printf 'STATUS: PASS o/r#3 ccc 2026-11-22T08:00\n' > "$T/Work/tasks/done/job-c.md"
run sess-10 "## In flight
- NOTE-SESS-10b"
jobs="$(sed -n '/<!-- JOBS:START -->/,/<!-- JOBS:END -->/p' "$H")"
[ "$(grep -c '^- ' <<<"$jobs")" = 2 ] || bad "jobs: expected exactly 2 lines, got: $jobs"
grep -q "^- job-a  STATUS: building o/r#1 .* $T/Work/tasks/job-a.md$" <<<"$jobs" || bad "jobs: job-a's line 1 and path missing"
grep -q "^- job-b  STATUS: landing o/r#2 " <<<"$jobs" || bad "jobs: job-b missing"
grep -q 'job-c' <<<"$jobs" && bad "jobs: a done/ sheet was listed"
grep -q 'SHEET-BODY' "$H" && bad "jobs: a sheet body was copied into HANDOFF"
rm "$T/Work/tasks/job-a.md"
run sess-11 "## In flight
- NOTE-SESS-11"
[ "$(grep -c 'JOBS:START' "$H")" = 1 ] || bad "jobs: the Jobs list was stacked, not replaced"
grep -q 'job-a' "$H" && bad "jobs: a closed sheet stayed on the list"
grep -q 'NOTE-SESS-10b' "$H" || bad "jobs: a session note was lost when the Jobs list was replaced"
# Subagent compactions (23 Nov 2026): Claude Code sends the PARENT's session_id + transcript_path plus the
# subagent's agent_id. The hook must not call the model or touch HANDOFF.md then; a main-session compaction
# with the same transcript still does both; unreadable input still writes a stamped note.
mkdir -p "$T/fakebin"; printf '{"type":"user","message":{"content":"TRANSCRIPT-TEXT"}}\n' > "$T/t.jsonl"
cat > "$T/fakebin/claude" <<'SH'
#!/bin/bash
echo call >> "$HOME/claude-calls"; sleep 4; printf '## In flight\n- FAKE-MODEL-NOTE\n'
SH
chmod +x "$T/fakebin/claude"
# The real hook path (27 Nov 2026): it must RETURN AT ONCE and write the note from a detached copy, because a
# hook that waited on the summariser held every compaction for minutes. Markers and the lock live in $T.
export TMPDIR="$T"
hook(){ printf '%s' "$1" | PATH="$T/fakebin:$PATH" bash "$S" >/dev/null 2>&1; }
until_true(){ local n=0; until eval "$1"; do n=$((n+1)); [ $n -gt 60 ] && return 1; sleep 0.25; done; }
before="$(cat "$H")"
hook "{\"session_id\":\"sess-12\",\"transcript_path\":\"$T/t.jsonl\",\"trigger\":\"auto\",\"agent_id\":\"a123\",\"agent_type\":\"builder\"}"
sleep 1
[ -e "$T/claude-calls" ] && bad "subagent compaction: the summariser model was called"
[ "$(cat "$H")" = "$before" ] || bad "subagent compaction: HANDOFF.md was changed"
t0=$(date +%s)
hook "{\"session_id\":\"sess-12\",\"transcript_path\":\"$T/t.jsonl\",\"trigger\":\"auto\"}"
[ $(( $(date +%s) - t0 )) -le 2 ] || bad "main compaction: the hook waited on the summariser instead of returning at once"
grep -q 'FAKE-MODEL-NOTE' "$H" && bad "main compaction: the note was there before the 4 s summariser could finish (it did not run detached)"
until_true "grep -q 'FAKE-MODEL-NOTE' '$H'" || bad "main compaction: the model's note was not written"
[ "$(cat "$T/claude-calls" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || bad "main compaction: the summariser was not called exactly once"
# A second compaction of the same session inside 10 minutes keeps the note and pays for no second summary.
before="$(cat "$H")"
hook "{\"session_id\":\"sess-12\",\"transcript_path\":\"$T/t.jsonl\",\"trigger\":\"auto\"}"
sleep 1
[ "$(cat "$T/claude-calls" | wc -l | tr -d ' ')" = 1 ] || bad "repeat compaction: the summariser was called again inside 10 minutes"
[ "$(cat "$H")" = "$before" ] || bad "repeat compaction: HANDOFF.md was rewritten inside 10 minutes"
# Another session is not held back by sess-12's window.
hook "{\"session_id\":\"sess-13\",\"transcript_path\":\"$T/t.jsonl\",\"trigger\":\"auto\"}"
until_true "grep -q 'session:sess-13' '$H'" || bad "another session's compaction wrote no note"
before="$(cat "$H")"
hook 'not json {'
until_true '[ "$(cat "$H")" != "$before" ]' || bad "unreadable hook input: no stamped note was written"
rm -rf "$T"
[ $fail = 0 ] && echo "PASS test-handoff-keeps-curated" || exit 1
