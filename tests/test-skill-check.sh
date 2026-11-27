#!/bin/bash
# skill-check against a fake ai-run, a fake gh and fixture skills, transcripts and asks; offline, no model, no money.
# Proves: a right load is PASS and a wrong one FAIL (the checker cannot always pass); two plausible skills pass on
# either; a "must not load" ask fails when that skill loads; a skill missing from Claude's listing fails; the 20
# most-loaded skills come from the transcripts and one with no asks is NOT COVERED; a usage limit (ai-run's stop, or
# Claude's own synthetic notice), a signed-out claude, a missing runner or an empty answer is COULDNT-CHECK, never
# PASS, and a limit stops the run at once; 0 asks is a FAIL with exit 2; a stale report is deleted first; the report
# is named by the Central date; every run is Skill-only, no connectors, no saved session, never the API key; a
# problem files ONE issue and a gh outage is named without changing the exit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; SC="${SC_UNDER_TEST:-$HERE/skill-check}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

mkdir -p "$W/bin" "$W/skills"/{alpha,beta,gamma} "$W/projects/p1" "$W/out"
for s in alpha beta gamma; do printf -- '---\nname: %s\ndescription: %s things\n---\n' "$s" "$s" > "$W/skills/$s/SKILL.md"; done
# Transcripts: alpha 5 loads, beta 3; gamma only in the second set (NOT COVERED case).
skill_call() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Skill","input":{"skill":"%s"}}]}}\n' "$1"; }
{ for _ in 1 2 3 4 5; do skill_call alpha; done; for _ in 1 2 3; do skill_call beta; done; skill_call retired-skill; } > "$W/projects/p1/s.jsonl"
mkdir -p "$W/projects2/p"; cp "$W/projects/p1/s.jsonl" "$W/projects2/p/"; for _ in 1 2 3 4 5 6 7 8 9; do skill_call gamma; done >> "$W/projects2/p/s.jsonl"

cat > "$W/asks.json" <<'J'
{ "skills": {
  "alpha": { "asks": [ { "ask": "a one", "expect": ["alpha"] }, { "ask": "a two", "expect": ["alpha", "beta"] }, { "ask": "a three", "expect": ["alpha"] } ], "not": "a never" },
  "beta":  { "asks": [ { "ask": "b one", "expect": ["beta"] }, { "ask": "b two", "expect": ["beta"] }, { "ask": "b three", "expect": ["beta"] } ], "not": "b never" }
} }
J
# What the fake Claude loads for each ask (ask|skills). "a two" loads beta: the second plausible skill.
cat > "$W/map" <<'M'
a one|alpha
a two|beta
a three|alpha,gamma
a never|beta
b one|beta
b two|beta
b three|beta
b never|alpha
M

cat > "$W/bin/ai-run" <<'AI'
#!/bin/bash
S="$FAKE_STORE"; echo x >> "$S/calls"
echo "args=$* caller=${AI_RUN_CALLER:-} nocredit=${AI_RUN_NO_CREDIT:-} mcp=${AI_RUN_MCP:-} bare=${AI_RUN_BARE:-} key=${ANTHROPIC_API_KEY:-} runs=${AI_RUN_MAX_RUNS:-} cl=${AI_RUN_CLAUDE_ARGS:-}" >> "$S/how"
ask="${!#}"
skills="$(grep -F -- "$ask|" "$FAKE_MAP" | head -1 | cut -d'|' -f2)"
[ -n "${FAKE_LOAD_OVERRIDE:-}" ] && case "$ask" in "${FAKE_LOAD_OVERRIDE%%=*}") skills="${FAKE_LOAD_OVERRIDE#*=}" ;; esac
listing="${FAKE_LISTING:-alpha,beta,gamma}"
init() { printf '{"type":"system","subtype":"init","tools":["Skill"],"skills":[%s]}\n' "$(printf '%s' "$listing" | sed 's/[^,][^,]*/"&"/g')"; }
case "${FAKE_MODE:-ok}" in
  ok)
    init
    content="$(printf '%s' "$skills" | tr ',' '\n' | grep . | sed 's/.*/{"type":"tool_use","id":"t","name":"Skill","input":{"skill":"&"}}/' | paste -sd, -)"
    [ -n "$content" ] || content='{"type":"text","text":"Sure, here is how I would do it."}'
    printf '{"type":"assistant","message":{"model":"claude-opus","content":[%s]}}\n' "$content"
    printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":2,"total_cost_usd":0.1,"usage":{"input_tokens":2,"cache_read_input_tokens":1000,"output_tokens":30}}\n'
    exit 1 ;;
  limit) echo "NAMED STOP [CLAUDE_LIMIT] resets 9am — the work waits for the reset; no Codex or free fallback."; exit 76 ;;
  synthetic)
    init
    printf '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your limit · resets 9am"}]}}\n'
    printf '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your limit · resets 9am","total_cost_usd":0}\n'
    exit 0 ;;
  synthonly) init; printf '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Claude usage limit reached. Your limit will reset at 9am"}]}}\n'; exit 1 ;;
  signedout) printf '{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}\n'; exit 1 ;;
  paused) echo "NAMED STOP [PAUSED] every scheduled AI job waits until 2026-12-01"; exit 75 ;;
  empty) exit 1 ;;
  kill) kill -9 "$PPID"; exit 1 ;;
