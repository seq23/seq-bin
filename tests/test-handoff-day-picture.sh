#!/bin/bash
# Behaviour test for the 27 Nov 2026 rebuild of handoff-on-compact.sh, in fake HOMEs with a fake `claude`
# on PATH (the real path: prompt on stdin, answer on stdout) and a fixed clock (HANDOFF_TEST_NOW, Central).
# What it proves, section by section:
#   A  notes build up: three compactions of one session, the model is given the old note plus ONLY the
#      transcript since it, on Sonnet; a PR number or path it invents is removed; one it forgets comes back
#   B  no model call under 20 new messages, and the skipped messages are still read by the next summary
#   C  every outage (model fails, empty, not a note, timeout, `claude` missing, transcript unreadable or not
#      given, empty transcript, first note of a session) keeps the old note and writes a stamped line
#   D  the day archive: every note that leaves HANDOFF (replaced, past 6, rolled over) is there once, in the
#      order it left, in its own day's file; midnight is her Mac's midnight, not UTC's
#   E  an archive that cannot be written: nothing is replaced or dropped
#   F  two sessions compacting at once (and a migration beside them): no note lost, none archived twice
#   G  post-land-check lines move to the one list: none lost, none doubled, run twice, killed halfway,
#      list unwritable; text outside Today byte for byte the same
#   H  PINNED over 15 lines is said in the hook's message; no line is deleted
#   I  a session whose note already left HANDOFF (past 6) still builds on it, from the archive; at a new day
#      an open item's line is kept, an earlier day's landed item is not repeated
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/handoff-on-compact.sh"
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
export TZ=America/Chicago
fail=0; bad(){ echo "FAIL: $1"; fail=1; }
has(){ grep -qF -- "$2" "$1" 2>/dev/null || bad "$3"; }
hasnt(){ if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3"; fi; }
count(){ grep -cF -- "$2" "$1" 2>/dev/null || true; }
once(){ [ "$(count "$1" "$2")" = 1 ] || bad "$3 (found $(count "$1" "$2") time(s))"; }
epoch(){ python3 -c 'import calendar,sys,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$1"; }
line_of(){ grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
in_order(){ # file text... : each text is there and they appear in this order
  local f="$1" last=0 n t; shift
  for t in "$@"; do n="$(line_of "$f" "$t")"; [ -n "$n" ] && [ "$n" -gt "$last" ] || { bad "order in $(basename "$f"): '$t' is missing or out of order"; return; }; last="$n"; done
}
outside(){ # the bytes of HANDOFF outside the TODAY markers
  python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); a=d.split(b"<!-- TODAY:START -->",1); sys.stdout.buffer.write(a[0]+b"|"+a[1].split(b"<!-- TODAY:END -->",1)[1])' "$1" | cksum
}
part(){ sed -n "/^<<<$2\$/,/^$2>>>\$/p" "$1"; }   # one data block of a saved prompt
say(){ # file start n text: n user/assistant messages one second apart, as Claude Code writes them
  python3 - "$@" <<'PY'
import sys, json, time
f, start, n, text = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with open(f, "a") as fh:
    for i in range(n):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(start + i)) + ".000Z"
        role = "user" if i % 2 == 0 else "assistant"
        t = text + " [" + str(i + 1) + "]"
        content = t if role == "user" else [{"type": "text", "text": t}, {"type": "tool_use", "id": "x", "name": "Bash", "input": {}}]
        fh.write(json.dumps({"type": role, "timestamp": ts, "message": {"role": role, "content": content}}) + "\n")
PY
}
mkdir -p "$R/fakebin" "$R/onlybin"
cat > "$R/fakebin/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/claude-args"
cat > "${FAKE_PROMPT:-/dev/null}"
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
[ -n "${FAKE_RC:-}" ] && exit "$FAKE_RC"
cat "$FAKE_ANSWER"
SH
printf '#!/bin/bash\necho "land-after: no open task sheets in x"\n' > "$R/fakebin/la"
chmod +x "$R/fakebin/claude" "$R/fakebin/la"
export LAND_AFTER_BIN="$R/fakebin/la"
# A PATH with everything the hook needs and no `claude` at all (the dev Mac has a real one).
for t in python3 jq cat rm dirname grep sed tail awk; do printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v $t)" > "$R/onlybin/$t"; chmod +x "$R/onlybin/$t"; done
home(){ export HOME="$R/$1" TMPDIR="$R/$1/tmp"; mkdir -p "$TMPDIR"; H="$HOME/HANDOFF.md"; A="$HOME/Work/handoff-archive"; D="$HOME/Work/tasks/post-land-checks.md"; }
real(){ # sid now [transcript]: the real path, in the foreground (HANDOFF_BG), fake `claude` first on PATH
  printf '{"session_id":"%s","transcript_path":"%s","trigger":"auto"}' "$1" "${3-$HOME/t.jsonl}" \
    | HANDOFF_BG=fg HANDOFF_TEST_NOW="$2" PATH="$R/fakebin:$PATH" bash "$S" 2>>"$R/err"
}
stand(){ # sid now summary: the stand-in path (no model, no transcript)
  printf '{"session_id":"%s","trigger":"auto"}' "$1" | HANDOFF_TEST_NOW="$2" HANDOFF_TEST_SUMMARY="$3" bash "$S" 2>>"$R/err"
}
calls(){ wc -l < "$HOME/claude-args" 2>/dev/null | tr -d ' '; }
note4(){ printf '## In flight\n%s\n## Landed today\n%s\n## Waiting on her\n- nothing\n## Next\n- nothing\n' "$1" "$2"; }

