#!/bin/bash
# token-report against fixture transcripts: counts each API call once, measures what tool results carried,
# never prints message text, commands, an email or a key, and stops by name when there is nothing to read.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TR="${TOKEN_REPORT_UNDER_TEST:-$ROOT/token-report.mjs}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export TOKEN_REPORT_DIR="$W/measure" TOKEN_REPORT_BOSS=off
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
FAKE_KEY="ghp_Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0LmNbVc"
FAKE_MAIL="lp.person@example-fund.com"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

P="$W/projects/-Users-x-GitHub-demo-repo"; mkdir -p "$P/sess1/subagents"
asst() { # id in cacheRead cacheWrite out [tool_use json]
  printf '{"parentUuid":null,"type":"assistant","timestamp":"%s","cwd":"/Users/x/GitHub/demo-repo","message":{"id":"%s","model":"claude-opus-5-5","content":[%s],"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s}}}\n' "$NOW" "$1" "${6:-}" "$2" "$3" "$4" "$5"
}
result() { # tool_use_id text
  printf '{"parentUuid":null,"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}}\n' "$NOW" "$1" "$2"
}
BIG="$(printf 'x%.0s' $(seq 1 4000))"   # 4000 chars = 1000 tokens
{
  printf '{"type":"ai-title","aiTitle":"Send the deck to %s with key %s","sessionId":"s"}\n' "$FAKE_MAIL" "$FAKE_KEY"
  printf '{"parentUuid":null,"type":"user","timestamp":"%s","message":{"role":"user","content":"please email %s the key %s"}}\n' "$NOW" "$FAKE_MAIL" "$FAKE_KEY"
  asst m1 10 100 0 5 '{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo '"$FAKE_KEY"' | mail '"$FAKE_MAIL"'"}}'
  asst m1 10 100 0 5 '{"type":"text","text":"same call, second block"}'         # same message id: counted once
  result t1 "$BIG $FAKE_MAIL $FAKE_KEY"
  asst m2 1 1000 0 5 '{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"gh pr checks 5"}}'
  result t2 "short"
  asst m3 1 2000 0 5
  asst m4 1 3000 0 5
  printf '{"parentUuid":null,"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n'
  asst m5 1 100 0 5
  printf '{"type":"api-request-blob","sessionId":"s","message":"%s"}\n' "$FAKE_KEY"
} > "$P/sess1.jsonl"
{
  asst a1 5 0 50 5 '{"type":"tool_use","id":"u1","name":"mcp__claude-in-chrome__computer","input":{"action":"screenshot"}}'
  printf '{"parentUuid":null,"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"u1","content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}]}}\n' "$NOW"
  asst a2 5 2000 0 5
} > "$P/sess1/subagents/agent-abc123.jsonl"
printf '{"agentType":"builder","description":"Fix %s login for %s","finished":true}\n' "$FAKE_KEY" "$FAKE_MAIL" > "$P/sess1/subagents/agent-abc123.meta.json"

out="$(node "$TR" --root "$W/projects" --days 1 --out "$W/r.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "a fixture run writes (exit 0)" || bad "fixture run (rc $rc: $out)"
all="$out$(cat "$W/r.json" 2>/dev/null)"
grep -qF "$FAKE_KEY" <<<"$all" && bad "the fake key appears in the output" || ok "the fake key never appears (table or JSON)"
grep -qF "$FAKE_MAIL" <<<"$all" && bad "the email appears in the output" || ok "the email never appears (table or JSON)"
grep -qE "please email|same call|gh pr checks|echo |xxxx" <<<"$all" && bad "message text, a command or tool output appears" || ok "no message text, command or tool output appears"
grep -q '\[email\]' "$W/r.json" && grep -q '\[secret\]' "$W/r.json" && ok "the title and description keep their shape with [email] and [secret]" || bad "masking markers missing"
j() { node -e "const r=require('$W/r.json'); console.log(JSON.stringify($1))"; }
[ "$(j "r.rows.find(x=>x.kind==='main').calls")" = 5 ] && ok "a message split over two lines is one API call (5 calls, not 6)" || bad "dedupe: calls $(j "r.rows.find(x=>x.kind==='main').calls")"
[ "$(j "r.rows.find(x=>x.kind==='main').tokens")" = 6239 ] && ok "tokens = input + cache read + cache write + output, each call once (6239)" || bad "tokens $(j "r.rows.find(x=>x.kind==='main').tokens")"
# t1 (1000+ tokens) entered before m2; m2, m3, m4 re-read it; the compaction ends its carry before m5.
carried="$(j "r.rows.find(x=>x.kind==='main').causes.find(c=>c.cause==='Bash').carried")"
[ "$carried" -gt 3000 ] && [ "$carried" -lt 3100 ] && ok "a result is carried by each later call until the compaction (3 × ~1010)" || bad "carry $carried"
[ "$(j "r.rows.find(x=>x.kind==='main').causes.some(c=>c.cause==='gh')")" = true ] && ok "a gh command is its own cause" || bad "gh cause"
[ "$(j "r.rows.find(x=>x.kind==='subagent').role")" = '"builder"' ] && [ "$(j "r.rows.find(x=>x.kind==='subagent').causes[0].cause")" = '"screenshots/images"' ] \
  && ok "a subagent row carries its agent type, and a screenshot is counted as an image" || bad "subagent row"