esac
AI
cat > "$W/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$FAKE_STORE/gh"
[ -n "${FAKE_GH_DOWN:-}" ] && { echo "HTTP 502" >&2; exit 1; }
case "$1 $2" in "issue list") [ -n "${FAKE_GH_EXISTING:-}" ] && echo "$FAKE_GH_EXISTING"; exit 0 ;; esac
exit 0
GH
chmod +x "$W/bin/ai-run" "$W/bin/gh"

NOW=2026-11-30T05:00:00Z   # Sunday 29 Nov 23:00 Central (already Monday on an Eastern Mac, and in UTC)
run() { # run <name> [env...] -- [args]: fresh store and out per case; rc in $W/<name>.rc, stdout+stderr in .log
  local name="$1"; shift; local envs=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  rm -rf "$W/store" ; mkdir -p "$W/store"; : > "$W/store/calls"
  env FAKE_STORE="$W/store" FAKE_MAP="$W/map" SKILL_CHECK_ASKS="$W/asks.json" SKILL_CHECK_OUT="$W/out/$name" \
    SKILL_CHECK_AI_RUN="$W/bin/ai-run" SKILL_CHECK_PROJECTS="$W/projects" SKILL_CHECK_SKILLS="$W/skills" \
    SKILL_CHECK_GH="$W/bin/gh" SKILL_CHECK_NOW="$NOW" SKILL_CHECK_CWD="$W" ANTHROPIC_API_KEY=sk-should-be-dropped \
    ${envs[@]+"${envs[@]}"} node "$SC" "$@" > "$W/$name.log" 2>&1
  echo $? > "$W/$name.rc"
  cp "$W/store/calls" "$W/$name.calls"; [ -f "$W/store/gh" ] && cp "$W/store/gh" "$W/$name.gh"; [ -f "$W/store/how" ] && cp "$W/store/how" "$W/$name.how"
  return 0
}
rc() { [ "$(cat "$W/$1.rc")" = "$2" ]; }
R() { echo "$W/out/$1/2026-11-29.md"; }

echo "=== 1. every ask right: 8 PASS lines, exit 0, COMPLETE, no issue; the second plausible skill passes ==="
run ok
check "exit 0 (got $(cat "$W/ok.rc"))" rc ok 0
check "report named by the Central date" test -f "$(R ok)"
check "8 PASS lines" [ "$(count "$(R ok)" '^- PASS')" = 8 ]
check "no FAIL or COULDNT-CHECK line" hasnt "$(R ok)" "- FAIL"
check "'a two' passed on beta, the second plausible skill" has "$(R ok)" '- PASS · alpha · should load · "a two" → loaded: beta'
check "every loaded skill recorded (alpha and gamma)" has "$(R ok)" '"a three" → loaded: alpha, gamma'
check "COMPLETE sentinel" has "$(R ok)" "SKILL-CHECK-COMPLETE: 8 asks checked"
check "census line" has "$W/ok.log" "OUTPUT 8 asks checked: 8 right, 0 wrong, 0 not checked (100% right)"
check "8 runs" [ "$(wc -l < "$W/ok.calls" | tr -d ' ')" = 8 ]
check "no issue on an all-right run" test ! -f "$W/ok.gh"
check "ranking read from the transcripts (alpha 5 first; retired skill dropped)" has "$(R ok)" "1. alpha (5)"
check "retired skill not ranked" hasnt "$(R ok)" "retired-skill"
check "runs go through ai-run as brain" has "$W/ok.how" "args=--role brain -- a one"
check "Skill is the only tool, two turns, no saved session" has "$W/ok.how" "cl=--tools Skill --max-turns 2 --output-format stream-json --verbose --no-session-persistence"
check "never the API key: AI_RUN_NO_CREDIT=1 and the key dropped" has "$W/ok.how" "nocredit=1 mcp=none bare= key= runs="
check "caller is skill-check" has "$W/ok.how" "caller=skill-check"