echo "=== A: three compactions of one session build ONE note up ==="
home build; T0=$(epoch 2026-06-10T17:00:00Z)
printf '# HANDOFF\n\n## PINNED\n- pinned one\n' > "$H"
say "$HOME/t.jsonl" $((T0-1000)) 24 "MSG-A seq23/alpha#101 landed in tools/alpha.sh and seq23/alpha#102 opened"
{ printf 'Here is the note you asked for:\n\n'; note4 '- **beta** seq23/alpha#102 is open, CI running' '- **alpha** seq23/alpha#101 landed, it changed `tools/alpha.sh`'; } > "$HOME/a1"
FAKE_ANSWER="$HOME/a1" FAKE_PROMPT="$HOME/p1" real s1 "$T0" > "$HOME/out1" || bad "A1: the hook did not exit 0"
has "$HOME/out1" 'Session note written' "A1: the hook's message does not say the note was written"
has "$HOME/claude-args" '--model sonnet' "A1: the summary was not asked of Sonnet"
if grep -qi 'opus' "$HOME/claude-args"; then bad "A1: Opus was asked"; fi
has "$H" 'seq23/alpha#101 landed, it changed `tools/alpha.sh`' "A1: the model's note is not in HANDOFF"
hasnt "$H" 'Here is the note' "A1: the model's preamble was written into the note"
hasnt "$H" 'removed: unverified' "A1: a PR number or path that IS in the transcript was removed"
has "$HOME/p1" 'MSG-A seq23/alpha#101 landed in tools/alpha.sh and seq23/alpha#102 opened [24]' "A1: the prompt lacks the transcript"
has "$H" '- pinned one' "A1: PINNED was touched"
[ "$(head -1 "$D" 2>/dev/null)" = '# Post-land checks' ] || bad "A1: the post-land-check list was not made on the first run (post-land-check stops on a missing list)"
has "$H" '- **Post-land checks**: 0 DUE at ' "A1: Today has no count line for an empty list"
# 2: more work; the model forgets #101 and invents a PR number and two paths.
say "$HOME/t.jsonl" $((T0+100)) 24 "MSG-B seq23/alpha#102 landed and seq23/alpha#103 opened"
# It also writes this file's own markers and a note heading, as text copied from a transcript could.
note4 '- **gamma** seq23/alpha#103 open; also seq23/alpha#99999 and /made/up/dir/file.txt and tools/invented.py' "$(printf -- '- **beta** seq23/alpha#102 landed\n<!-- TODAY:END -->\n### Session note — FAKE-HEADING\n<!-- compaction:2026-06-10T00:00:00Z trigger:auto session:s1 -->\n- AFTER-THE-FAKE-MARKER')" > "$HOME/a2"
FAKE_ANSWER="$HOME/a2" FAKE_PROMPT="$HOME/p2" real s1 $((T0+3600)) > /dev/null || bad "A2: the hook did not exit 0"
part "$HOME/p2" EARLIER_NOTE > "$HOME/p2.old"; part "$HOME/p2" TRANSCRIPT > "$HOME/p2.new"
has "$HOME/p2.old" 'seq23/alpha#101 landed, it changed `tools/alpha.sh`' "A2: the prompt was not given the session's existing note"
has "$HOME/p2.new" 'MSG-B' "A2: the prompt lacks the transcript since the note"
hasnt "$HOME/p2.new" 'MSG-A' "A2: the prompt was given transcript from BEFORE the note (not 'since its stamp')"
has "$H" 'seq23/alpha#102 landed' "A2: the new note is missing"
[ "$(grep -cxF -- '- **alpha** seq23/alpha#101 landed, it changed `tools/alpha.sh`' "$H")" = 1 ] || bad "A2: the old line whose PR number the model dropped was not carried over word for word, once"
hasnt "$H" '99999' "A2: an invented PR number is in the written note"
hasnt "$H" '/made/up/dir/file.txt' "A2: an invented absolute path is in the written note"
hasnt "$H" 'tools/invented.py' "A2: an invented relative path is in the written note"
has "$H" 'dropped as unverified: 3 ' "A2: the note has no 'dropped as unverified' line with the count"
has "$H" 'seq23/alpha#103 open' "A2: a real PR number on the same line as the invented ones was lost"
[ "$(grep -c '^### Session note' "$H")" = 1 ] || bad "A2: the session's notes stacked, or the model's text opened a second note"
[ "$(count "$H" '<!-- TODAY:END -->')" = 1 ] || bad "A2: the model's text wrote a second TODAY:END marker"
[ "$(tail -1 "$H")" = '<!-- TODAY:END -->' ] || bad "A2: the model's text closed Today early (text now sits outside the markers)"
has "$H" '- AFTER-THE-FAKE-MARKER' "A2: the rest of the model's note was lost"
once "$A/2026-06-10.md" 'seq23/alpha#102 is open, CI running' "A2: the replaced note is not in the day archive once"
has "$A/2026-06-10.md" '`seq23/alpha#99999`, `/made/up/dir/file.txt`, `tools/invented.py`' "A2: what was dropped as unverified is not listed in the day archive"
# 3: the model returns only the newest item.
say "$HOME/t.jsonl" $((T0+4000)) 24 "MSG-C seq23/alpha#104 landed"
note4 '- nothing' '- **delta** seq23/alpha#104 landed' > "$HOME/a3"
FAKE_ANSWER="$HOME/a3" FAKE_PROMPT="$HOME/p3" real s1 $((T0+7200)) > /dev/null
part "$HOME/p3" TRANSCRIPT > "$HOME/p3.new"
has "$HOME/p3.new" 'MSG-C' "A3: the prompt lacks the newest transcript"; hasnt "$HOME/p3.new" 'MSG-B' "A3: the prompt repeats transcript the last note already covered"
for n in 101 102 103 104; do has "$H" "seq23/alpha#$n" "A3: after three compactions the note no longer names #$n"; done
[ "$(grep -cF -- 'seq23/alpha#101 landed, it changed' "$H")" = 1 ] || bad "A3: the kept line was written twice"
[ "$(grep -c '^### Session note' "$H")" = 1 ] || bad "A3: the session's notes stacked"
[ "$(grep -c '^### Session note' "$A/2026-06-10.md")" = 2 ] || bad "A3: the archive does not hold exactly the two replaced notes"
in_order "$A/2026-06-10.md" 'seq23/alpha#102 is open, CI running' '- **beta** seq23/alpha#102 landed'
[ "$(calls)" = 3 ] || bad "A: expected 3 model calls, got $(calls)"

