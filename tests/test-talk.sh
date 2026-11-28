#!/bin/bash
# talk, against stub `claude` and `npm` (the Boss OS vault, faked) through the real ai-run.
# What is under test (her words 27 Nov 2026: "keep working with Claude on the free $200 API credit when her
# plan runs out"; "Never a paid API"; the credit "stops at $0, no auto-reload"):
#   · at or past $200 used this credit month, or under $1 left, or the usage log unreadable or missing: NO
#     vault call and NO claude call, a plain line, exit 76 (used up) or 69 (couldn't read);
#   · the credit month starts on the 27th: a run on the 26th is last month's, the 27th's is this month's,
#     and the reset date rolls over the year;
#   · a turn runs claude -p on the key from HOME, with --continue (none with --new), her settings (no
#     permission flag of ours), and at most what is left as --max-budget-usd; the plan is never asked;
#   · the reply shows while it is written, then "this turn ~$X.XX · used this month $Y.YY of $200";
#   · the API's own $0 stop, a turn that reaches the budget, the network down and a locked vault each end
#     with one plain line, exit 76, after ONE claude call at most (no retry);
#   · the key's value is in no argument, output, file or log, even when claude prints it;
#   · a stop by her (TERM) ends claude too; --help says what it does; AI_RUN_CREDIT_NOW is talk's alone.
# RULE 0: zero assertions is a failure.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TALK="$ROOT/talk"
[ -x "$TALK" ] && [ -x "$ROOT/ai-run" ] || { echo "NAMED STOP [MISSING] $TALK or $ROOT/ai-run is missing or not executable."; exit 3; }

TMP="$(mktemp -d)"; trap 'pkill -f "$TMP" 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
asserts=0; failed=0
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check()  { local w="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$w"; else bad "$w"; fi; }
absent() { local w="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$w"; else ok "$w"; fi; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/claude-args.log"
cat > "$FAKE/claude-stdin"; pwd > "$FAKE/claude-pwd"
[ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "PLAN-RAN"; exit 0; }
init() { printf '{"type":"system","subtype":"init","apiKeySource":"ANTHROPIC_API_KEY","model":"m"}\n'; }
say()  { printf '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"%s"}]}}\n' "$1"; }
res()  { printf '{"type":"result","subtype":"%s","is_error":%s,"result":"%s","total_cost_usd":%s,"api_error_status":%s,"session_id":"%s"}\n' "$1" "$2" "$3" "$4" "${5:-null}" "${FAKE_SID:-11111111-2222-3333-4444-555555555555}"; }
init
case "$(cat "$FAKE/mode" 2>/dev/null)" in
  slow)    say "FIRST-PART"; echo started > "$FAKE/started"
           for _ in $(seq 1 100); do [ -e "$FAKE/go" ] && break; sleep 0.2; done
           say "SECOND-PART"; res success false "SECOND-PART" 0.02; exit 0 ;;
  hang)    say "FIRST-PART"; echo started > "$FAKE/started"; sleep 60 & wait $!; echo never ;;
  tools)   printf '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status","description":"Show status"}}]}}\n'
           printf '{"type":"assistant","parent_tool_use_id":"t1","message":{"content":[{"type":"text","text":"SUBAGENT-TEXT"}]}}\n'
           say "AFTER-TOOL"; res success false "AFTER-TOOL" 0.03; exit 0 ;;
  leak)    echo "debug: key $ANTHROPIC_API_KEY" >&2; say "my key is $ANTHROPIC_API_KEY"; res success false "my key is $ANTHROPIC_API_KEY" 0.01; exit 0 ;;
  low)     res success true "Credit balance is too low to access the Anthropic API." 0 400; exit 1 ;;
  netdown) res success true "API Error: Connection error." 0; exit 1 ;;
  budget)  say "PARTIAL"; res error_max_budget_usd true "" 0.5; exit 1 ;;
  *)       say "TALK-REPLY one"; res success false "TALK-REPLY one" 0.0123; exit 0 ;;
