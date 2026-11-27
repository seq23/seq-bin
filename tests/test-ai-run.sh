#!/bin/bash
# ai-run, against stub `codex` and `claude` binaries on PATH.
#
# OWNER RULING (3 Nov 2026): Codex does the hands-on work, Claude is only the brains, and a Codex
# usage limit hands the run to Claude (her yes, 6 Nov 2026, replacing the 3 Nov "waits" rule). What is under test:
#   · --role worker runs `codex exec -s workspace-write` with stdin </dev/null and never claude;
#     network only with --network; --cwd and the repo's .git (writable) reach codex;
#   · a Codex usage-limit message is exit 75 and `NAMED STOP [CODEX_LIMIT] resets <time>`, with NO
#     claude call; a run that merely printed such a line and finished is not a limit;
#   · codex missing, logged out, or logged in with a (billing) API key is CODEX_UNAVAILABLE, no claude;
#   · --role brain runs `claude -p --model opus` and never codex;
#   · a Claude usage limit (any exit code) is exit 76 and `NAMED STOP [CLAUDE_LIMIT] resets <time>`,
#     never Codex or a free route; a long answer that merely discusses limits is not one;
#   · --out appends as it happens and survives a kill, which reaches the engine;
#   · every run appends one usage-log line; no tracked job sets AI_RUN_WORKER.
# RULE 0: zero assertions is a failure.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AI="$ROOT/ai-run"
[ -x "$AI" ] || { echo "NAMED STOP [MISSING] $AI is missing or not executable."; exit 3; }

TMP="$(mktemp -d)"; trap 'pkill -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
asserts=0; failed=0
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check()  { local w="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$w"; else bad "$w"; fi; }
absent() { local w="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$w"; else ok "$w"; fi; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/codex" <<'SH'
#!/bin/bash
if [ "$1 $2" = "login status" ]; then
  case "$(cat "$FAKE/codex-login" 2>/dev/null)" in
    out) echo "Not logged in"; exit 1 ;;
    apikey) echo "Logged in using an API key - sk-proj-***"; exit 0 ;;
    *) echo "Logged in using ChatGPT"; exit 0 ;;
  esac
fi
printf '%s\n' "$*" >> "$FAKE/codex-args.log"
stdin="$(cat)"; printf '%s' "$stdin" > "$FAKE/codex-stdin"
pwd > "$FAKE/codex-pwd"
case "$(cat "$FAKE/codex-mode" 2>/dev/null)" in
  limit)   echo "codex working"; echo "ERROR: You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro) or try again at Nov 7th, 2026 3:05 PM."; exit 1 ;;
  limit-in) echo "■ You've hit your usage limit. Try again in 2 days 3 hours."; exit 1 ;;
  printed) echo "cat fixture: ERROR: You've hit your usage limit. try again at 9 PM."; echo "done"; exit 0 ;;
  slow)    echo "first line"; sleep 60 & wait $!; echo "never" ;;
  fail)    echo "boom"; exit 3 ;;
  *)       echo "WORKER-DONE" ;;
esac
SH
cat > "$BIN/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/claude-args.log"
cat > "$FAKE/claude-stdin"; pwd > "$FAKE/claude-pwd"
case "$(cat "$FAKE/claude-mode" 2>/dev/null)" in
  weekly0) echo "You've hit your weekly limit · resets Oct 30 at 9am (America/New_York)"; exit 0 ;;
  weekly1) echo "You've hit your weekly limit · resets 9am (America/New_York)"; exit 1 ;;
  hour5)   echo "5-hour limit reached ∙ resets 3pm"; exit 1 ;;
  epoch)   echo "Claude AI usage limit reached|1764000000"; exit 1 ;;
  noreset) echo "You've hit your session limit"; exit 1 ;;
  essay)   for i in $(seq 1 30); do echo "Paragraph $i: we discussed how you've hit your weekly limit in planning and what resets 9am means for the schedule."; done; exit 0 ;;
  slow)    echo "STARTED"; sleep 30; echo "LATE-ANSWER" ;;
  *)       echo "BRAIN-DONE" ;;