echo "=== B: under 20 new messages there is no model call, and nothing is skipped for good ==="
say "$HOME/t.jsonl" $((T0+7300)) 5 "MSG-D small"
note4 '- SHOULD-NOT-APPEAR' '- nothing' > "$HOME/a-none"
stamp_before="$(grep 'compaction:' "$H")"; before="$(cat "$H")"
FAKE_ANSWER="$HOME/a-none" real s1 $((T0+7400)) > "$HOME/outB" || bad "B: the hook did not exit 0"
[ "$(calls)" = 3 ] || bad "B: the model was called with 5 new messages"
hasnt "$H" 'SHOULD-NOT-APPEAR' "B: a new summary was written"
has "$H" 'compacted again with 5 new message(s) since this note (under 20); no new summary.' "B: no stamped line says why there is no new summary"
[ "$(cat "$H")" != "$before" ] || bad "B: the hook exited 0 having written nothing"
has "$H" '- **delta** seq23/alpha#104 landed' "B: the kept note lost a line"
[ "$(grep 'compaction:' "$H")" = "$stamp_before" ] || bad "B: the kept note's stamp moved, so the 5 messages would never be read"
FAKE_ANSWER="$HOME/a-none" real s1 $((T0+7500)) > /dev/null
[ "$(count "$H" 'no new summary')" = 1 ] || bad "B: the 'no new summary' lines stacked"
say "$HOME/t.jsonl" $((T0+7600)) 20 "MSG-E more"
note4 '- nothing' '- **alpha..delta** seq23/alpha#101 seq23/alpha#102 seq23/alpha#103 seq23/alpha#104 landed' > "$HOME/a4"
FAKE_ANSWER="$HOME/a4" FAKE_PROMPT="$HOME/p4" real s1 $((T0+8000)) > /dev/null
[ "$(calls)" = 4 ] || bad "B: 25 new messages did not get a summary"
part "$HOME/p4" TRANSCRIPT > "$HOME/p4.new"
has "$HOME/p4.new" 'MSG-D small [1]' "B: the 5 messages of the skipped compaction were never given to the model"
has "$HOME/p4.new" 'MSG-E more [20]' "B: the newest messages were not given to the model"
hasnt "$H" 'no new summary' "B: the 'no new summary' line outlived the next summary"
once "$A/2026-06-10.md" '- **delta** seq23/alpha#104 landed' "B: the note that was kept, then replaced, is not in the archive once"
hasnt "$A/2026-06-10.md" 'no new summary' "B: the hook's own 'no new summary' line was archived as part of the note"