echo "=== 2. a misfire: the right skill does not load -> FAIL, exit 1, one issue ==="
run miss FAKE_LOAD_OVERRIDE="a one="
check "exit 1" rc miss 1
check "FAIL line names what was expected" has "$(R miss)" '- FAIL · alpha · should load · "a one" → loaded: nothing (expected alpha)'
check "7 PASS lines, not 8" [ "$(count "$(R miss)" '^- PASS')" = 7 ]
check "Wrong section names alpha" has "$(R miss)" "- alpha: 1 wrong"
check "one issue filed" has "$W/miss.gh" "issue create -R seq23/seq-bin --title skill-check 2026-11-29: 1 wrong"
check "issue body carries no ask lines (public repo)" hasnt "$W/miss.gh" "should load"

echo "=== 3. a must-not-load ask loads the skill -> FAIL ==="
run neg FAKE_LOAD_OVERRIDE="b never=beta"
check "exit 1" rc neg 1
check "negative FAIL" has "$(R neg)" '- FAIL · beta · must not load · "b never" → loaded: beta (beta loaded for an ask it does not cover)'
run neg2 FAKE_LOAD_OVERRIDE="b never="
check "negative with nothing loaded is a PASS" has "$(R neg2)" '- PASS · beta · must not load · "b never" → loaded: nothing'

echo "=== 4. a skill missing from Claude's listing fails even if the name is called ==="
run unlisted FAKE_LISTING=beta,gamma
check "exit 1" rc unlisted 1
check "names the missing listing" has "$(R unlisted)" "(alpha is not in the skill listing Claude was given)"

echo "=== 5. usage limit (ai-run's stop): COULDNT-CHECK, stops at once, 0 PASS, exit 75 ==="
mkdir -p "$W/out/limit"; for _ in $(seq 1 99); do echo "- PASS stale"; done > "$W/out/limit/2026-11-29.md"
run limit FAKE_MODE=limit
check "exit 75" rc limit 75
check "stale report deleted first: 0 PASS lines" [ "$(count "$(R limit)" PASS)" = 0 ]
check "one run only: the limit stops the rest" [ "$(wc -l < "$W/limit.calls" | tr -d ' ')" = 1 ]
check "first ask COULDNT-CHECK with the reason" has "$(R limit)" "- COULDNT-CHECK · alpha · should load · \"a one\" → her plan's usage limit was reached"
check "the rest not run" [ "$(count "$(R limit)" 'not run: her plan')" = 7 ]
check "Result says FAIL, nothing proven" has "$(R limit)" "Result: FAIL — 0 of 8 asks could be checked"
check "INCOMPLETE sentinel, never COMPLETE" has "$(R limit)" "SKILL-CHECK-INCOMPLETE: 0 of 8 asks checked"
check "named stop" has "$W/limit.log" "NAMED STOP [NOTHING_CHECKED]"
check "issue filed for the unchecked run" has "$W/limit.gh" "8 not checked"

mkdir -p "$W/out/killed"; for _ in $(seq 1 99); do echo "- PASS stale"; done > "$W/out/killed/2026-11-29.md"
run killed FAKE_MODE=kill
check "a run killed midway leaves no report, never last run's" test ! -f "$(R killed)"

echo "=== 6. Claude's own synthetic limit notice (exit 0) is COULDNT-CHECK, not FAIL ==="
run synth FAKE_MODE=synthetic
check "exit 75" rc synth 75
check "no FAIL line" hasnt "$(R synth)" "- FAIL"
check "limit named" has "$(R synth)" "her plan's usage limit was reached"
check "stopped after one run" [ "$(wc -l < "$W/synth.calls" | tr -d ' ')" = 1 ]

run synthonly FAKE_MODE=synthonly
check "synthetic notice with no result event: limit named" has "$(R synthonly)" "her plan's usage limit was reached"
check "...and it stops the run" [ "$(wc -l < "$W/synthonly.calls" | tr -d ' ')" = 1 ]