esac
SH
chmod +x "$BIN"/*
export FAKE="$TMP" AI_RUN_LOG="$TMP/ai-run.log" AI_RUN_PAUSE_FILE="$TMP/no-pause-file"
reset() { rm -f "$TMP"/codex-* "$TMP"/claude-* "$TMP/out.log"; }
run() { env PATH="$BIN:$PATH" "$@"; }
codex_calls()  { grep -c . "$TMP/codex-args.log" 2>/dev/null || echo 0; }
claude_calls() { grep -c . "$TMP/claude-args.log" 2>/dev/null || echo 0; }
no_claude() { [ ! -s "$TMP/claude-args.log" ]; }

REPO="$TMP/github/alpha"; mkdir -p "$REPO"; git -C "$REPO" init -q

echo "=== 1. worker -> codex exec -s workspace-write, never claude ==="
reset
out="$(echo "STDIN-MUST-NOT-REACH-CODEX" | run "$AI" --role worker --cwd "$TMP/github" -- "fix the build"; echo "rc=$?")"
check "exit 0 (${out##*rc=})" grep -q 'rc=0$' <<<"$out"
check "codex was called exactly once" [ "$(codex_calls)" -eq 1 ]
check "…as exec -s workspace-write" grep -q '^exec -s workspace-write ' "$TMP/codex-args.log"
check "…with the prompt" grep -q 'fix the build$' "$TMP/codex-args.log"
check "…in --cwd (-C)" grep -q -- "-C $TMP/github" "$TMP/codex-args.log"
check "…with the repo's .git writable (workspace-write keeps .git read-only)" grep -q "writable_roots=\[.*$REPO/.git" "$TMP/codex-args.log"
absent "…and no network without --network" grep -q 'network_access' "$TMP/codex-args.log"
check "codex's stdin was /dev/null (the caller's stdin never reached it)" [ ! -s "$TMP/codex-stdin" ]
check "claude was never called" no_claude
check "without --out the output is on stdout" grep -q 'WORKER-DONE' <<<"$out"
check "a usage-log line: role, engine, caller, exit" grep -qE $'\trole=worker\tengine=codex\tcaller=[^\t]+\texit=0\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' "$AI_RUN_LOG"

echo "=== 2. --network and --out ==="
reset
echo "earlier line" > "$TMP/out.log"
run "$AI" --role worker --network --out "$TMP/out.log" -- "go"; rc=$?
check "exit 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "--network turns sandbox network on" grep -q 'sandbox_workspace_write.network_access=true' "$TMP/codex-args.log"
check "--out is appended to, not truncated" grep -q '^earlier line$' "$TMP/out.log"
check "…and holds the run's output" grep -q 'WORKER-DONE' "$TMP/out.log"
echo "prompt from stdin" | run "$AI" --role worker --out "$TMP/out.log" >/dev/null;
check "the prompt may come on stdin" grep -q 'prompt from stdin$' "$TMP/codex-args.log"

echo "=== 3. a Codex usage limit HANDS THE RUN TO CLAUDE (her yes, 6 Nov 2026); never waits ==="
reset; echo limit > "$TMP/codex-mode"
out="$(run "$AI" --role worker --out "$TMP/out.log" -- "fix it")"; rc=$?
absent "claude WAS called after the limit" no_claude
check "…with the same prompt" grep -q 'fix it' "$TMP/claude-stdin"
check "the run ends with claude's exit code, not 75 (rc=$rc)" [ "$rc" -eq 0 ]
absent "no CODEX_LIMIT wait stop" grep -q 'NAMED STOP \[CODEX_LIMIT\]' "$TMP/out.log"
check "the hand-off is written into --out with the reset time" grep -q 'handing this run to Claude' "$TMP/out.log"
check "codex ran once, not retried" [ "$(codex_calls)" -eq 1 ]
check "the usage log records the hand-off" grep -q 'stop=CODEX_LIMIT_TO_CLAUDE' "$AI_RUN_LOG"
reset; echo limit-in > "$TMP/codex-mode"
out="$(AI_RUN_NO_CLAUDE_FALLBACK=1 run "$AI" --role worker -- "x")"; rc=$?
check "with the fallback switched off, a limit is still exit 75 with its reset (rc=$rc)" grep -q 'CODEX_LIMIT\] resets in 2 days 3 hours' <<<"$out"
check "…and no claude" no_claude
reset; echo printed > "$TMP/codex-mode"
out="$(run "$AI" --role worker -- "x")"; rc=$?
check "a run that only PRINTED a limit line and finished is exit 0, not a limit (rc=$rc)" [ "$rc" -eq 0 ]
absent "…and no CODEX_LIMIT stop" grep -q CODEX_LIMIT <<<"$out"
reset; echo fail > "$TMP/codex-mode"
run "$AI" --role worker -- "x" >/dev/null; rc=$?
check "any other codex failure passes its own exit code through (rc=$rc)" [ "$rc" -eq 3 ]
check "…no claude" no_claude

echo "=== 4. Codex unavailable: CODEX_UNAVAILABLE, no claude ==="
reset
out="$(run env AI_RUN_CODEX_BIN="$TMP/nope/codex" "$AI" --role worker -- "x")"; rc=$?
check "codex missing -> exit 69 CODEX_UNAVAILABLE (rc=$rc)" [ "$rc" -eq 69 ]
check "…named" grep -q 'NAMED STOP \[CODEX_UNAVAILABLE\]' <<<"$out"
check "…no claude" no_claude
echo out > "$TMP/codex-login"
out="$(run "$AI" --role worker -- "x")"; rc=$?
check "codex logged out -> 69 CODEX_UNAVAILABLE (rc=$rc)" grep -q 'CODEX_UNAVAILABLE' <<<"$out"
check "…and codex exec never ran" [ "$(codex_calls)" -eq 0 ]
echo apikey > "$TMP/codex-login"
out="$(run "$AI" --role worker -- "x")"; rc=$?
check "codex on an API key (paid) -> 69 CODEX_UNAVAILABLE (rc=$rc)" [ "$rc" -eq 69 ]
check "…no claude, no exec" [ "$(claude_calls)$(codex_calls)" = "00" ]
rm -f "$TMP/codex-login"

echo "=== 5. brain -> claude -p --model opus, never codex ==="
reset
out="$(run "$AI" --role brain --cwd "$REPO" -- "summarise the week")"; rc=$?
check "exit 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "claude was called once" [ "$(claude_calls)" -eq 1 ]
check "…as -p --model opus --dangerously-skip-permissions" grep -qx -- '-p --model opus --dangerously-skip-permissions' "$TMP/claude-args.log"
check "…with the prompt on its stdin" grep -qx 'summarise the week' "$TMP/claude-stdin"
check "…in --cwd" grep -qx "$(cd "$REPO" && pwd)" "$TMP/claude-pwd"
check "codex was never called" [ "$(codex_calls)" -eq 0 ]
check "the output came back" grep -q BRAIN-DONE <<<"$out"
reset
run env AI_RUN_CLAUDE_ARGS='--chrome --allowedTools=mcp__claude-in-chrome__*' "$AI" --role brain -- "list" >/dev/null
check "AI_RUN_CLAUDE_ARGS replaces the permission flag, unglobbed" grep -qx -- '-p --model opus --chrome --allowedTools=mcp__claude-in-chrome__\*' "$TMP/claude-args.log"

echo "=== 6. a kill reaches the engine; --out keeps what it printed ==="
reset; echo slow > "$TMP/codex-mode"
env PATH="$BIN:$PATH" "$AI" --role worker --out "$TMP/out.log" -- "long" & AIPID=$!
for _ in $(seq 1 50); do grep -q 'first line' "$TMP/out.log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$AIPID"; wait "$AIPID"; rc=$?
sleep 0.3
check "ai-run ends when killed (rc=$rc)" [ "$rc" -ne 0 ]
check "the line printed before the kill is in --out" grep -q 'first line' "$TMP/out.log"
absent "the codex child did not survive the kill" pgrep -f "$BIN/codex exec"

echo "=== 7. AI_RUN_WORKER=claude is her override; only the partner tail and the ci-sweep Codex-out hand-off set it (her yes 6 Nov 2026) ==="
reset
run env AI_RUN_WORKER=claude "$AI" --role worker -- "by hand" >/dev/null
check "the override runs the worker on claude" [ "$(claude_calls)" -eq 1 ]
check "…logged as engine=claude-override" grep -q $'engine=claude-override' "$AI_RUN_LOG"
setters="$(cd "$ROOT" && git ls-files 2>/dev/null | grep -vxE 'ai-run|tests/test-ai-run.sh|README.md|docs/.*|scooter-watch-run-fix.sh|ci-sweep.sh' | while IFS= read -r f; do [ -f "$f" ] && grep -lE 'AI_RUN_WORKER=' "$f"; done)"
if [ -n "$(cd "$ROOT" && git ls-files 2>/dev/null | head -1)" ]; then
  check "no tracked job sets AI_RUN_WORKER (found: ${setters:-none})" [ -z "$setters" ]
else
  bad "could not list tracked files to look for AI_RUN_WORKER setters"
fi

# 9 Nov 2026: a reused PID (alive, not our child) made the wait loop spin at 100% CPU for 50 minutes.
reset; sleep 60 & FOREIGN=$!
( sleep 1; true ) & SUB=$!; wait "$SUB"
START=$(date +%s)
env PATH="$BIN:$PATH" AI_RUN_TEST_FOREIGN_PID="$FOREIGN" timeout 15 "$AI" --role worker --out "$TMP/out.log" -- "quick" >/dev/null 2>&1; rc=$?
check "a reused, foreign PID ends the wait instead of spinning (rc $rc)" test "$rc" -ne 124
check "a reused, foreign PID ends the wait within 10 s" test $(( $(date +%s) - START )) -lt 10
kill "$FOREIGN" 2>/dev/null
# 21 Nov 2026: a 100 KB prompt (a review with a PR's changed lines) must start the engine in seconds;
# the old whitespace check was quadratic in bash 3.2 and spun past the 20-minute seat cap.
reset; BIG="$(head -c 100000 /dev/zero | tr '\0' 'a' | fold -w 80)"
START=$(date +%s)
env PATH="$BIN:$PATH" timeout 30 /bin/bash "$AI" --role worker --out "$TMP/out.log" -- "$BIG" >/dev/null 2>&1; rc=$?
check "a 100 KB prompt reaches the engine (rc $rc)" test "$rc" -eq 0
check "a 100 KB prompt starts within 10 s" test $(( $(date +%s) - START )) -lt 10
reset; out="$(env PATH="$BIN:$PATH" /bin/bash "$AI" --role worker -- "$(printf '  \n\t ')"; echo "rc=$?")"
check "a blank prompt is still a NAMED STOP [NO_PROMPT] (rc 64)" grep -q 'rc=64$' <<<"$out"
echo "=== 8. a Claude usage limit is exit 76 NAMED STOP [CLAUDE_LIMIT] resets <time>; never Codex or a free route (23 Nov 2026) ==="
reset; echo weekly0 > "$TMP/claude-mode"
out="$(run "$AI" --role brain --out "$TMP/out.log" -- "plan the week")"; rc=$?
check "a limit notice with exit 0 is still exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
check "…named, with Claude's own reset time" grep -q 'NAMED STOP \[CLAUDE_LIMIT\] resets Oct 30 at 9am (America/New_York)' <<<"$out"
check "…and the stop line is in --out too" grep -q 'NAMED STOP \[CLAUDE_LIMIT\]' "$TMP/out.log"
check "…codex was never called" [ "$(codex_calls)" -eq 0 ]
check "…claude ran once, not retried" [ "$(claude_calls)" -eq 1 ]
check "…the usage log records stop=CLAUDE_LIMIT exit 76" grep -qE $'exit=76\tstop=CLAUDE_LIMIT\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' "$AI_RUN_LOG"
reset; echo weekly1 > "$TMP/claude-mode"
out="$(run "$AI" --role brain -- "x")"; rc=$?
check "a limit notice with exit 1 is exit 76 (rc=$rc)" grep -q 'CLAUDE_LIMIT\] resets 9am (America/New_York)' <<<"$out"
reset; echo hour5 > "$TMP/claude-mode"
out="$(run "$AI" --role brain -- "x")"; rc=$?
check "the 5-hour wording is a CLAUDE_LIMIT (rc=$rc)" [ "$rc" -eq 76 ]
check "…resets 3pm" grep -q 'CLAUDE_LIMIT\] resets 3pm' <<<"$out"
reset; echo epoch > "$TMP/claude-mode"
out="$(run "$AI" --role brain -- "x")"; rc=$?
check "the epoch wording is a CLAUDE_LIMIT with a readable time (rc=$rc)" grep -qE 'CLAUDE_LIMIT\] resets [A-Z][a-z]{2} [0-9]+ at ' <<<"$out"
reset; echo noreset > "$TMP/claude-mode"
out="$(run "$AI" --role brain -- "x")"; rc=$?
check "no reset time is still a CLAUDE_LIMIT saying so (rc=$rc)" grep -q 'CLAUDE_LIMIT\] resets unknown (Claude gave no reset time' <<<"$out"
reset; echo essay > "$TMP/claude-mode"
out="$(run "$AI" --role brain -- "x")"; rc=$?
check "a long answer that only DISCUSSES limits is exit 0, not a stop (rc=$rc)" [ "$rc" -eq 0 ]
absent "…no CLAUDE_LIMIT" grep -q CLAUDE_LIMIT <<<"$out"
reset; echo limit > "$TMP/codex-mode"; echo weekly1 > "$TMP/claude-mode"
out="$(run "$AI" --role worker -- "fix")"; rc=$?
check "a Codex limit handed to a Claude that is also out ends at 76 CLAUDE_LIMIT (rc=$rc)" [ "$rc" -eq 76 ]
check "…codex ran once, claude once, nothing else" [ "$(codex_calls)$(claude_calls)" = "11" ]

echo "=== her pause: one date file stops every ai-run call, Codex and Claude, and nothing is lost ==="
tomorrow="$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d tomorrow +%Y-%m-%d)"; yesterday="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)"
reset; echo "$tomorrow" > "$TMP/pause"
out="$(AI_RUN_PAUSE_FILE="$TMP/pause" run "$AI" --role brain -- "summarise the week")"; rc=$?
check "paused brain: exit 75 (rc=$rc), the same 'work waits' code as a limit" [ "$rc" -eq 75 ]
check "…NAMED STOP [PAUSED] naming the date" grep -q "NAMED STOP \[PAUSED\] by the owner until $tomorrow" <<<"$out"
check "…and claude never ran" no_claude
out="$(AI_RUN_PAUSE_FILE="$TMP/pause" run "$AI" --role worker -- "fix it")"; rc=$?
check "paused worker: exit 75 and codex never ran (rc=$rc)" eval '[ "$rc" -eq 75 ] && [ ! -s "$TMP/codex-args.log" ]'
check "…the usage log records stop=PAUSED" grep -q 'stop=PAUSED' "$AI_RUN_LOG"
out="$(AI_RUN_IGNORE_PAUSE=1 AI_RUN_PAUSE_FILE="$TMP/pause" run "$AI" --role brain -- "her own run")"; rc=$?
check "a run she starts by hand (AI_RUN_IGNORE_PAUSE=1) still runs (rc=$rc)" eval '[ "$rc" -eq 0 ] && [ "$(claude_calls)" -eq 1 ]'
reset; echo "$yesterday" > "$TMP/pause"
out="$(AI_RUN_PAUSE_FILE="$TMP/pause" run "$AI" --role brain -- "summarise the week")"; rc=$?
check "an expired pause date runs as usual (rc=$rc)" eval '[ "$rc" -eq 0 ] && [ "$(claude_calls)" -eq 1 ]'
reset; echo "sometime soon" > "$TMP/pause"
out="$(AI_RUN_PAUSE_FILE="$TMP/pause" run "$AI" --role brain -- "summarise the week")"; rc=$?
check "a pause file with no readable date is still a pause, never 'no pause' (rc=$rc)" eval '[ "$rc" -eq 75 ] && no_claude && grep -q "does not hold a date" <<<"$out"'

echo "=== ai-pause: the one command that sets, shows and ends the pause ==="
PAUSE="$ROOT/ai-pause"; PF="$TMP/pause2"
out="$(AI_RUN_PAUSE_FILE="$PF" "$PAUSE" 1)"; check "ai-pause 1 writes tomorrow's date and says PAUSED until it" eval '[ "$(cat "$PF")" = "$tomorrow" ] && grep -q "PAUSED until $tomorrow" <<<"$out"'
reset; out="$(AI_RUN_PAUSE_FILE="$PF" run "$AI" --role brain -- "x")"; rc=$?
check "…and ai-run then stops on that file (rc=$rc)" eval '[ "$rc" -eq 75 ] && no_claude'
out="$(AI_RUN_PAUSE_FILE="$PF" "$PAUSE" "$yesterday")"; rc=$?
check "a date that is not ahead is refused and the pause is left as it was (rc=$rc)" eval '[ "$rc" -eq 64 ] && [ "$(cat "$PF")" = "$tomorrow" ]'
out="$(AI_RUN_PAUSE_FILE="$PF" "$PAUSE" banana)"; rc=$?
check "a word that is not a date is refused, nothing changed (rc=$rc)" eval '[ "$rc" -eq 64 ] && [ "$(cat "$PF")" = "$tomorrow" ]'
out="$(AI_RUN_PAUSE_FILE="$PF" "$PAUSE" off)"; check "ai-pause off removes the file and says no pause" eval '[ ! -e "$PF" ] && grep -q "no pause" <<<"$out"'
reset; out="$(AI_RUN_PAUSE_FILE="$PF" run "$AI" --role brain -- "x")"; rc=$?
check "…and ai-run runs again (rc=$rc)" eval '[ "$rc" -eq 0 ] && [ "$(claude_calls)" -eq 1 ]'

echo "=== the usage caps: runs a day per caller, and seconds per run (Claude only) ==="
reset; : > "$AI_RUN_LOG"
for i in 1 2 3; do AI_RUN_CALLER=loopy AI_RUN_MAX_RUNS=3 run "$AI" --role brain -- "round $i" >/dev/null; done
out="$(AI_RUN_CALLER=loopy AI_RUN_MAX_RUNS=3 run "$AI" --role brain -- "round 4")"; rc=$?
check "the 4th Claude run of a caller capped at 3 a day: exit 75, NAMED STOP [RUN_CAP] (rc=$rc)" eval '[ "$rc" -eq 75 ] && grep -q "NAMED STOP \[RUN_CAP\] loopy has already made 3 Claude runs today" <<<"$out"'
check "…and claude ran exactly 3 times" [ "$(claude_calls)" -eq 3 ]
out="$(AI_RUN_CALLER=other AI_RUN_MAX_RUNS=3 run "$AI" --role brain -- "someone else")"; rc=$?
check "another caller is not held by loopy's count (rc=$rc)" [ "$rc" -eq 0 ]
out="$(AI_RUN_CALLER=loopy AI_RUN_MAX_RUNS=3 run "$AI" --role worker -- "codex work")"; rc=$?
check "the run cap counts Claude runs only: the same caller's Codex run still runs (rc=$rc)" [ "$rc" -eq 0 ]
reset; echo slow > "$TMP/claude-mode"; t0=$SECONDS
out="$(AI_RUN_MAX_SECS=2 run "$AI" --role brain -- "think for a long time")"; rc=$?
check "a Claude run past its 2-second cap is stopped: exit 124 in well under the engine's 30 s (rc=$rc, $((SECONDS-t0)) s)" eval '[ "$rc" -eq 124 ] && [ $((SECONDS-t0)) -lt 15 ]'
check "…NAMED STOP [TIME_CAP], with what it printed before the cap kept and the late answer absent" eval 'grep -q "NAMED STOP \[TIME_CAP\]" <<<"$out" && grep -q STARTED <<<"$out" && ! grep -q LATE-ANSWER <<<"$out"'
reset
out="$(AI_RUN_MAX_SECS=2 run "$AI" --role brain -- "quick")"; rc=$?
check "a run that finishes inside its cap is untouched (rc=$rc)" eval '[ "$rc" -eq 0 ] && grep -q BRAIN-DONE <<<"$out" && ! grep -q TIME_CAP <<<"$out"'

echo "=== AI_RUN_MCP=none: Claude starts with no connectors ==="
reset
AI_RUN_MCP=none run "$AI" --role brain -- "judge this diff" >/dev/null
check "claude is started with --strict-mcp-config and an empty server list" grep -qF -- '--strict-mcp-config --mcp-config {"mcpServers":{}}' "$TMP/claude-args.log"
reset
run "$AI" --role brain -- "needs her connectors" >/dev/null
absent "without it the connectors are left as they are" grep -q -- '--strict-mcp-config' "$TMP/claude-args.log"
reset
out="$(AI_RUN_MCP=some run "$AI" --role brain -- "x" 2>&1)"; rc=$?
check "an unknown AI_RUN_MCP value is refused, never guessed (rc=$rc)" eval '[ "$rc" -eq 64 ] && no_claude'

echo
[ "$asserts" -gt 0 ] || { echo "NAMED STOP [ZERO_ASSERTIONS] nothing was checked."; exit 3; }
echo "$((asserts - failed))/$asserts passed"
[ "$failed" -eq 0 ] || exit 1
echo "ai-run routes hands-on work to Codex, brains to Claude, and a Codex limit hands the run to Claude (6 Nov 2026)."