echo "=== C: an outage never replaces a good note, and always leaves a stamped line ==="
say "$HOME/t.jsonl" $((T0+8100)) 24 "MSG-F seq23/alpha#105 opened"
good='- **alpha..delta** seq23/alpha#101 seq23/alpha#102 seq23/alpha#103 seq23/alpha#104 landed'
stamp_before="$(grep 'compaction:' "$H")"; printf 'I cannot help with that. seq23/alpha#105\n' > "$HOME/a-garbage"; : > "$HOME/a-empty"
now=$((T0+9000))
outage(){ # name, the reason the stamped line must give, then the run
  local name="$1" why="$2" before n; shift 2; before="$(cat "$H")"; n="$(calls)"; now=$((now+60))
  "$@" > "$HOME/outC" || bad "C $name: the hook did not exit 0 though it wrote its line"
  [ "$(grep -cxF -- "$good" "$H")" = 1 ] || bad "C $name: the good note was replaced or changed"
  [ "$(count "$H" 'could not summarise')" = 1 ] || bad "C $name: not exactly one 'could not summarise' line"
  has "$H" "could not summarise ($why)" "C $name: the stamped line does not give the reason '$why'"
  [ "$(cat "$H")" != "$before" ] || bad "C $name: exit 0 having written nothing"
  [ "$(grep 'compaction:' "$H")" = "$stamp_before" ] || bad "C $name: the kept note's stamp moved"
  has "$HOME/outC" 'could not be produced' "C $name: the hook's message claims a note was written"
  hasnt "$H" 'seq23/alpha#105' "C $name: text from a failed answer reached the note"
  echo "$n" > "$HOME/calls-before"
}
slow(){ local t0; t0=$(date +%s); FAKE_SLEEP=6 FAKE_ANSWER="$HOME/a4" HANDOFF_MODEL_TIMEOUT=1 real s1 "$now"; [ $(( $(date +%s) - t0 )) -le 4 ] || bad "C timeout: the hook waited for the summariser past its limit"; }
noclaude(){ printf '{"session_id":"s1","transcript_path":"%s","trigger":"auto"}' "$HOME/t.jsonl" | HANDOFF_BG=fg HANDOFF_TEST_NOW="$now" PATH="$R/onlybin" "$BASH" "$S" 2>>"$R/err"; }
nopath(){ printf '{"session_id":"s1","trigger":"auto"}' | HANDOFF_BG=fg HANDOFF_TEST_NOW="$now" PATH="$R/fakebin:$PATH" bash "$S" 2>>"$R/err"; }
outage "model fails" 'the summariser failed (exit 1)' env FAKE_RC=1 FAKE_ANSWER="$HOME/a4" bash -c "$(declare -f real); R='$R' S='$S'; real s1 \$0" "$((now+60))"
outage "empty answer" "the summariser's answer was not a note" env FAKE_ANSWER="$HOME/a-empty" bash -c "$(declare -f real); R='$R' S='$S'; real s1 \$0" "$((now+60))"
outage "answer is not a note" "the summariser's answer was not a note" env FAKE_ANSWER="$HOME/a-garbage" bash -c "$(declare -f real); R='$R' S='$S'; real s1 \$0" "$((now+60))"
{ note4 '- x' '- y'; for i in $(seq 1 130); do echo "- filler line $i seq23/alpha#105"; done; } > "$HOME/a-long"
outage "answer far too long" "the summariser's answer was 138 lines, over the limit of 120" env FAKE_ANSWER="$HOME/a-long" bash -c "$(declare -f real); R='$R' S='$S'; real s1 \$0" "$((now+60))"
outage "timeout" 'the summariser timed out' slow
outage "claude missing" 'the `claude` command could not be started' noclaude
[ "$(calls)" = "$(cat "$HOME/calls-before")" ] || bad "C claude missing: a model was called"
outage "transcript unreadable" 'the transcript could not be read' real s1 "$((now+60))" "$HOME"
outage "no transcript path" 'no transcript path was given' nopath
note4 '- **epsilon** seq23/alpha#105 open' "$good" > "$HOME/a5"
FAKE_ANSWER="$HOME/a5" FAKE_PROMPT="$HOME/p5" real s1 $((now+600)) > /dev/null
part "$HOME/p5" TRANSCRIPT > "$HOME/p5.new"
has "$HOME/p5.new" 'MSG-F seq23/alpha#105 opened [1]' "C: the messages of the failed compactions were never given to the model"
hasnt "$H" 'could not summarise' "C: the 'could not summarise' line outlived the next good summary"
has "$H" 'seq23/alpha#105 open' "C: the summary after the outage was not written"
# The first note of a session fails: a stamped note, and the whole transcript is read next time.
FAKE_RC=1 FAKE_ANSWER="$HOME/a4" real s2 $((now+700)) > /dev/null || bad "C first note: the hook did not exit 0"
has "$H" 'covers:none trigger:auto session:s2 -->' "C first note: a failed first summary left no stamped note for the session"
has "$H" 'Summary could not be produced' "C first note: the note does not say the summary failed"
has "$H" 'seq23/alpha#105 open' "C first note: another session's note was lost"
note4 '- **s2** seq23/alpha#105 open' '- nothing' > "$HOME/a6"
FAKE_ANSWER="$HOME/a6" FAKE_PROMPT="$HOME/p6" real s2 $((now+800)) > /dev/null
has "$HOME/p6" 'MSG-A' "C first note: the summary after a failed first note did not read the transcript from its start"
hasnt "$H" 'Summary could not be produced' "C first note: the failure note was not replaced by the good one"
# An empty transcript: no model call, a stamped note.
: > "$HOME/empty.jsonl"; n="$(calls)"
real s3 $((now+900)) "$HOME/empty.jsonl" > /dev/null || bad "C empty transcript: the hook did not exit 0"
[ "$(calls)" = "$n" ] || bad "C empty transcript: the model was called with nothing to read"
has "$H" 'session:s3 -->' "C empty transcript: no stamped note"
has "$H" 'the transcript had no text to summarise' "C empty transcript: the note does not say why"

