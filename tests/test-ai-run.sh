#!/bin/bash
# ai-run, against stub `codex` and `claude` binaries on PATH.
#
# OWNER RULING (3 Nov 2026): Codex does the hands-on work, Claude is only the brains, and a Codex
# usage limit means the work WAITS — it is never handed to Claude. What is under test:
#   · --role worker runs `codex exec -s workspace-write` with stdin </dev/null and never claude;
#     network only with --network; --cwd and the repo's .git (writable) reach codex;
#   · a Codex usage-limit message is exit 75 and `NAMED STOP [CODEX_LIMIT] resets <time>`, with NO
#     claude call; a run that merely printed such a line and finished is not a limit;
#   · codex missing, logged out, or logged in with a (billing) API key is CODEX_UNAVAILABLE, no claude;
#   · --role brain runs `claude -p --model opus` and never codex;
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
echo "BRAIN-DONE"
SH
chmod +x "$BIN"/*
export FAKE="$TMP" AI_RUN_LOG="$TMP/ai-run.log"
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
check "a usage-log line: role, engine, caller, exit" grep -qE $'\trole=worker\tengine=codex\tcaller=[^\t]+\texit=0$' "$AI_RUN_LOG"

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

echo "=== 3. a Codex usage limit: exit 75, CODEX_LIMIT with its reset time, no claude ==="
reset; echo limit > "$TMP/codex-mode"
out="$(run "$AI" --role worker --out "$TMP/out.log" -- "fix it")"; rc=$?
check "exit 75 (rc=$rc)" [ "$rc" -eq 75 ]
check "NAMED STOP [CODEX_LIMIT] resets <the time in the message>: $out" grep -q 'NAMED STOP \[CODEX_LIMIT\] resets Nov 7th, 2026 3:05 PM' <<<"$out"
check "…also written into --out" grep -q 'NAMED STOP \[CODEX_LIMIT\]' "$TMP/out.log"
check "claude was NOT called (the work waits; it is never handed to Claude)" no_claude
check "codex ran once, not retried" [ "$(codex_calls)" -eq 1 ]
check "the usage log records exit 75 and the stop" grep -qE $'exit=75\tstop=CODEX_LIMIT$' "$AI_RUN_LOG"
reset; echo limit-in > "$TMP/codex-mode"
out="$(run "$AI" --role worker -- "x")"; rc=$?
check "a 'try again in …' limit is 75 with the duration (rc=$rc)" grep -q 'CODEX_LIMIT\] resets in 2 days 3 hours' <<<"$out"
check "…no claude" no_claude
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

echo "=== 7. AI_RUN_WORKER=claude is HER manual override, and no job sets it ==="
reset
run env AI_RUN_WORKER=claude "$AI" --role worker -- "by hand" >/dev/null
check "the override runs the worker on claude" [ "$(claude_calls)" -eq 1 ]
check "…logged as engine=claude-override" grep -q $'engine=claude-override' "$AI_RUN_LOG"
setters="$(cd "$ROOT" && git ls-files 2>/dev/null | grep -vxE 'ai-run|tests/test-ai-run.sh|README.md|docs/.*' | while IFS= read -r f; do [ -f "$f" ] && grep -lE 'AI_RUN_WORKER=' "$f"; done)"
if [ -n "$(cd "$ROOT" && git ls-files 2>/dev/null | head -1)" ]; then
  check "no tracked job sets AI_RUN_WORKER (found: ${setters:-none})" [ -z "$setters" ]
else
  bad "could not list tracked files to look for AI_RUN_WORKER setters"
fi

echo
[ "$asserts" -gt 0 ] || { echo "NAMED STOP [ZERO_ASSERTIONS] nothing was checked."; exit 3; }
echo "$((asserts - failed))/$asserts passed"
[ "$failed" -eq 0 ] || exit 1
echo "ai-run routes hands-on work to Codex, brains to Claude, and a Codex limit waits — never Claude."