[ "$(j "r.rows.find(x=>x.kind==='main').repo")" = '"demo-repo"' ] && ok "the repo is named from the session's folder" || bad "repo"
grep -q '^OUTPUT token-report 2 jobs ' <<<"$out" && ok "census line OUTPUT token-report 2 jobs" || bad "census line"
[ "$(j "r.bossOs.read")" = false ] && grep -q '"why": "not read' "$W/r.json" && grep -q 'Boss OS ledger: not read' <<<"$out" && ok "Boss OS switched off reads 'not read', never 0" || bad "boss off"
out2="$(TOKEN_REPORT_BOSS=on TOKEN_REPORT_BOSS_CWD="$W/nowhere" node "$TR" --root "$W/projects" --days 1 --out "$W/r2.json" 2>&1)"
grep -q 'Boss OS ledger: not read: ' <<<"$out2" && ok "a Boss OS read that fails is 'not read: <why>', never 0" || bad "boss outage ($(grep 'Boss OS' <<<"$out2"))"

# Rule 0: nothing to read is a named stop, never an empty all-fine.
mkdir -p "$W/empty"; out="$(node "$TR" --root "$W/empty" --days 1 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -q 'NAMED STOP \[NO_TRANSCRIPTS\]' <<<"$out" && grep -q 'OUTPUT token-report 0 jobs' <<<"$out" && ok "no transcripts: exit 3, NAMED STOP [NO_TRANSCRIPTS]" || bad "no transcripts (rc $rc: $out)"
out="$(node "$TR" --root "$W/missing" --days 1 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "an unreadable folder: exit 3" || bad "missing folder rc $rc"
mkdir -p "$W/garble/p"; printf 'not json\n{"parentUuid":null,"type":"assistant","message":{"content":[]}}\n' > "$W/garble/p/s.jsonl"
out="$(node "$TR" --root "$W/garble" --days 1 2>&1)"; rc=$?
[ "$rc" = 4 ] && grep -q 'NAMED STOP \[UNREADABLE_FORMAT\]' <<<"$out" && ok "transcripts with no readable usage: exit 4, UNREADABLE_FORMAT" || bad "format (rc $rc: $out)"
out="$(node "$TR" --root "$W/projects" --days 1 --min-rows 5 2>&1)"; rc=$?
[ "$rc" = 5 ] && grep -q 'NAMED STOP \[TOO_FEW_ROWS\]' <<<"$out" && ok "fewer jobs than the minimum: exit 5, TOO_FEW_ROWS" || bad "min rows (rc $rc)"