echo "=== D: the day archive holds every note that left, once, in order; midnight is Central ==="
home day; D1=$(epoch 2026-06-10T15:00:00Z)   # 10:00 Central, 10 June
printf '# HANDOFF\r\n## PINNED\n- p caf\xe9\n## Today\n<!-- TODAY:START -->\n<!-- day:2026-06-10 -->\n_x_\n\nHAND-STATUS-LINE with seq23/x#7\n<!-- TODAY:END -->\nAFTER-TODAY-LINE\n' > "$H"
out0="$(outside "$H")"
stand s1 "$D1" "$(note4 '- NOTE-S1-V1' '- nothing')" > /dev/null
[ ! -e "$A" ] || bad "D: an archive was written before anything left HANDOFF"
stand s1 $((D1+60)) "$(note4 '- NOTE-S1-V2' '- nothing')" > /dev/null
for i in 2 3 4 5 6 7 8; do stand "s$i" $((D1+60*i)) "$(note4 "- NOTE-S$i-V1" '- nothing')" > /dev/null; done
AD="$A/2026-06-10.md"
for i in 3 4 5 6 7 8; do has "$H" "NOTE-S$i-V1" "D: session $i's note is not in HANDOFF (6 are kept)"; done
hasnt "$H" 'NOTE-S2-V1' "D: a 7th note was kept in HANDOFF"
has "$H" '_2 older session note(s) from today dropped from this file; each one'"'"'s full text is in `~/Work/handoff-archive/`' "D: HANDOFF does not say where the dropped notes are"
in_order "$AD" 'NOTE-S1-V1' 'NOTE-S1-V2' 'NOTE-S2-V1'
hasnt "$AD" 'NOTE-S3-V1' "D: a note still in HANDOFF was archived"
hasnt "$H" 'Kept from the earlier note' "D: a note with no PR numbers got a 'kept' section"; hasnt "$H" 'unverified' "D: a note with no PR numbers or paths got an 'unverified' line"
# 19:01 Central is already 11 June in UTC: still the same day here.
stand s8 "$(epoch 2026-06-11T00:01:00Z)" "$(note4 '- NOTE-S8-V2' '- nothing')" > /dev/null
has "$H" '<!-- day:2026-06-10 -->' "D: the day rolled over at UTC midnight, not Central midnight"
has "$H" 'NOTE-S7-V1' "D: notes were dropped at UTC midnight"
stand s7 "$(epoch 2026-06-11T04:59:30Z)" "$(note4 '- NOTE-S7-V2' '- nothing')" > /dev/null   # 23:59:30 Central
has "$H" '<!-- day:2026-06-10 -->' "D: 23:59:30 Central was treated as the next day"
[ ! -e "$A/2026-06-11.md" ] || bad "D: a note of 10 June (Central) was archived under 11 June"
stand s9 "$(epoch 2026-06-11T05:00:30Z)" "$(note4 '- NOTE-S9-V1' '- nothing')" > /dev/null   # 00:00:30 Central
has "$H" '<!-- day:2026-06-11 -->' "D: 00:00:30 Central did not start the new day"
has "$H" '### Carried over from 2026-06-10 (check before trusting)' "D: yesterday's status was not carried once"
has "$H" 'HAND-STATUS-LINE with seq23/x#7' "D: the hand-written status was lost at the new day"
[ "$(grep -c '^### Session note' "$H")" = 1 ] || bad "D: yesterday's notes stayed in HANDOFF"
in_order "$AD" 'NOTE-S1-V1' 'NOTE-S1-V2' 'NOTE-S2-V1' 'NOTE-S8-V1' 'NOTE-S7-V1' 'HAND-STATUS-LINE' 'NOTE-S3-V1' 'NOTE-S4-V1' 'NOTE-S5-V1' 'NOTE-S6-V1' 'NOTE-S8-V2' 'NOTE-S7-V2'
for t in NOTE-S1-V1 NOTE-S1-V2 NOTE-S2-V1 NOTE-S3-V1 NOTE-S4-V1 NOTE-S5-V1 NOTE-S6-V1 NOTE-S7-V1 NOTE-S7-V2 NOTE-S8-V1 NOTE-S8-V2 HAND-STATUS-LINE; do once "$AD" "$t" "D: '$t' is not in the 10 June archive exactly once"; done
[ "$(grep -c '^### Session note' "$AD")" = 11 ] || bad "D: the 10 June archive does not hold exactly the 11 notes that left"
[ ! -e "$A/2026-06-11.md" ] || bad "D: something was archived under 11 June though nothing of that day has left"
# A resumed session comes back with a new id: its note stacks beside the old one; the next day both are archived.
stand s9b $((D1+86400)) "$(note4 '- NOTE-S9B-V1' '- nothing')" > /dev/null
has "$H" 'NOTE-S9-V1' "D: a resumed session's new id replaced the old id's note"; has "$H" 'NOTE-S9B-V1' "D: the resumed session's note is missing"
stand s10 $((D1+2*86400)) "$(note4 '- NOTE-S10-V1' '- nothing')" > /dev/null
in_order "$A/2026-06-11.md" 'NOTE-S9-V1' 'NOTE-S9B-V1'
once "$AD" 'HAND-STATUS-LINE' "D: the carried status was archived a second time when it left"
hasnt "$H" 'HAND-STATUS-LINE' "D: the carried block survived a second day"
[ "$(outside "$H")" = "$out0" ] || bad "D: text outside the TODAY markers changed (a Windows line end or a non-UTF-8 byte was rewritten)"

