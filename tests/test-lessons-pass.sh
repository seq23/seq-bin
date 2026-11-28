#!/bin/bash
# lessons-pass in a fake HOME against a fake ai-run and a fake gh, offline.
# Proves: the day's failure lines are gathered from every source (and only that Central day's); the same PR in two
# sources is one failure; emails are masked before the prompt and in the file; repeats are COUNTED BY CODE from the
# model's item numbers (a model's bad numbers cannot inflate a count); the model runs bare (AI_RUN_BARE=1, Haiku,
# 300 s, 2 runs, caller lessons-pass, no --network/--cwd); only the day's file is written and no rule file is touched;
# a model down, capped or answering junk is named in the file with every failure listed, never "no failures", and
# exits non-zero; a day with no failures still writes its file with its sources; nothing readable is exit 2; a
# complete day is not paid for twice; the day boundary is Central (18:00, midnight, the clock-change day); and
# post-land-check runs it on every nightly exit but never on --now or --dry-run, with its own exit code unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LP="${LP_UNDER_TEST:-$HERE/lessons-pass}"; PLC="${PLC_UNDER_TEST:-$HERE/post-land-check}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
H="$W/home"; T="$H/Work/tasks"; S="$W/store"; D=2026-11-26
mkdir -p "$W/bin" "$S"
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi; }

cat > "$W/bin/ai-run" <<'AI'
#!/bin/bash
# Records how it was called; answers per FAKE_MODE into --out, as ai-run does.
S="$FAKE_STORE"; echo x >> "$S/ai-calls"; cat > "$S/prompt"
echo "cwd=$(pwd)" > "$S/ai-cwd"; echo "args=$* bare=${AI_RUN_BARE:-} model=${AI_RUN_CLAUDE_MODEL:-} secs=${AI_RUN_MAX_SECS:-} runs=${AI_RUN_MAX_RUNS:-} caller=${AI_RUN_CALLER:-} mcp=${AI_RUN_MCP:-}" > "$S/ai-how"
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
case "${FAKE_MODE:-ok}" in
  ok)   printf 'Here you go:\nGROUP 1, 2 | engineering check failed on a schedule change | CHECK: a test that fails a daily-to-weekly change\nGROUP 3 | a land stopped | CHECK: land names it\n' >> "$out" ;;
  bad)  printf 'GROUP 1,1,1,99 | inflated | CHECK: c\n' >> "$out" ;;
  down) echo "NAMED STOP [CLAUDE_LIMIT] resets 9am"; echo "NAMED STOP [CLAUDE_LIMIT] resets 9am" >> "$out"; exit 76 ;;
  junk) echo "I could not do that." >> "$out" ;;
  partial) printf 'GROUP 1 | x | CHECK: y\n' >> "$out"; exit 124 ;;
esac
AI
cat > "$W/bin/gh" <<'GH'
#!/bin/bash
[ -n "${FAKE_GH_DOWN:-}" ] && { echo "HTTP 502" >&2; exit 1; }
case "$2" in
  *comments/111) printf '**Engineering check: FAIL — weekly truth breaks the 3-day freshness check; ask someone@example.com**\nmore\n' ;;
  *comments/222) printf 'Engineering check: FAIL — weekly truth breaks the 3-day freshness check\n' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$W/bin/ai-run" "$W/bin/gh"
export FAKE_STORE="$S" LESSONS_AI_RUN="$W/bin/ai-run" LESSONS_GH="$W/bin/gh" HOME="$H"
ctime() { TZ=America/Chicago touch -t "$1" "$2"; }   # $1 YYYYMMDDhhmm Central