echo "=== 7. signed out / paused / runner missing / empty answer: COULDNT-CHECK ==="
run out FAKE_MODE=signedout
check "signed out: exit 75" rc out 75
check "signed out named" has "$(R out)" "claude is not signed in"
run paused FAKE_MODE=paused
check "paused: exit 75, one run" rc paused 75
check "paused named" has "$(R paused)" "ai-pause is on"
run empty FAKE_MODE=empty
check "empty: exit 75" rc empty 75
check "empty answers are not a wall: every ask tried" [ "$(wc -l < "$W/empty.calls" | tr -d ' ')" = 8 ]
check "empty: 0 PASS" [ "$(count "$(R empty)" PASS)" = 0 ]
run norunner SKILL_CHECK_AI_RUN="$W/bin/no-such-runner"
check "missing runner: exit 75" rc norunner 75
check "missing runner named" has "$(R norunner)" "no-such-runner is missing"

echo "=== 8. Rule 0: 0 asks is a FAIL, exit 2; a bad or missing asks file is exit 2 ==="
echo '{ "skills": {} }' > "$W/empty-asks.json"
run noasks SKILL_CHECK_ASKS="$W/empty-asks.json"
check "exit 2" rc noasks 2
check "named stop" has "$W/noasks.log" "NAMED STOP [NO_ASKS_RAN]"
check "report says FAIL, 0 PASS" has "$(R noasks)" "Result: FAIL — NAMED STOP [NO_ASKS_RAN]"
check "no model run" [ ! -s "$W/noasks.calls" ]
run only0 -- --only nosuch
check "--only with no matching skill: exit 2" rc only0 2
echo '{ "skills": { "alpha": { "asks": [ { "ask": "x", "expect": ["alpha"] } ], "not": "y" } } }' > "$W/short-asks.json"
run short SKILL_CHECK_ASKS="$W/short-asks.json"
check "fewer than 3 asks: exit 2 ASKS_INVALID" rc short 2
check "ASKS_INVALID named" has "$W/short.log" "NAMED STOP [ASKS_INVALID]"
run noasksfile SKILL_CHECK_ASKS="$W/missing.json"
check "missing asks file: exit 2" rc noasksfile 2

echo "=== 9. a top skill with no asks is NOT COVERED, exit 1 ==="
run cover SKILL_CHECK_PROJECTS="$W/projects2"
check "exit 1" rc cover 1
check "gamma NOT COVERED" has "$(R cover)" "- NOT COVERED gamma (9 loads)"
check "issue says not covered" has "$W/cover.gh" "1 not covered"

echo "=== 10. --only re-runs one skill into its own file ==="
run only -- --only beta
check "exit 0" rc only 0
check "only beta's 4 asks ran" [ "$(wc -l < "$W/only.calls" | tr -d ' ')" = 4 ]
check "own file" test -f "$W/out/only/2026-11-29-only.md"
check "a same-day re-run keeps the full run's day cap (8 asks x2 +10), not its own 4 asks" has "$W/only.how" "runs=26 cl="
check "weekly file untouched" test ! -f "$(R only)"

echo "=== 11. gh down: the stop is named, the exit stays 1; an open issue gets a comment ==="
run ghdown FAKE_LOAD_OVERRIDE="a one=" FAKE_GH_DOWN=1
check "exit 1 kept" rc ghdown 1
check "ISSUE_UNFILED named" has "$W/ghdown.log" "NAMED STOP [ISSUE_UNFILED]"
run ghopen FAKE_LOAD_OVERRIDE="a one=" FAKE_GH_EXISTING=7
check "comments on the open issue" has "$W/ghopen.gh" "issue comment 7 -R seq23/seq-bin"
check "the open issue is found by exact title from a plain list, not the lagging search" hasnt "$W/ghopen.gh" "--search"

echo "=== 12. Central date edges ==="
run early SKILL_CHECK_NOW=2026-11-29T05:59:00Z
check "23:59 Saturday Central is the 28th" test -f "$W/out/early/2026-11-28.md"
run dst SKILL_CHECK_NOW=2026-03-09T04:30:00Z
check "the night of the spring clock change is still the 8th" test -f "$W/out/dst/2026-03-08.md"

echo
echo "skill-check: $passes passed, $fails failed"
[ "$passes" -ge 60 ] || { echo "NAMED STOP [TOO_FEW_CHECKS] only $passes checks ran"; exit 1; }
[ "$fails" -eq 0 ]