echo "=== E: an archive that cannot be written means nothing is replaced or dropped ==="
home noarch; mkdir -p "$HOME/Work"; : > "$HOME/Work/handoff-archive"   # a file where the folder must be
printf '# HANDOFF\n<!-- TODAY:START -->\n<!-- day:2026-06-10 -->\n_x_\n\n<!-- TODAY:END -->\n' > "$H"
stand s1 "$D1" "$(note4 '- NOTE-E1-V1' '- nothing')" > /dev/null
stand s1 $((D1+60)) "$(note4 '- NOTE-E1-V2' '- nothing')" > "$HOME/outE" || bad "E: the hook did not exit 0 though it wrote the note"
has "$H" 'NOTE-E1-V1' "E: a note was replaced though it could not be archived"
has "$H" 'NOTE-E1-V2' "E: the new note was not written"
has "$H" 'the day archive could not be written' "E: the note does not say the archive failed"
has "$HOME/outE" 'the day archive could not be written, so nothing was replaced or dropped' "E: the hook's message does not say so"
for i in 2 3 4 5 6 7 8; do stand "s$i" $((D1+60*i)) "$(note4 "- NOTE-E$i-V1" '- nothing')" > /dev/null; done
for t in NOTE-E1-V1 NOTE-E1-V2 NOTE-E2-V1 NOTE-E3-V1 NOTE-E8-V1; do has "$H" "$t" "E: '$t' was dropped though it could not be archived"; done
hasnt "$H" 'older session note(s) from today dropped' "E: HANDOFF says notes were dropped"
rm "$HOME/Work/handoff-archive"
stand s8 $((D1+600)) "$(note4 '- NOTE-E8-V2' '- nothing')" > /dev/null
[ "$(grep -c '^### Session note' "$H")" = 6 ] || bad "E: once the archive works again HANDOFF is not back to 6 notes"
for t in NOTE-E1-V1 NOTE-E1-V2 NOTE-E2-V1 NOTE-E8-V1; do once "$A/2026-06-10.md" "$t" "E: '$t' did not reach the archive once it worked again"; hasnt "$H" "$t" "E: '$t' is still in HANDOFF after it was archived"; done
for t in NOTE-E3-V1 NOTE-E7-V1 NOTE-E8-V2; do has "$H" "$t" "E: '$t' (one of the newest 6) left HANDOFF"; hasnt "$A/2026-06-10.md" "$t" "E: '$t' is in the archive though it never left"; done

echo "=== F: two sessions compacting at once lose nothing ==="
home race
printf '# HANDOFF\n<!-- TODAY:START -->\n<!-- day:2026-06-10 -->\n_x_\n\n<!-- JOBS:START -->\n<!-- JOBS:END -->\n- ENG-CHECK DUE o/r#41 aaaaaaa — written by an old land during the race\n<!-- TODAY:END -->\n' > "$H"
say "$HOME/ta.jsonl" $((D1+90000)) 20 "RACE-MSG-A"; say "$HOME/tb.jsonl" $((D1+90000)) 20 "RACE-MSG-B"
for r in 1 2 3; do
  note4 "- RACE-A-$r" '- nothing' > "$HOME/ra$r"; note4 "- RACE-B-$r" '- nothing' > "$HOME/rb$r"
  FAKE_ANSWER="$HOME/ra$r" HANDOFF_TEST_HOLD=0.4 real ca $((D1+100*r)) "$HOME/ta.jsonl" > /dev/null &
  FAKE_ANSWER="$HOME/rb$r" HANDOFF_TEST_HOLD=0.4 real cb $((D1+100*r)) "$HOME/tb.jsonl" > /dev/null &
  [ "$r" = 2 ] && { HANDOFF_TEST_NOW=$((D1+100*r)) bash "$S" --migrate-due > /dev/null 2>>"$R/err" & }
  wait
  has "$H" "RACE-A-$r" "F round $r: session A's note was lost to session B's write"
  has "$H" "RACE-B-$r" "F round $r: session B's note was lost to session A's write"
done
[ "$(grep -c '^### Session note' "$H")" = 2 ] || bad "F: not exactly one note per session"
for t in RACE-A-1 RACE-A-2 RACE-B-1 RACE-B-2; do once "$A/2026-06-10.md" "$t" "F: '$t' is not in the archive exactly once"; done
[ "$(grep -c '^- ENG-CHECK DUE o/r#41 ' "$D")" = 1 ] || bad "F: the post-land-check line is not in the list exactly once"
if grep -q '^- ENG-CHECK DUE ' "$H"; then bad "F: the post-land-check line is still in HANDOFF"; fi
[ -z "$(ls "$HOME"/HANDOFF.md.* 2>/dev/null)" ] || bad "F: a temporary file was left beside HANDOFF.md"

echo "=== G: post-land-check lines move to the one list ==="
home move; NOW=$(epoch 2026-06-10T17:00:00Z)
L1='- OUTCOME-CHECK DUE o/r#7 abc1234 — task:job by:2000-01-04 expect:>=3 — outcome: x — check: echo 3'
L2='- ENG-CHECK DUE o/r#8 def5678 — landed under her bypass; a fresh reviewer checks'
L3='- FORM-PROOF DUE o/r#9 0a0b0c0 — forms: contact'
L4='- ENG-CHECK DONE o/r#6 1111111 — x → https://x'
L5='- FORM-PROOF FAIL o/r#5 2222222 — forms: quote → https://y'
fixture(){ printf '# HANDOFF\r\n## PINNED\n- p caf\xe9\n## Today\n<!-- TODAY:START -->\n<!-- day:2026-06-10 -->\n_x_\n\n<!-- JOBS:START -->\n### Jobs\n- none open\n<!-- JOBS:END -->\n\n<!-- STUCK-PRS:START -->\n### Stuck PRs\n- o/r#3 red 2 h\n<!-- STUCK-PRS:END -->\n\nSTATUS-LINE-ABOVE\n### Post-land checks (hand-written heading)\n%s\n%s\n%s\n%s\n%s\nSTATUS-LINE-BELOW\n\n### Session note — earlier\n<!-- compaction:2026-06-10T15:00:00Z trigger:auto session:m1 -->\n- ENG-CHECK DUE o/r#77 7777777 — a line QUOTED inside a session note\n<!-- TODAY:END -->\nAFTER-TODAY-LINE\n' "$L1" "$L2" "$L3" "$L4" "$L5" > "$H"; }
fixture; out0="$(outside "$H")"; cp "$H" "$HOME/H.orig"
HANDOFF_TEST_NOW="$NOW" bash "$S" --migrate-due > "$HOME/outG" 2>&1 || bad "G: the migration did not exit 0"
has "$HOME/outG" 'moved 5 post-land-check line(s)' "G: the migration does not say what it moved"
for l in "$L1" "$L2" "$L3" "$L4" "$L5"; do
  [ "$(grep -cxF -- "$l" "$D")" = 1 ] || bad "G: '${l:0:28}…' is not in the list exactly once"
  if grep -qxF -- "$l" "$H"; then bad "G: '${l:0:28}…' is still in HANDOFF"; fi