fixture() {
  rm -rf "$H" "$S"; mkdir -p "$T/logs" "$H/.claude/skills/ship-ready" "$H/bin" "$S"
  printf 'rules\n' > "$H/.claude/CLAUDE.md"; printf 'history\n' > "$H/.claude/rules-history.md"; printf 'skill\n' > "$H/.claude/skills/ship-ready/SKILL.md"
  cat > "$T/logs/post-land-check.log" <<EOF
25 Nov 23:39 CT   FAIL seq23/old#9 https://github.com/seq23/old/pull/9#issuecomment-999
26 Nov 23:39 CT   FAIL seq23/app-a#5 https://github.com/seq23/app-a/pull/5#issuecomment-111
26 Nov 23:39 CT   FAIL seq23/app-b#6 https://github.com/seq23/app-b/pull/6#issuecomment-222
26 Nov 23:40 CT   PASS seq23/app-c#7 https://github.com/seq23/app-c/pull/7#issuecomment-333
26 Nov 23:41 CT form proof: seq23/app-c#7 (forms: contact)
27 Nov 00:10 CT   FAIL seq23/next#1 https://github.com/seq23/next/pull/1#issuecomment-444
EOF
  printf '# Post-land checks\n\n- ENG-CHECK FAIL seq23/app-a#5 abc — landed on green CI → link\n' > "$T/post-land-checks.md"
  printf 'STATUS: FAIL seq23/app-d#8 def 2026-11-26T10:00 — checks red: validate; mail owner@example.com\nGoal: g\n' > "$T/sheet-d.md"
  printf 'STATUS: FAIL seq23/app-e#9 def 2026-11-25T10:00 — old\n' > "$T/sheet-e.md"
  printf 'STATUS: DONE seq23/app-f#3 def 2026-11-26T10:00 — fine\n' > "$T/sheet-f.md"
  printf '=== land 12 (2026-11-25T09:00)\nSTOPPED: the run before, a day earlier\n=== land 12 (2026-11-26T13:00)\nmerging\nSTOPPED: main is failure after merging #12. Not deploying.\n=== land 12 (2026-11-27T08:00)\nSTOPPED: the next morning\n' > "$T/logs/land-12.log"; ctime 202611270800 "$T/logs/land-12.log"
  printf 'STOPPED: a log with no header takes its file date\n' > "$T/logs/land-11.log"; ctime 202611261500 "$T/logs/land-11.log"
  printf 'STOPPED: an old stop\n' > "$T/logs/land-10.log"; ctime 202611251400 "$T/logs/land-10.log"
  printf 'STATUS: TODO seq23/app-a#5 — fix the engineering FAIL\n' > "$T/engfix-app-a-5.md"; ctime 202611262340 "$T/engfix-app-a-5.md"
  find "$H" -type f | sort | while read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done > "$W/before"
}
# shellcheck disable=SC2120  # lp --force and lp --frobnicate are called inside eval strings
lp() { LESSONS_DAY="${LESSONS_DAY-$D}" "$LP" "$@" > "$W/out" 2>&1; echo $?; }
# shellcheck disable=SC2034  # F is read inside the eval strings below
F="$T/lessons/$D.md"
calls() { [ -f "$S/ai-calls" ] && wc -l < "$S/ai-calls" | tr -d ' ' || echo 0; }

echo "=== a real day: every source, only that Central day, one failure per PR ==="
fixture; rc="$(FAKE_MODE=ok lp)"
check "exit 0 and the day's file is complete" eval '[ "$rc" = 0 ] && grep -q "^<!-- lessons-pass:complete -->$" "$F"'
check "the prompt holds both log FAILs with their verdict reasons (one gh GET each)" eval 'grep -q "app-a#5.*verdict: Engineering check: FAIL — weekly truth" "$S/prompt" && grep -q "app-b#6.*verdict:" "$S/prompt"'
check "…the FAIL sheet dated that day and the land log STOPPED line changed that day" eval 'grep -q "sheet-d.md.*STATUS: FAIL seq23/app-d#8" "$S/prompt" && grep -q "land-12.log.*STOPPED: main is failure" "$S/prompt"'
check "…never a PASS, a form-proof start, another day's log line, sheet or land log, or a DONE sheet" \
  eval '! grep -qE "app-c#7|seq23/old#9|seq23/next#1|app-e#9|app-f#3|an old stop|the run before|the next morning" "$S/prompt"'