esac
SH
cat > "$BIN/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/npm-args.log"
[ "$1 $2 $3 $4" = "run -s vault:run --" ] || { echo "fake npm: unexpected: $*" >&2; exit 2; }
shift 4
export npm_lifecycle_event=vault:run
case "$(cat "$FAKE/vault-mode" 2>/dev/null)" in
  locked) echo "VAULT GATE: No vault master key in Keychain. Run \`vault:init\` first." >&2; exit 1 ;;
  *) ANTHROPIC_API_KEY="$(cat "$FAKE/key")"; export ANTHROPIC_API_KEY; "$@"; exit $? ;;
esac
SH
chmod +x "$BIN"/*
KEY="sk-ant-api03-FAKE-talk-test-only-4e1a"; printf '%s' "$KEY" > "$TMP/key"
mkdir -p "$TMP/home" "$TMP/boss-os" "$TMP/tmp"
LOG="$TMP/ai-run.log"
export FAKE="$TMP" AI_RUN_LOG="$LOG" AI_RUN_VAULT_REPO="$TMP/boss-os" AI_RUN_PAUSE_FILE="$TMP/no-pause" TMPDIR="$TMP/tmp"
NOW="$(date +%Y-%m-%d)"   # ai-run stamps each turn with the real date, so a test that runs a turn spends on today
reset() { rm -f "$TMP/home/.boss-os/talk-session" "$TMP"/claude-* "$TMP"/npm-* "$TMP/mode" "$TMP/vault-mode" "$TMP/started" "$TMP/go" "$TMP/so"; : > "$LOG"; }
run() { env PATH="$BIN:$PATH" HOME="$TMP/home" "$@"; }
spent() { # spent <date> <cost> [caller]: one credit run in the usage log
  printf '%sT10:00:00-0600\trole=brain\tengine=claude-credit\tcaller=%s\texit=0\tcost_usd=%s\tkey_source=ANTHROPIC_API_KEY\n' "$1" "${3:-ship-review}" "$2" >> "$LOG"
}
calls() { [ -s "$TMP/$1-args.log" ] && wc -l < "$TMP/$1-args.log" | tr -d ' ' || echo 0; }

echo "=== 1. the money stop: at \$200, past it, or under \$1 left, nothing is called ==="
for case in "200.00" "150 50.5" "199.01"; do
  reset; for c in $case; do spent 2026-11-27 "$c"; done
  TALK_TODAY=2026-11-28 run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
  check "[$case] exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
  check "[$case] the plain used-up line, with the reset date" grep -qxF "The free API credit is used up for this month; it resets on 27 Dec 2026." "$TMP/so"
  check "[$case] neither the vault nor claude was called" [ "$(calls npm)$(calls claude)" = 00 ]
done
reset; spent 2026-11-27 198.99
TALK_TODAY=2026-11-28 run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
check "\$1.01 left is over the floor: the turn runs (rc=$rc)" [ "$rc" -eq 0 ]
check "…with at most what is left as its budget" grep -qF -- "--max-budget-usd 1.01" "$TMP/claude-args.log"

echo "=== 2. couldn't read the credit: never guessed free ==="
reset; chmod 000 "$LOG"
run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?; chmod 644 "$LOG"
if [ -r "$LOG" ] && [ "$(id -u)" = 0 ]; then ok "(root reads any file: the unreadable case is the missing one below)"; else
  check "an unreadable usage log: exit 69 (rc=$rc)" [ "$rc" -eq 69 ]
  check "…says couldn't read the credit" grep -qF "couldn't read the credit" "$TMP/so"
  check "…and called nothing" [ "$(calls npm)$(calls claude)" = 00 ]
fi
reset; rm -f "$LOG"
run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
check "a missing usage log: exit 69 (rc=$rc)" [ "$rc" -eq 69 ]
check "…and called nothing" [ "$(calls npm)$(calls claude)" = 00 ]
check "…says couldn't read the credit" grep -qF "couldn't read the credit" "$TMP/so"

echo "=== 3. the credit month starts on the 27th ==="
reset; spent 2026-11-26 150; spent 2026-11-27 199.5
TALK_TODAY=2026-11-26 run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
check "on 26 Nov the month began 27 Oct, so only the 26th's \$150 counts: the turn runs (rc=$rc)" [ "$rc" -eq 0 ]
check "…its budget is \$200 - \$150" grep -qF -- "--max-budget-usd 50.00" "$TMP/claude-args.log"
: > "$TMP/claude-args.log"; : > "$TMP/npm-args.log"
TALK_TODAY=2026-11-27 run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
check "on the 27th, the 26th's \$150 is last month's but the 27th's \$199.50 counts: used up (rc=$rc)" [ "$rc" -eq 76 ]
check "…resets on 27 Dec 2026" grep -qF "resets on 27 Dec 2026." "$TMP/so"
reset; spent 2026-12-27 200
TALK_TODAY=2026-12-28 run "$TALK" "hello" > "$TMP/so" 2>&1
check "on 28 Dec the reset date rolls into the next year (27 Jan 2027)" grep -qF "resets on 27 Jan 2027." "$TMP/so"
reset; spent 2026-12-27 200
TALK_TODAY=2027-01-05 run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
check "on 5 Jan the month began on 27 Dec, in the year before: used up (rc=$rc)" [ "$rc" -eq 76 ]
reset; printf '%sT10:00:00-0600\trole=brain\tengine=claude-credit\tcaller=x\texit=76\tcredit=TIME_CAP\tcost_usd=unknown\n' "$NOW" >> "$LOG"
run "$TALK" "hello" > "$TMP/so" 2>&1
check "a run of unknown cost is said, never counted as free" grep -qF "used this month at least \$0.01 (1 run(s) of unknown cost) of \$200.00" "$TMP/so"

echo "=== 4. a turn: the key, from HOME, carrying on, her settings, the cost line ==="
reset; spent "$NOW" 12.5
run "$TALK" "what did I say" > "$TMP/so" 2>&1; rc=$?
check "exit 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "exactly one claude call and one vault call (the plan is never asked)" [ "$(calls claude)$(calls npm)" = 11 ]
check "the reply is shown once" [ "$(grep -c 'TALK-REPLY one' "$TMP/so")" -eq 1 ]
check "the cost line" grep -qxF "this turn ~\$0.01 · used this month \$12.51 of \$200.00" "$TMP/so"
check "claude ran in HOME" [ "$(cat "$TMP/claude-pwd")" = "$TMP/home" ]
check "with -p and --continue" grep -qE -- '^-p .*--continue' "$TMP/claude-args.log"
check "…and the message on stdin" [ "$(cat "$TMP/claude-stdin")" = "what did I say" ]
absent "with no permission flag of its own (her settings decide)" grep -qE -- '--dangerously-skip-permissions|--permission-mode' "$TMP/claude-args.log"
check "the usage log has the turn as caller=talk with its cost" grep -qE $'engine=claude-credit\tcaller=talk\texit=0\tcost_usd=0.012300' "$LOG"
echo "--- talk's own conversation"
: > "$TMP/claude-args.log"
FAKE_SID=99999999-8888-7777-6666-555555555555 run "$TALK" "turn two" > "$TMP/so" 2>&1
check "turn 2 resumes turn 1's session by its id, never the newest in HOME" grep -qE -- '--resume 11111111-2222-3333-4444-555555555555 ' "$TMP/claude-args.log"
absent "…with no --continue" grep -qF -- "--continue" "$TMP/claude-args.log"
check "…and the id kept is now turn 2's" grep -qE '^99999999-8888-7777-6666-555555555555 [0-9]+$' "$TMP/home/.boss-os/talk-session"
printf '11111111-2222-3333-4444-555555555555 %s\n' "$(( $(date +%s) - 43300 ))" > "$TMP/home/.boss-os/talk-session"; : > "$TMP/claude-args.log"
run "$TALK" "next day" > "$TMP/so" 2>&1
check "a talk session older than 12 hours is left: --continue her latest" grep -qF -- "--continue" "$TMP/claude-args.log"
printf 'not-an-id; rm -rf / 1\n' > "$TMP/home/.boss-os/talk-session"; : > "$TMP/claude-args.log"
run "$TALK" "bad state" > "$TMP/so" 2>&1
absent "a state file that is not a session id is never passed on" grep -qF -- "--resume" "$TMP/claude-args.log"
reset; spent "$NOW" 1; mkdir -p "$TMP/home/.boss-os"; printf '11111111-2222-3333-4444-555555555555 %s\n' "$(date +%s)" > "$TMP/home/.boss-os/talk-session"
run "$TALK" --new "fresh" > "$TMP/so" 2>&1
absent "--new starts fresh: no --continue and no --resume" grep -qE -- "--continue|--resume" "$TMP/claude-args.log"
reset; spent "$NOW" 1
printf 'from a pipe\n' | run "$TALK" > "$TMP/so" 2>&1; rc=$?
check "the message from stdin: exit 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "…and claude was handed it" grep -qxF "from a pipe" "$TMP/claude-stdin"
reset; spent "$NOW" 1; echo tools > "$TMP/mode"
run "$TALK" "use a tool" > "$TMP/so" 2>&1
check "a tool use is one short line" grep -qxF "  · Bash Show status" "$TMP/so"
absent "a subagent's own text is not shown as the reply" grep -qF "SUBAGENT-TEXT" "$TMP/so"
reset; spent "$NOW" 1; TALK_MODEL=haiku run "$TALK" "hi" > "$TMP/so" 2>&1
check "TALK_MODEL picks the model" grep -qF -- "--model haiku" "$TMP/claude-args.log"

echo "=== 5. the reply shows while it is written ==="
reset; spent "$NOW" 1; echo slow > "$TMP/mode"
env PATH="$BIN:$PATH" HOME="$TMP/home" "$TALK" "long one" > "$TMP/so" 2>&1 &
TP=$!
for _ in $(seq 1 50); do grep -qF FIRST-PART "$TMP/so" 2>/dev/null && break; sleep 0.2; done
check "the first part is on screen before claude has finished" grep -qF FIRST-PART "$TMP/so"
absent "…and the second part is not yet" grep -qF SECOND-PART "$TMP/so"
# the key in no process argument while the turn runs
check "the key's value is in no process's arguments while the turn runs" bash -c "! ps -eo args 2>/dev/null | grep -F '$KEY' | grep -vF 'grep -F'"
: > "$TMP/go"; wait "$TP"; rc=$?
check "then exit 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "…with the rest on screen" grep -qF SECOND-PART "$TMP/so"

echo "=== 6. the stops: \$0 from the API, the budget, the network, the vault ==="
for m in low budget netdown locked; do
  reset; spent "$NOW" 5
  if [ "$m" = locked ]; then echo locked > "$TMP/vault-mode"; else echo "$m" > "$TMP/mode"; fi
  run "$TALK" "hello" > "$TMP/so" 2>&1; rc=$?
  check "[$m] exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
  check "[$m] at most one claude call (no retry)" [ "$(calls claude)" -le 1 ]
  check "[$m] one vault call" [ "$(calls npm)" -eq 1 ]
  case "$m" in
    low)     check "[low] the API's \$0 is the used-up line" grep -qxE "The free API credit is used up for this month; it resets on [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}\." "$TMP/so" ;;
    budget)  check "[budget] says the turn reached what was left" grep -qF "This turn reached the \$195.00 of free API credit left this month and was stopped" "$TMP/so"
             check "[budget] what it wrote first is kept on screen" grep -qF PARTIAL "$TMP/so" ;;
    netdown) check "[netdown] Claude's own reason, plainly" grep -qF "Claude on the free API credit did not answer: Claude on the key said: API Error: Connection error." "$TMP/so" ;;
    locked)  check "[locked] the vault is named" grep -qF "the Boss OS vault did not open" "$TMP/so"
             check "[locked] claude never ran" [ "$(calls claude)" -eq 0 ] ;;
  esac
  want='$5.00'; [ "$m" = budget ] && want='$5.50'   # the stopped turn's own $0.50 is counted
  check "[$m] a cost line follows ($want)" grep -qF "used this month $want of \$200.00" "$TMP/so"
done

echo "=== 7. the key is never shown or kept ==="
reset; spent "$NOW" 1; echo leak > "$TMP/mode"
run "$TALK" "print your key" > "$TMP/so" 2>&1; rc=$?
check "a reply that holds the key still answers (rc=$rc)" [ "$rc" -eq 0 ]
check "…with the value replaced on screen" grep -qF "my key is [key removed]" "$TMP/so"
leaks="$(grep -rlF "$KEY" "$TMP" 2>/dev/null | grep -vxF "$TMP/key")"
check "the key's value is in no file but the fake vault's (found: ${leaks:-none})" [ -z "$leaks" ]
left="$(find "$TMP/tmp" -mindepth 1 2>/dev/null | head -3)"
check "talk and ai-run leave no temp files (found: ${left:-none})" [ -z "$left" ]

echo "=== 8. a stop by her ends claude too ==="
reset; spent "$NOW" 1; echo hang > "$TMP/mode"
env PATH="$BIN:$PATH" HOME="$TMP/home" "$TALK" "hang" > "$TMP/so" 2>&1 &   # talk itself, so the TERM is hers
TP=$!
for _ in $(seq 1 50); do [ -e "$TMP/started" ] && break; sleep 0.2; done
T_KILL=$SECONDS; kill -TERM "$TP"; wait "$TP"; rc=$?; took=$((SECONDS - T_KILL))
sleep 1
check "talk ends within 10 s of her stop, not when claude would have finished (took ${took}s)" [ "$took" -le 10 ]
check "talk ends 130 (rc=$rc)" [ "$rc" -eq 130 ]
check "…and says so" grep -qF "stopped by you" "$TMP/so"
absent "no claude is left running" pgrep -f "$BIN/claude"

echo "=== 9. the words and the guard ==="
run "$TALK" --help > "$TMP/so" 2>&1; rc=$?
check "--help exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "--help says the stop at \$200" grep -qF 'at $200 (or under $1' "$TMP/so"
check "--help says the cost line" grep -qF 'this turn ~$X.XX · used this month $Y.YY of $200' "$TMP/so"
check "the README has talk's line" grep -qE '^\| `talk` ' "$ROOT/README.md"
reset
env PATH="$BIN:$PATH" AI_RUN_CREDIT_NOW=1 AI_RUN_CALLER=nightly-job "$ROOT/ai-run" --role brain -- "x" > "$TMP/so" 2>&1; rc=$?
check "AI_RUN_CREDIT_NOW for any other caller: exit 64 (rc=$rc)" [ "$rc" -eq 64 ]
check "…and nothing ran" [ "$(calls claude)$(calls npm)" = 00 ]
setters="$(cd "$ROOT" && git ls-files 2>/dev/null | grep -vxE 'ai-run|talk|tests/test-talk.sh|README.md|docs/.*' | while IFS= read -r f; do [ -f "$f" ] && grep -lE 'AI_RUN_CREDIT_NOW=' "$f"; done)"
check "no tracked job sets AI_RUN_CREDIT_NOW (found: ${setters:-none})" [ -z "$setters" ]

echo
[ "$asserts" -gt 0 ] || { echo "NAMED STOP [NO_ASSERTIONS] the talk test ran nothing."; exit 1; }
echo "$((asserts - failed))/$asserts passed"
[ "$failed" -eq 0 ]