done
in_order "$D" "$L1" "$L2" "$L3" "$L4" "$L5"
[ "$(grep -c 'Post-land checks\*\*: ' "$H")" = 1 ] || bad "G: HANDOFF does not have exactly one count line"
has "$H" '- **Post-land checks**: 3 DUE at ' "G: the count line does not say 3 DUE"
has "$H" 'the list is `~/Work/tasks/post-land-checks.md`' "G: the count line does not give the list's path"
in_order "$H" '<!-- STUCK-PRS:END -->' '<!-- DUE:START -->' 'STATUS-LINE-ABOVE' '### Post-land checks (hand-written heading)' 'STATUS-LINE-BELOW' '### Session note — earlier' 'o/r#77 7777777 — a line QUOTED inside a session note'
has "$H" '- o/r#3 red 2 h' "G: pr-watch's block was changed"
if grep -q 'o/r#77' "$D"; then bad "G: a line quoted inside a session note was moved into the list post-land-check runs"; fi
[ "$(outside "$H")" = "$out0" ] || bad "G: text outside the TODAY markers changed"
# Twice: nothing more happens.
cp "$H" "$HOME/H.1"; cp "$D" "$HOME/D.1"
HANDOFF_TEST_NOW="$NOW" bash "$S" --migrate-due > /dev/null 2>&1 || bad "G: the second migration did not exit 0"
cmp -s "$D" "$HOME/D.1" || bad "G: a second migration changed the list"
cmp -s "$H" "$HOME/H.1" || bad "G: a second migration changed HANDOFF"
# Killed between the two writes: the list has the lines and HANDOFF still has them too. And post-land-check
# closed one in the list meanwhile.
cp "$HOME/H.orig" "$H"; sed -i.bak 's|^- ENG-CHECK DUE o/r#8 \(.*\)$|- ENG-CHECK DONE o/r#8 \1 → https://z|' "$D"; rm -f "$D.bak"; cp "$D" "$HOME/D.2"
HANDOFF_TEST_NOW="$NOW" bash "$S" --migrate-due > "$HOME/outG" 2>&1 || bad "G: the migration after a kill did not exit 0"
cmp -s "$D" "$HOME/D.2" || bad "G: re-running after a kill duplicated a line or re-opened a closed check"
if grep -qE '^- (ENG-CHECK|FORM-PROOF|OUTCOME-CHECK) (DUE|DONE|FAIL) o/r#[5-9] ' "$H"; then bad "G: after a kill and a re-run the lines are still in HANDOFF"; fi
has "$H" '- **Post-land checks**: 2 DUE at ' "G: the count is not the list's count (2 DUE after one was closed)"
# The list cannot be written: the lines stay in HANDOFF, and it is not exit 0.
cp "$HOME/H.orig" "$H"; rm -rf "$HOME/Work/tasks"; : > "$HOME/Work/tasks"
if HANDOFF_TEST_NOW="$NOW" bash "$S" --migrate-due > "$HOME/outG" 2>&1; then bad "G: an unwritable list was exit 0"; fi
has "$HOME/outG" 'NAMED STOP [DUE_FILE_UNWRITTEN]' "G: an unwritable list is not a named stop"
cmp -s "$H" "$HOME/H.orig" || bad "G: the lines left HANDOFF though the list could not be written"
# The same at a compaction: the note is written, the lines stay, and the note says so.
stand m2 "$NOW" "$(note4 '- NOTE-M2' '- nothing')" > /dev/null || bad "G: the hook did not exit 0"
for l in "$L1" "$L2" "$L3" "$L4" "$L5"; do [ "$(grep -cxF -- "$l" "$H")" = 1 ] || bad "G: '${l:0:28}…' left HANDOFF at a compaction though the list could not be written"; done
has "$H" '5 post-land-check line(s) could not be moved' "G: the note does not say the lines could not be moved"
# A line an old `land` writes into Today later is moved at the next compaction, and the count follows.
rm "$HOME/Work/tasks"
stand m2 $((NOW+60)) "$(note4 '- NOTE-M2b' '- nothing')" > /dev/null
for l in "$L1" "$L2" "$L3" "$L4" "$L5"; do [ "$(grep -cxF -- "$l" "$D")" = 1 ] || bad "G: a compaction did not move '${l:0:28}…' into the list once"; done
if grep -qE '^- (ENG-CHECK|FORM-PROOF|OUTCOME-CHECK) (DUE|DONE|FAIL) o/r#[5-9] ' "$H"; then bad "G: a compaction left post-land-check lines in HANDOFF"; fi
has "$H" '- **Post-land checks**: 3 DUE at ' "G: a compaction did not write the count line"
has "$H" 'STATUS-LINE-ABOVE' "G: a hand-written status line was lost"; has "$H" '### Post-land checks (hand-written heading)' "G: a hand-written heading was deleted"
[ "$(outside "$H")" = "$out0" ] || bad "G: text outside the TODAY markers changed at a compaction"
# No HANDOFF at all is a named stop, never a silent 0.
rm "$H"; if bash "$S" --migrate-due > "$HOME/outG" 2>&1; then bad "G: a missing HANDOFF was exit 0"; fi
has "$HOME/outG" 'NAMED STOP [HANDOFF_MISSING]' "G: a missing HANDOFF is not a named stop"