check "…a land log's STOPPED line takes its run header's date; a log with no header, its file's date" grep -q "land-11.log.*no header takes its file date" "$S/prompt"
check "the same PR in the log, the list and an engfix sheet is ONE failure (5 in all)" eval '[ "$(grep -cE "^[0-9]+\. \[" "$S/prompt")" = 5 ] && grep -q "post-land-check.log, engfix sheet engfix-app-a-5.md" "$S/prompt"'
check "…and the list's FAIL line rides along as context" grep -q "checked: - ENG-CHECK FAIL seq23/app-a#5" "$S/prompt"
check "emails are masked in the prompt and in the file" eval '! grep -q "@example.com" "$S/prompt" "$F" && grep -q "\[email\]" "$S/prompt"'
check "repeats are counted by code: the 2-failure group reads 2×, first" eval 'grep -A1 "^1\. \*\*2×\*\* engineering check failed on a schedule change (failures 1, 2)" "$F" | grep -q "Draft check: a test that fails a daily-to-weekly change"'
check "…a failure the model left out is still a group of one, never dropped" eval 'grep -q "\*\*1×\*\* (the model did not group this one) (failures 4)" "$F" && grep -q "\*\*1×\*\* (the model did not group this one) (failures 5)" "$F"'
check "…and every failure line is in the file" eval '[ "$(grep -cE "^[0-9]+\. \[" "$F")" = 5 ]'
check "the model runs bare: no tools, Haiku, 300 s, 2 runs a day, named caller" \
  grep -q "bare=1 model=haiku secs=300 runs=2 caller=lessons-pass" "$S/ai-how"
check "…as a brain with no --network and no --cwd (it is handed text, never a folder)" eval 'grep -q "^args=--role brain --out " "$S/ai-how" && ! grep -qE -- "--network|--cwd" "$S/ai-how"'
check "…started from its own empty temp folder, never a repo (Claude Code would show the model that folder's files)" \
  eval 'grep -q "^cwd=.*/lessons-pass\.[A-Za-z0-9]*$" "$S/ai-cwd"'
check "only the day's file was written: every rule, skill, sheet and log is byte-for-byte unchanged" eval '
  find "$H" -type f | sort | while read -r f; do printf "%s %s\n" "$(cksum < "$f")" "$f"; done > "$W/after"
  d="$(diff "$W/before" "$W/after")"; [ "$(grep -c "^[<>]" <<<"$d")" = 1 ] && grep "^> " <<<"$d" | grep -qF " $F"'
check "no temp file is left beside it" eval '[ "$(find "$T/lessons" -type f | wc -l | tr -d " ")" = 1 ]'
check "a second run on a complete day pays for no second model call" eval '[ "$(FAKE_MODE=ok lp)" = 0 ] && [ "$(calls)" = 1 ] && grep -q "already complete" "$W/out"'
check "…--force writes it again (one more call)" eval '[ "$(FAKE_MODE=ok lp --force)" = 0 ] && [ "$(calls)" = 2 ]'
check "an unknown argument is a usage error, nothing written" eval 'rm -f "$F"; [ "$(lp --frobnicate)" = 64 ] && [ ! -f "$F" ]'

echo "=== the model's numbers cannot inflate a count ==="
fixture; FAKE_MODE=bad lp >/dev/null
check "GROUP 1,1,1,99 counts 1 (repeats and out-of-range numbers dropped)" eval 'grep -q "^1\. \*\*1×\*\* inflated (failures 1)" "$F" && ! grep -q "3×\|4×" "$F"'