# --compare: a third or more is WORKING; less is NOT WORKING; too few runs is NOT CHECKED; the mix cannot fake a cut.
mk() { # file builder_tokens n_builders reviewer_tokens n_reviewers
  node -e "const rows=[];for(let i=0;i<$3;i++)rows.push({role:'builder',finished:true,tokens:$2});for(let i=0;i<$5;i++)rows.push({role:'reviewer',finished:true,tokens:$4});require('fs').writeFileSync('$1',JSON.stringify({rows}))"
}
mk "$W/base.json" 30000000 10 4000000 10
mk "$W/cut.json" 18000000 10 2500000 10
mk "$W/flat.json" 27000000 10 3800000 10
mk "$W/mix.json" 30000000 3 4000000 40          # same per-run costs, far more cheap reviews
mk "$W/few.json" 1000 1 1000 1
cmp_() { out="$(node "$TR" --compare "$W/base.json" --current "$1" 2>&1)"; rc=$?; }
cmp_ "$W/cut.json"; [ "$rc" = 0 ] && grep -q '^VERDICT: WORKING' "$W/measure/tokens-compare.txt" && ok "a 40% cut is WORKING (exit 0)" || bad "cut (rc $rc: $out)"
cmp_ "$W/flat.json"; [ "$rc" = 1 ] && grep -q '^VERDICT: NOT WORKING' "$W/measure/tokens-compare.txt" && ok "a 7% cut is NOT WORKING (exit 1)" || bad "flat (rc $rc: $out)"
cmp_ "$W/mix.json"; [ "$rc" = 1 ] && ok "more cheap reviews and fewer builds is NOT a cut (baseline mix)" || bad "mix faked a cut (rc $rc: $out)"
cmp_ "$W/few.json"; [ "$rc" = 6 ] && grep -q '^VERDICT: NOT CHECKED' "$W/measure/tokens-compare.txt" && ok "too few runs is NOT CHECKED (exit 6), never WORKING" || bad "few (rc $rc: $out)"
out="$(node "$TR" --compare "$W/nope.json" --current "$W/cut.json" 2>&1)"; rc=$?
[ "$rc" = 6 ] && grep -q 'NAMED STOP \[BASELINE_UNREAD\]' <<<"$out" && ok "a missing baseline is a named stop, not checked" || bad "baseline missing (rc $rc)"

# --nightly: the Mac's window first; then the day, the week against the baseline, and old daily files pruned.
mkdir -p "$W/mw"; printf '#!/bin/bash\necho "OUTSIDE_WINDOW x ANY"; exit 1\n' > "$W/mw/out"; printf '#!/bin/bash\nexit 5\n' > "$W/mw/bad"; printf '#!/bin/bash\nexit 0\n' > "$W/mw/in"; chmod +x "$W/mw/"*
export TOKEN_REPORT_DIR="$W/night"; mkdir -p "$W/night"
out="$(TOKEN_REPORT_MAC_WINDOW="$W/mw/out" node "$TR" --nightly --root "$W/projects" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q OUTSIDE_WINDOW <<<"$out" && [ -z "$(ls "$W/night")" ] && ok "nightly outside the Mac's window waits: reads nothing, writes nothing" || bad "nightly outside window (rc $rc: $out)"
out="$(TOKEN_REPORT_MAC_WINDOW="$W/mw/bad" node "$TR" --nightly --root "$W/projects" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -q 'NAMED STOP \[MAC_WINDOW_UNREAD\]' <<<"$out" && ok "an unreadable window check is a named stop (exit 3)" || bad "nightly window unread (rc $rc)"
cp "$W/base.json" "$W/night/tokens-baseline-2026-11-28.json"; : > "$W/night/tokens-2026-09-01.json"; touch -t 202609010000 "$W/night/tokens-2026-09-01.json" "$W/night/tokens-baseline-2026-11-28.json"
out="$(TOKEN_REPORT_MAC_WINDOW="$W/mw/in" TOKEN_REPORT_BASELINE="$W/night/tokens-baseline-2026-11-28.json" node "$TR" --nightly --root "$W/projects" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^OUTPUT token-report 2 jobs' <<<"$out" && grep -q '^VERDICT: NOT CHECKED' "$W/night/tokens-compare.txt" \
  && ok "nightly writes the day and a compare verdict (too few runs here: NOT CHECKED, never WORKING)" || bad "nightly run (rc $rc: $out)"
[ ! -e "$W/night/tokens-2026-09-01.json" ] && [ -e "$W/night/tokens-baseline-2026-11-28.json" ] && ok "a daily file past 60 days goes; the baseline stays" || bad "prune"
out="$(TOKEN_REPORT_MAC_WINDOW="$W/mw/in" TOKEN_REPORT_BASELINE="$W/none.json" node "$TR" --nightly --root "$W/projects" 2>&1)"
grep -q 'compare: NAMED STOP \[BASELINE_UNREAD\]' <<<"$out" && ok "nightly with no baseline says so by name" || bad "nightly no baseline"

[ "$fails" -eq 0 ] && echo "PASS test-token-report" || { echo "FAIL test-token-report ($fails)"; exit 1; }