echo "=== H: PINNED over 15 lines is said, nothing is deleted ==="
home pinned
pinned(){ { printf '# HANDOFF\n\n## PINNED (read first)\n\n'; for i in $(seq 1 "$1"); do printf -- '- pinned line %s\n\n' "$i"; done; printf '## Today\n<!-- TODAY:START -->\n<!-- TODAY:END -->\n'; } > "$H"; }
pinned 16; stand h1 "$NOW" "$(note4 '- NOTE-H' '- nothing')" > "$HOME/outH"
has "$HOME/outH" 'PINNED in ~/HANDOFF.md is 16 lines; the limit is 15.' "H: 16 PINNED lines were not warned about in the hook's message"
jq -e '.systemMessage | test("Session note written")' "$HOME/outH" > /dev/null || bad "H: the hook's message is not valid JSON with the result first"
[ "$(grep -c '^- pinned line ' "$H")" = 16 ] || bad "H: a PINNED line was deleted"
pinned 15; stand h1 "$NOW" "$(note4 '- NOTE-H' '- nothing')" > "$HOME/outH"
hasnt "$HOME/outH" 'PINNED' "H: 15 PINNED lines (the limit) were warned about"

echo "=== I: a note that left HANDOFF is still built on; yesterday's landed items are not repeated ==="
home left; I0=$(epoch 2026-06-10T15:00:00Z)
printf '# HANDOFF\n<!-- TODAY:START -->\n<!-- day:2026-06-10 -->\n_x_\n\n<!-- TODAY:END -->\n' > "$H"
say "$HOME/t.jsonl" $((I0-500)) 20 "MSG-I1 o/r#201 landed, o/r#202 opened"
note4 '- **open** o/r#202 waits on CI' '- **done** o/r#201 landed' > "$HOME/i1"
FAKE_ANSWER="$HOME/i1" real i1 "$I0" > /dev/null
for i in 2 3 4 5 6 7; do stand "i$i" $((I0+60*i)) "$(note4 "- NOTE-I$i" '- nothing')" > /dev/null; done
hasnt "$H" 'o/r#202 waits on CI' "I: (setup) session i1's note should have left HANDOFF after 6 more sessions"
once "$A/2026-06-10.md" 'o/r#202 waits on CI' "I: the dropped note is not in the archive once"
say "$HOME/t.jsonl" $((I0+1000)) 20 "MSG-I2 o/r#203 opened"
note4 '- **open** o/r#202 waits on CI; o/r#203 open' '- **done** o/r#201 landed' > "$HOME/i2"
FAKE_ANSWER="$HOME/i2" FAKE_PROMPT="$HOME/pi2" real i1 $((I0+2000)) > /dev/null
part "$HOME/pi2" EARLIER_NOTE > "$HOME/pi2.old"; part "$HOME/pi2" TRANSCRIPT > "$HOME/pi2.new"
has "$HOME/pi2.old" '- **done** o/r#201 landed' "I: a session whose note was dropped to the archive was summarised from nothing"
has "$HOME/pi2.new" 'MSG-I2' "I: the prompt lacks the new transcript"; hasnt "$HOME/pi2.new" 'MSG-I1' "I: the prompt re-read transcript the archived note already covered"
has "$H" 'o/r#203 open' "I: the session's new note is not back in HANDOFF"
[ "$(grep -c 'session:i1 -->' "$A/2026-06-10.md")" = 1 ] || bad "I: the archived note was archived a second time"
# The next day the model returns nothing: the open item's line is kept, yesterday's landed item is not repeated.
say "$HOME/t.jsonl" $((I0+80000)) 20 "MSG-I3 a quiet morning"
note4 '- nothing' '- nothing' > "$HOME/i3"
FAKE_ANSWER="$HOME/i3" FAKE_PROMPT="$HOME/pi3" real i1 $((I0+86400)) > /dev/null
has "$HOME/pi3" 'The earlier note is from an earlier day' "I: at a new day the model was not told the earlier note is yesterday's"
has "$H" '<!-- day:2026-06-11 -->' "I: (setup) the day did not roll over"
[ "$(grep -cxF -- '- **open** o/r#202 waits on CI; o/r#203 open' "$H")" = 1 ] || bad "I: an open item's line (PR numbers the new note lost) was not kept at the new day"
hasnt "$H" 'o/r#201' "I: yesterday's landed item was repeated in today's note"
once "$A/2026-06-10.md" '- **open** o/r#202 waits on CI; o/r#203 open' "I: yesterday's note is not in yesterday's archive once"

[ $fail = 0 ] && echo "PASS test-handoff-day-picture" || exit 1