echo "=== outage: never a blank 'nothing failed' ==="
fixture; rc="$(FAKE_MODE=down lp)"
check "model at its usage limit: ai-run's exit (76), the stop named, every failure listed, not complete" \
  eval '[ "$rc" = 76 ] && grep -q "MODEL DID NOT SORT THESE\*\* (NAMED STOP \[CLAUDE_LIMIT\] resets 9am)" "$F" && [ "$(grep -cE "^[0-9]+\. \[" "$F")" = 5 ] && ! grep -q "lessons-pass:complete\|No failures" "$F"'
check "…and the next run tries again (an incomplete file is not 'already complete')" eval '[ "$(FAKE_MODE=ok lp)" = 0 ] && grep -q "lessons-pass:complete" "$F"'
fixture; rc="$(FAKE_MODE=junk lp)"
check "model answers junk: exit 1, named, unsorted list kept" eval '[ "$rc" = 1 ] && grep -q "the model answered nothing in the GROUP shape" "$F" && [ "$(grep -cE "^[0-9]+\. \[" "$F")" = 5 ]'
fixture; rc="$(FAKE_MODE=partial lp)"
check "model stopped by its time cap after a partial answer: exit 124, the partial groups are not trusted" \
  eval '[ "$rc" = 124 ] && grep -q "MODEL DID NOT SORT THESE\*\* (ai-run exit 124)" "$F" && ! grep -q "Draft check" "$F"'
printf '#!/bin/bash\necho x >> "$FAKE_STORE/ai-calls"\n' > "$W/bin/old-ai-run"; chmod +x "$W/bin/old-ai-run"
fixture; rc="$(LESSONS_AI_RUN="$W/bin/old-ai-run" lp)"
check "an ai-run with no AI_RUN_BARE mode (it would start Claude WITH tools) is never run: exit 69, named" \
  eval '[ "$rc" = 69 ] && [ "$(calls)" = 0 ] && grep -q "NAMED STOP \[BARE_UNSUPPORTED\]" "$F" && ! grep -q "lessons-pass:complete" "$F"'
check "a missing ai-run is not a pass" eval 'fixture; [ "$(LESSONS_AI_RUN="$W/nope" lp)" != 0 ] && ! grep -q "lessons-pass:complete" "$F"'
fixture; rc="$(FAKE_GH_DOWN=1 FAKE_MODE=ok lp)"
check "gh down: the reason is named unreadable and the night still sorts" eval '[ "$rc" = 0 ] && grep -q "verdict: (its verdict comment could not be read)" "$S/prompt"'

echo "=== Rule 0: a clean day and an unreadable day ==="
fixture; rc="$(LESSONS_DAY=2026-11-20 FAKE_MODE=ok lp)"
check "no failures that day: exit 0, no model call, the file says so and lists each source read" \
  eval '[ "$rc" = 0 ] && [ "$(calls)" = 0 ] && grep -q "No failures on 2026-11-20" "$T/lessons/2026-11-20.md" && grep -q "logs/post-land-check.log (0 lines that day" "$T/lessons/2026-11-20.md" && grep -q "^- task sheets (5 read" "$T/lessons/2026-11-20.md"'
fixture; rm "$T/logs/post-land-check.log"; LESSONS_DAY=2026-11-20 lp >/dev/null
check "a missing source is named in the file" grep -q "^- logs/post-land-check.log (No such file or directory)" "$T/lessons/2026-11-20.md"
rm -rf "$H"; mkdir -p "$H"; export rc; rc="$(LESSONS_OUT="$W/out-dir" lp)"
check "nothing readable at all: exit 2, the file says the day is NOT known clean, not complete" \
  eval '[ "$rc" = 2 ] && grep -q "NOTHING COULD BE READ" "$W/out-dir/$D.md" && ! grep -q "No failures\|lessons-pass:complete" "$W/out-dir/$D.md"'

echo "=== the Central day ==="
fixture
day_at() { LESSONS_DAY="" LESSONS_NOW="$1" FAKE_MODE=ok "$LP" >/dev/null 2>&1; ls "$T/lessons" | sed 's/\.md$//' | tail -1; rm -rf "$T/lessons"; }
check "23:15 CT is that day" [ "$(day_at 2026-11-27T23:15)" = 2026-11-27 ]
check "18:00 CT is that day" [ "$(day_at 2026-11-27T18:00)" = 2026-11-27 ]
check "17:59 CT is the day before" [ "$(day_at 2026-11-27T17:59)" = 2026-11-26 ]
check "00:30 CT (a late catch-up) is the day before" [ "$(day_at 2026-11-28T00:30)" = 2026-11-27 ]
check "the clock-change day (1 Nov 2026, 25 hours) is still one day" [ "$(day_at 2026-11-01T23:15)" = 2026-11-01 ]
check "the first of the month looks back to the last day of the one before" [ "$(day_at 2026-12-01T07:00)" = 2026-11-30 ]

echo "=== post-land-check runs it on the way out, never changing its exit ==="
mkdir -p "$W/plc"
printf '#!/bin/bash\necho "called $*" >> "%s/lessons-calls"; exit "${FAKE_LESSONS_RC:-0}"\n' "$W/plc" > "$W/bin/lessons"; chmod +x "$W/bin/lessons"
printf '#!/bin/bash\necho "$1" >> "%s/banners"\n' "$W/plc" > "$W/bin/notify"; chmod +x "$W/bin/notify"
plc() { POST_LAND_SKIP="$W/plc/no-skip" POST_LAND_DUE_FILE="$W/plc/due.md" POST_LAND_LOG="$W/plc/log" POST_LAND_LOCKS="$W/plc/locks" \
  POST_LAND_NOTIFY="$W/bin/notify" POST_LAND_TASKS="$W/plc/tasks" POST_LAND_LESSONS="$W/bin/lessons" POST_LAND_AI_RUN="$W/bin/ai-run" \
  PATH="$W/bin:$PATH" "$PLC" "$@" </dev/null >/dev/null 2>&1; echo $?; }
lcalls() { [ -f "$W/plc/lessons-calls" ] && wc -l < "$W/plc/lessons-calls" | tr -d ' ' || echo 0; }
mkdir -p "$W/plc/tasks"; printf '# Post-land checks\n\n- nothing due here\n' > "$W/plc/due.md"
check "a nightly run with nothing due (exit 0) calls lessons-pass once" eval '[ "$(plc)" = 0 ] && [ "$(lcalls)" = 1 ]'
check "lessons-pass failing (exit 3) leaves post-land-check at 0, named in its log and a banner" \
  eval '[ "$(FAKE_LESSONS_RC=3 plc)" = 0 ] && [ "$(lcalls)" = 2 ] && grep -q "NAMED STOP \[LESSONS_NOT_WRITTEN\]" "$W/plc/log" && grep -q "^Lessons pass did not finish" "$W/plc/banners"'
check "--dry-run never calls it" eval '[ "$(plc --dry-run)" = 0 ] && [ "$(lcalls)" = 2 ]'
check "--now (land's single form proof) never calls it" eval 'plc --now o/x#1 >/dev/null; [ "$(lcalls)" = 2 ]'
printf '# Post-land checks\n\n- FORM-PROOF DUE o/site#1 abc123 — forms: contact form; deployed 26 Nov 2026 10:00 CT\n' > "$W/plc/due.md"
printf '#!/bin/bash\ncase "$1 $2" in "api user") echo me;; "api --paginate") echo "[]";; *) exit 1;; esac\n' > "$W/bin/gh"; chmod +x "$W/bin/gh"
check "a night with a line left unproved keeps its own exit 1 (lessons-pass ok or failing)" \
  eval '[ "$(plc)" = 1 ] && rm -rf "$W/plc/locks" && [ "$(FAKE_LESSONS_RC=5 plc)" = 1 ] && [ "$(lcalls)" = 4 ]'

echo "lessons-pass: $passes ok, $fails failed"
[ "$passes" -gt 0 ] && [ "$fails" -eq 0 ]
