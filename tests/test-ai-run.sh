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
#   · a Claude usage limit (any exit code) runs the same prompt ONCE more on the free API credit (her
#     words 27 Nov 2026: "only after plan runs out"), through a stub `npm run -s vault:run`; a long
#     answer that merely discusses limits is not a limit;
#   · the plan is always asked first: no limit, no vault call, and a key in the caller's environment
#     never reaches claude; the credit run's answer is the job's output and its cost is in the usage log;
#   · a credit that cannot run (vault locked or missing, no key, credit used up, key or org refused,
#     network down, a limit of its own, an empty or unreadable answer) is exit 76 and
#     `NAMED STOP [CLAUDE_LIMIT] resets <time>` with one line saying why; never a second try, never Codex;
#   · AI_RUN_NO_CREDIT=1 is the old named stop, byte for byte; the test-only switch is refused for a
#     caller whose name does not start with test-;
#   · the key's value is in no file, stream or argument the run leaves, even when claude prints it;
#   · --out appends as it happens and survives a kill, which reaches the engine;
#   · every run appends one usage-log line; no tracked job sets AI_RUN_WORKER.
# The stubs never touch the network or the real vault (AI_RUN_VAULT_REPO points at a fake checkout).
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
cat "$FAKE/claude-stdin" >> "$FAKE/claude-stdins.log"; echo >> "$FAKE/claude-stdins.log"
# What this call could see: a checksum of the key (never its value), and whether the vault's other
# secret, npm's own variables and npm's PATH came through.
key=unset; [ -n "${ANTHROPIC_API_KEY:-}" ] && key="$(printf '%s' "$ANTHROPIC_API_KEY" | cksum | tr ' ' '-')"
path=own; [ "${PATH#/fake/node_modules/.bin:}" = "$PATH" ] || path=npm
env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | grep -vxE '_|SHLVL|PWD|OLDPWD' | sort -u | tr '\n' ' ' >> "$FAKE/claude-names.log"; echo >> "$FAKE/claude-names.log"
printf 'key=%s other=%s npm=%s path=%s\n' "$key" "${FAKE_OTHER_SECRET:+set}" "${npm_lifecycle_event:+set}" "$path" >> "$FAKE/claude-env.log"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then   # a run on a key: Claude's event stream, as --output-format stream-json prints it
  res() { # res <is_error> <result> <cost> [api_error_status]
    printf '{"type":"system","subtype":"init","apiKeySource":"ANTHROPIC_API_KEY","model":"m"}\n'
    printf '{"type":"result","subtype":"success","is_error":%s,"result":"%s","total_cost_usd":%s,"api_error_status":%s}\n' "$1" "$2" "$3" "${4:-null}"
  }
  case "$(cat "$FAKE/credit-mode" 2>/dev/null)" in
    low)     echo "a warning on stderr" >&2; res true "Credit balance is too low" 0 400; exit 1 ;;
    invalid) res true "Invalid API key · Fix external API key" 0 401; exit 1 ;;
    refused) res true "This organization has been disabled." 0 403; exit 1 ;;
    netdown) res true "API Error: Connection error." 0; exit 1 ;;
    limit)   res false "You've hit your weekly limit · resets 9am" 0; exit 0 ;;
    empty)   res false "" 0.01; exit 0 ;;
    garbage) echo "Segmentation fault"; exit 139 ;;
    silent)  exit 0 ;;
    okbutrc) res false "CREDIT-DONE" 0.002; exit 3 ;;
    leak)    echo "debug: the key is $ANTHROPIC_API_KEY" >&2; res false "CREDIT-DONE and my key is $ANTHROPIC_API_KEY" 0.0041; exit 0 ;;
    errleak) echo "auth failed for $ANTHROPIC_API_KEY" >&2; res true "rejected key $ANTHROPIC_API_KEY" 0 401; exit 1 ;;
    crashleak) echo "fatal: bad key $ANTHROPIC_API_KEY" >&2; exit 2 ;;
    foreign) echo "FOREIGN LINE" >> "$FAKE/out.log"; res false "CREDIT-DONE" 0.0032; exit 0 ;;
    slow)    echo started > "$FAKE/credit-started"; sleep 60 & wait $!; echo "never" ;;
    *)       res false "CREDIT-DONE line one\\nline two" 0.0032; exit 0 ;;
  esac
fi
case "$(cat "$FAKE/claude-mode" 2>/dev/null)" in
  weekly0) echo "You've hit your weekly limit · resets Oct 30 at 9am (America/New_York)"; exit 0 ;;
  weekly1) echo "You've hit your weekly limit · resets 9am (America/New_York)"; exit 1 ;;
  hour5)   echo "5-hour limit reached ∙ resets 3pm"; exit 1 ;;
  epoch)   echo "Claude AI usage limit reached|1764000000"; exit 1 ;;
  noreset) echo "You've hit your session limit"; exit 1 ;;
  partial) echo "Step 1 of 3 is done."; echo "You've hit your weekly limit · resets 9am (America/New_York)"; exit 1 ;;
  essay)   for i in $(seq 1 30); do echo "Paragraph $i: we discussed how you've hit your weekly limit in planning and what resets 9am means for the schedule."; done; exit 0 ;;
  slow)    echo "STARTED"; sleep 30; echo "LATE-ANSWER" ;;
  *)       echo "BRAIN-DONE" ;;
esac
SH
# The Boss OS vault, faked: `npm run -s vault:run -- <command…>` in the fake checkout. Like the real one
# it puts EVERY secret it holds into the command's environment, and npm's own variables and PATH with them.
# No vault-mode file means a locked vault, so a test that did not open it can never be handed a key.
cat > "$BIN/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/npm-args.log"; pwd >> "$FAKE/npm-pwd.log"
[ "$1 $2 $3 $4" = "run -s vault:run --" ] || { echo "fake npm: unexpected: $*" >&2; exit 2; }
shift 4
export npm_lifecycle_event=vault:run PATH="/fake/node_modules/.bin:$PATH"
# The real npm exports NODE and INIT_CWD, and a vault may hold ANY name, the ones ai-run's own code uses
# included (27 Nov 2026: npm's NODE, dropped with the rest, took the credit child's own $NODE with it and
# the first real run was thrown away). None of them may break the run or reach claude.
export NODE=/fake/node INIT_CWD=/fake S=x KEEP=x DIR=/fake PATH0=x RAW_ANSWER=x READER=x CPID=x v=x
case "$(cat "$FAKE/vault-mode" 2>/dev/null)" in
  open)  ANTHROPIC_API_KEY="$(cat "$FAKE/vault/key")" FAKE_OTHER_SECRET="$(cat "$FAKE/vault/other")"; export ANTHROPIC_API_KEY FAKE_OTHER_SECRET
         "$@"; exit $? ;;   # a child, never exec: like the real npm and vault, a kill of this process is NOT passed on
  nokey) FAKE_OTHER_SECRET="$(cat "$FAKE/vault/other")"; export FAKE_OTHER_SECRET; "$@"; exit $? ;;
  *)     echo "VAULT GATE: No vault master key in Keychain. Run \`vault:init\` first." >&2; exit 1 ;;
esac
SH
chmod +x "$BIN"/*
export FAKE="$TMP" AI_RUN_LOG="$TMP/ai-run.log" AI_RUN_PAUSE_FILE="$TMP/no-pause-file" AI_RUN_VAULT_REPO="$TMP/boss-os"
mkdir -p "$TMP/boss-os" "$TMP/vault" "$TMP/tmp" "$TMP/home"
export TMPDIR="$TMP/tmp"   # ai-run's own temp files land inside what the key search reads
KEY="sk-ant-api03-FAKE-test-only-9f3c1e"; printf '%s' "$KEY" > "$TMP/vault/key"
OTHER="other-vault-secret-7b2d"; printf '%s' "$OTHER" > "$TMP/vault/other"
KEYSUM="$(printf '%s' "$KEY" | cksum | tr ' ' '-')"
reset() { rm -f "$TMP"/codex-* "$TMP"/claude-* "$TMP"/npm-* "$TMP/out.log" "$TMP/vault-mode" "$TMP/credit-mode" "$TMP/credit-started" "$TMP/so" "$TMP/se"; }
run() { env PATH="$BIN:$PATH" "$@"; }
npm_calls() { calls npm; }
no_vault() { [ ! -s "$TMP/npm-args.log" ]; }
env_of() { sed -n "${1}p" "$TMP/claude-env.log" 2>/dev/null; }   # what claude call N could see
names_of() { sed -n "${1}p" "$TMP/claude-names.log" 2>/dev/null | tr ' ' '\n' | grep .; }   # the environment NAMES claude call N had
last_log() { tail -n "${1:-1}" "$AI_RUN_LOG" | head -1; }
STOP_WEEKLY0="NAMED STOP [CLAUDE_LIMIT] resets Oct 30 at 9am (America/New_York) — the work waits for the reset; no Codex or free fallback."
NOTICE_WEEKLY0="You've hit your weekly limit · resets Oct 30 at 9am (America/New_York)"
calls() { local n; n="$(grep -c . "$TMP/$1-args.log" 2>/dev/null)"; echo "${n:-0}"; }   # one number, also for a missing or empty log
codex_calls()  { calls codex; }
claude_calls() { calls claude; }
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
echo "=== 8. a Claude usage limit, with the free credit unusable (vault locked), is exit 76 NAMED STOP [CLAUDE_LIMIT] resets <time>; never Codex or a free model ==="
reset; echo weekly0 > "$TMP/claude-mode"
out="$(run "$AI" --role brain --out "$TMP/out.log" -- "plan the week")"; rc=$?
check "a limit notice with exit 0 is still exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
check "…named, with Claude's own reset time" grep -q 'NAMED STOP \[CLAUDE_LIMIT\] resets Oct 30 at 9am (America/New_York)' <<<"$out"
check "…and the stop line is in --out too" grep -q 'NAMED STOP \[CLAUDE_LIMIT\]' "$TMP/out.log"
check "…codex was never called" [ "$(codex_calls)" -eq 0 ]
check "…claude ran once, not retried (the vault was locked, so no run on the key)" [ "$(claude_calls)" -eq 1 ]
check "…the vault was asked exactly once" [ "$(npm_calls)" -eq 1 ]
check "…the usage log's last line is exit 76 stop=CLAUDE_LIMIT with why the credit did not run" \
  grep -qE $'\tengine=claude-credit\tcaller=[^\t]+\texit=76\tstop=CLAUDE_LIMIT\tcredit=VAULT_UNREADABLE\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"
check "…after the plan's own line, stop=CLAUDE_LIMIT_TO_CREDIT" grep -qE $'\tengine=claude\tcaller=[^\t]+\texit=0\tstop=CLAUDE_LIMIT_TO_CREDIT\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log 2)"
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

# From here on the day's run cap is off (it is proven above, and with the credit below): these sections make
# more Claude runs under one caller name than a real job may in a day.
export AI_RUN_MAX_RUNS=0
echo "=== 9. the plan is asked first, always: no limit, no vault, and a caller's key never reaches claude ==="
reset; echo open > "$TMP/vault-mode"
out="$(run env ANTHROPIC_API_KEY="caller-carried-key" "$AI" --role brain -- "summarise")"; rc=$?
check "a plan that answers is exit 0 with its answer (rc=$rc)" [ "$rc $out" = "0 BRAIN-DONE" ]
check "…the vault was never asked for the key" no_vault
check "…claude ran once" [ "$(claude_calls)" -eq 1 ]
check "…and saw NO key, though the caller's environment carried one ($(env_of 1))" [ "$(env_of 1)" = "key=unset other= npm= path=own" ]
check "…the usage log has one plain line for it" grep -qE $'\tengine=claude\tcaller=[^\t]+\texit=0\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"
reset; echo open > "$TMP/vault-mode"; echo essay > "$TMP/claude-mode"
run "$AI" --role brain -- "x" > /dev/null; rc=$?
check "a long answer that discusses limits never opens the vault (rc=$rc)" no_vault

echo "=== 10. the plan is out: exactly ONE run on the free API credit, and its answer is the job's output ==="
reset; echo open > "$TMP/vault-mode"; echo weekly0 > "$TMP/claude-mode"
run env HOME="$TMP/home" "$AI" --role brain --cwd "$REPO" -- "plan the week" > "$TMP/so" 2> "$TMP/se"; rc=$?
check "exit 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "stdout is exactly the credit run's answer: no limit notice, no stop, nothing added" [ "$(cat "$TMP/so")" = "$(printf 'CREDIT-DONE line one\nline two')" ]
check "…and nothing on stderr" [ ! -s "$TMP/se" ]
check "claude ran exactly twice: the plan, then once on the key" [ "$(claude_calls)" -eq 2 ]
check "…the vault was opened exactly once" [ "$(npm_calls)" -eq 1 ]
check "…from the vault's checkout, as npm run -s vault:run" [ "$(cat "$TMP/npm-pwd.log")" = "$TMP/boss-os" ]
check "the plan run saw no key ($(env_of 1))" [ "$(env_of 1)" = "key=unset other= npm= path=own" ]
check "the credit run saw the vault's key and NOTHING else the vault or npm added ($(env_of 2))" [ "$(env_of 2)" = "key=$KEYSUM other= npm= path=own" ]
check "the credit run's environment is the plan run's, name for name, plus the one key" \
  [ "$(names_of 2 | grep -vx ANTHROPIC_API_KEY)|$(names_of 2 | grep -cx ANTHROPIC_API_KEY)|$(names_of 1 | grep -c .)" = "$(names_of 1)|1|$(names_of 2 | grep -vcx ANTHROPIC_API_KEY)" ]
check "…and that comparison saw real environments (PATH and HOME are in both)" [ "$(names_of 1 | grep -cxE 'PATH|HOME')$(names_of 2 | grep -cxE 'PATH|HOME')" = "22" ]
check "both runs got the same prompt on stdin (the prompt starts again)" [ "$(grep -c '^plan the week$' "$TMP/claude-stdins.log")" -eq 2 ]
check "the credit run is the plan's command plus the event stream that carries the cost" \
  [ "$(sed -n 2p "$TMP/claude-args.log")" = "$(sed -n 1p "$TMP/claude-args.log") --output-format stream-json --verbose" ]
check "…and ran in --cwd, not in the vault's checkout" grep -qx "$(cd "$REPO" && pwd)" "$TMP/claude-pwd"
check "the usage log: the plan's line says it moved to the credit" grep -qE $'\trole=brain\tengine=claude\tcaller=[^\t]+\texit=0\tstop=CLAUDE_LIMIT_TO_CREDIT\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log 2)"
check "…and the credit run's line has the date, caller, reported cost, key source and that the prompt restarted" \
  grep -qE $'^20[0-9-]+T[0-9:+-]+\trole=brain\tengine=claude-credit\tcaller=[^\t]+\texit=0\tcost_usd=0\\.003200\tkey_source=ANTHROPIC_API_KEY\tprompt=restarted\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"
check "the private directory of the run is gone" [ -z "$(ls "$TMP/tmp")" ]
check "nothing was written under HOME (no profile, no settings, no shell file)" [ -z "$(find "$TMP/home" -mindepth 1)" ]
reset; echo open > "$TMP/vault-mode"; echo weekly0 > "$TMP/claude-mode"
echo "earlier line" > "$TMP/out.log"
echo "prompt from stdin" | run "$AI" --role brain --out "$TMP/out.log" > "$TMP/so" 2>&1; rc=$?
check "--out and the prompt on stdin: exit 0 (rc=$rc), nothing on stdout" [ "$rc|$(cat "$TMP/so")" = "0|" ]
check "…--out is what was there before plus the answer; the plan's notice is gone" [ "$(cat "$TMP/out.log")" = "$(printf 'earlier line\nCREDIT-DONE line one\nline two')" ]
check "…the credit run got the stdin prompt" grep -qx 'prompt from stdin' "$TMP/claude-stdin"
reset; echo open > "$TMP/vault-mode"; echo weekly0 > "$TMP/claude-mode"; echo foreign > "$TMP/credit-mode"
echo "earlier line" > "$TMP/out.log"
run "$AI" --role brain --out "$TMP/out.log" -- "x" > /dev/null 2>&1; rc=$?
check "something else wrote to --out meanwhile: nothing is cut, the answer is appended (rc=$rc)" \
  [ "$(cat "$TMP/out.log")" = "$(printf 'earlier line\n%s\nFOREIGN LINE\nCREDIT-DONE' "$NOTICE_WEEKLY0")" ]
reset; echo open > "$TMP/vault-mode"; echo partial > "$TMP/claude-mode"
out="$(run "$AI" --role brain -- "three steps")"; rc=$?
check "a limit after partial output: the answer is the credit run's, from the start (rc=$rc)" [ "$rc $out" = "0 $(printf 'CREDIT-DONE line one\nline two')" ]
check "…and the record says the prompt restarted" grep -qE $'\tprompt=restarted\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"
reset; echo open > "$TMP/vault-mode"; echo weekly1 > "$TMP/claude-mode"
out="$(run env AI_RUN_WORKER=claude "$AI" --role worker -- "by hand")"; rc=$?
check "the worker role on Claude takes the same one credit run (rc=$rc)" [ "$rc|$(claude_calls)$(npm_calls)" = "0|21" ]
check "…its plan line keeps engine=claude-override and exit 1" grep -qE $'\trole=worker\tengine=claude-override\tcaller=[^\t]+\texit=1\tstop=CLAUDE_LIMIT_TO_CREDIT\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log 2)"
reset; echo open > "$TMP/vault-mode"; echo limit > "$TMP/codex-mode"; echo weekly1 > "$TMP/claude-mode"
out="$(run "$AI" --role worker -- "fix")"; rc=$?
check "Codex out, then Claude's plan out: still ONE credit run, and it answers (rc=$rc)" [ "$rc|$(codex_calls)$(claude_calls)$(npm_calls)" = "0|121" ]
check "…the answer follows the Codex hand-off line" grep -q 'CREDIT-DONE line one' <<<"$out"
absent "…and no limit notice or stop is left in it" grep -qE 'weekly limit|NAMED STOP' <<<"$out"
reset; echo open > "$TMP/vault-mode"; echo weekly0 > "$TMP/claude-mode"
out="$(run env AI_RUN_CLAUDE_ARGS='--max-turns 3 --output-format json' "$AI" --role brain -- "x")"; rc=$?
check "a job with its own --output-format gets Claude's own output back, no second format added (rc=$rc)" \
  [ "$rc|$(sed -n 2p "$TMP/claude-args.log")" = "0|-p --model opus --max-turns 3 --output-format json" ]
check "…the answer is the raw result event" grep -q '^{"type":"result".*"result":"CREDIT-DONE' <<<"$out"
check "…and its cost is still recorded" grep -q $'\tcost_usd=0\\.003200\t' <<<"$(last_log)"

echo "=== 11. the credit cannot run: the named stop with its own reason; never success, never a second try ==="
outage() { # outage <label> <vault-mode> <credit-mode> <credit code> <claude calls> <reason regex> [cost logged: a number, unknown, or nothing when claude never started]
  reset; echo "$2" > "$TMP/vault-mode"; echo "$3" > "$TMP/credit-mode"; echo weekly0 > "$TMP/claude-mode"
  run "$AI" --role brain --out "$TMP/out.log" -- "plan" > "$TMP/so" 2> "$TMP/se"; local rc=$?
  check "$1: exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
  check "$1: stdout is the reason line, then the unchanged named stop as the LAST line" \
    [ "$(sed -n 1p "$TMP/so" | grep -cE "^The free API credit was tried once and did not run: $6")$(sed -n 2p "$TMP/so")$(grep -c . "$TMP/so")" = "1${STOP_WEEKLY0}2" ]
  check "$1: --out holds the plan's notice, the reason and the stop, and no answer" \
    [ "$(sed -n 1p "$TMP/out.log")|$(sed -n 2p "$TMP/out.log" | cut -c1-48)|$(sed -n 3p "$TMP/out.log")|$(grep -c . "$TMP/out.log")" = "$NOTICE_WEEKLY0|The free API credit was tried once and did not r|$STOP_WEEKLY0|3" ]
  absent "$1: no answer text anywhere" grep -q 'CREDIT-DONE' "$TMP/so" "$TMP/out.log"
  check "$1: claude ran $5 time(s) in all, the vault was asked once at most" [ "$(claude_calls)|$(npm_calls | sed 's/^[01]$/at-most-1/')" = "$5|at-most-1" ]
  check "$1: the usage log ends exit 76 stop=CLAUDE_LIMIT credit=$4${7:+ cost_usd=$7}" grep -qE $'\tengine=claude-credit\tcaller=[^\t]+\texit=76\tstop=CLAUDE_LIMIT\tcredit='"$4${7:+$'\t'cost_usd=${7//./\\.}}"$'\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"
  check "$1: the private directory of the run is gone" [ -z "$(ls "$TMP/tmp")" ]
}
outage "vault locked"        locked  ok      VAULT_UNREADABLE 1 'the Boss OS vault did not open \(vault:run exit 1: VAULT GATE: No vault master key in Keychain'
outage "no key in the vault" nokey   ok      NO_KEY           1 'the Boss OS vault holds no ANTHROPIC_API_KEY\.$'
outage "credit used up"      open    low     REFUSED          2 'Claude on the key said: Credit balance is too low \(HTTP 400\)$' 0.000000
outage "key invalid"         open    invalid REFUSED          2 'Claude on the key said: Invalid API key · Fix external API key \(HTTP 401\)$' 0.000000
outage "org refuses"         open    refused REFUSED          2 'Claude on the key said: This organization has been disabled\. \(HTTP 403\)$' 0.000000
outage "network down"        open    netdown REFUSED          2 'Claude on the key said: API Error: Connection error\.$' 0.000000
outage "a limit of its own"  open    limit   LIMIT            2 'the run on the key reported a limit of its own: You.ve hit your weekly limit' 0.000000
outage "an empty answer"     open    empty   NO_ANSWER        2 'Claude on the key handed back an empty answer\.$' 0.010000
outage "an unreadable answer" open   garbage NO_ANSWER        2 'Claude on the key gave no answer \(exit 139\): Segmentation fault$' unknown
outage "silence with exit 0" open    silent  NO_ANSWER        2 'Claude on the key gave no answer \(exit 0\): it printed nothing$' unknown
outage "an answer but a failed exit" open okbutrc NO_ANSWER   2 'Claude on the key answered but ended with exit 3, so its answer is not used\.$' 0.002000
reset; echo weekly0 > "$TMP/claude-mode"
out="$(run env AI_RUN_VAULT_REPO="$TMP/no-such-checkout" "$AI" --role brain -- "x")"; rc=$?
check "no vault checkout on this machine: exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
check "…said so" grep -q 'did not run: the Boss OS vault cannot be run on this machine' <<<"$out"
check "…and nothing was run in its place" no_vault
check "…the usage log says credit=VAULT_UNREADABLE, and no cost: claude never started" grep -qE $'\tstop=CLAUDE_LIMIT\tcredit=VAULT_UNREADABLE\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"

echo "=== 12. AI_RUN_NO_CREDIT=1 (a job that needs her claude.ai sign-in): the old named stop, byte for byte ==="
reset; echo open > "$TMP/vault-mode"; echo weekly0 > "$TMP/claude-mode"
echo "earlier line" > "$TMP/out.log"
run env AI_RUN_NO_CREDIT=1 "$AI" --role brain --out "$TMP/out.log" -- "read her mail" > "$TMP/so" 2> "$TMP/se"; rc=$?
check "exit 76 (rc=$rc)" [ "$rc" -eq 76 ]
check "stdout is the named stop alone" [ "$(cat "$TMP/so")" = "$STOP_WEEKLY0" ]
check "--out is the earlier line, the plan's notice and the stop, nothing else" [ "$(cat "$TMP/out.log")" = "$(printf 'earlier line\n%s\n%s' "$NOTICE_WEEKLY0" "$STOP_WEEKLY0")" ]
check "the vault was never asked" no_vault
check "claude ran once" [ "$(claude_calls)" -eq 1 ]
check "the usage log line is the old one: exit 76 stop=CLAUDE_LIMIT and nothing after" grep -qE $'\tengine=claude\tcaller=[^\t]+\texit=76\tstop=CLAUDE_LIMIT\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"
reset; echo open > "$TMP/vault-mode"; echo weekly1 > "$TMP/claude-mode"
out="$(run env AI_RUN_NO_CREDIT=1 "$AI" --role brain -- "x")"; rc=$?
check "without --out: the notice then the stop, as before (rc=$rc)" \
  [ "$rc|$out" = "76|$(printf "You've hit your weekly limit · resets 9am (America/New_York)\nNAMED STOP [CLAUDE_LIMIT] resets 9am (America/New_York) — the work waits for the reset; no Codex or free fallback.")" ]
check "…and no vault" no_vault

check "pnp-listings (Claude in Chrome needs her claude.ai sign-in) keeps the plain stop: its ai-run call sets AI_RUN_NO_CREDIT=1" \
  grep -qE "AI_RUN_NO_CREDIT=1 .*AI_RUN_CLAUDE_ARGS='--chrome " "$ROOT/pnp-listings.sh"
check "the shorts-arm email (Gmail connector) keeps the plain stop: its brain call sets AI_RUN_NO_CREDIT=1" \
  grep -qE '^AI_RUN_NO_CREDIT=1 "\$AI_RUN" --role brain .*Gmail connector' "$ROOT/shorts-arm.sh"
connector_calls="$(cd "$ROOT" && git ls-files 2>/dev/null | grep -vE '^(tests/|docs/|README\.md$|ai-run$)' | while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] && grep -nE '(ai-run|AI_RUN"?) .*(--chrome|connector)|--chrome.*(ai-run|AI_RUN)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'AI_RUN_NO_CREDIT=1' | sed "s|^|$f:|"; done)"
# (The symlinked runners, such as mailbox-sweep.sh, are Boss OS's files: that repo sets the flag in them.)
check "no job of this repo hands ai-run a connector or Chrome prompt without AI_RUN_NO_CREDIT=1 (found: ${connector_calls:-none})" [ -z "$connector_calls" ]

echo "=== 13. the test-only switch: refused for any caller not named test-…; never a real job's road to the credit ==="
reset; echo open > "$TMP/vault-mode"
out="$(run env AI_RUN_TEST_PLAN_LIMITED=1 AI_RUN_CALLER=ship-review "$AI" --role brain -- "x")"; rc=$?
check "a real caller is refused: exit 64 NAMED STOP [TEST_ONLY] (rc=$rc)" [ "$rc|${out%%]*}" = "64|NAMED STOP [TEST_ONLY" ]
check "…claude never ran" no_claude
check "…nor the vault" no_vault
out="$(run env AI_RUN_TEST_PLAN_LIMITED=1 "$AI" --role brain -- "x")"; rc=$?
check "no caller name at all is refused too (rc=$rc)" [ "$rc|$(claude_calls)|$(npm_calls)" = "64|0|0" ]
out="$(run env AI_RUN_TEST_PLAN_LIMITED=1 AI_RUN_CALLER=attest-x "$AI" --role brain -- "x")"; rc=$?
check "a name that only CONTAINS test- is refused (rc=$rc)" [ "$rc|$(claude_calls)|$(npm_calls)" = "64|0|0" ]
reset; echo open > "$TMP/vault-mode"
out="$(run env AI_RUN_TEST_PLAN_LIMITED=1 AI_RUN_CALLER=test-credit "$AI" --role brain -- "reply with the word ok")"; rc=$?
check "a test- caller: the plan is not asked, ONE run on the key answers (rc=$rc)" [ "$rc|$(claude_calls)$(npm_calls)|$(env_of 1)" = "0|11|key=$KEYSUM other= npm= path=own" ]
check "…logged as the test switch" grep -qE $'\tstop=TEST_PLAN_LIMITED_TO_CREDIT\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log 2)"
check "…then the credit run, under the test caller's name" grep -q $'\tengine=claude-credit\tcaller=test-credit\texit=0\tcost_usd=' <<<"$(last_log)"
reset
out="$(run env AI_RUN_TEST_PLAN_LIMITED=1 AI_RUN_CALLER=test-credit "$AI" --role brain -- "x")"; rc=$?
check "a test- caller with the vault locked: exit 76 and claude never ran (rc=$rc)" [ "$rc|$(claude_calls)" = "76|0" ]
check "…the stop says the plan was not asked" grep -q 'NAMED STOP \[CLAUDE_LIMIT\] resets unknown (test-only switch: the plan was not asked)' <<<"$out"

echo "=== 14. the key's value is in nothing the run leaves, even when claude itself prints it ==="
: > "$AI_RUN_LOG"
leaks() { grep -rlF -- "$1" "$TMP" 2>/dev/null | grep -v "^$TMP/vault/"; }
check "the search can see a key: it finds the fake vault's own copy" grep -rqF -- "$KEY" "$TMP/vault"
for mode in ok leak errleak crashleak low; do
  reset; echo open > "$TMP/vault-mode"; echo "$mode" > "$TMP/credit-mode"; echo weekly0 > "$TMP/claude-mode"
  run "$AI" --role brain --out "$TMP/out.log" -- "plan" > "$TMP/so" 2> "$TMP/se"
  cp "$TMP/out.log" "$TMP/kept-out-$mode"; cp "$TMP/so" "$TMP/kept-so-$mode"; cp "$TMP/se" "$TMP/kept-se-$mode"
  cp "$TMP/claude-args.log" "$TMP/kept-claude-args-$mode"; cp "$TMP/npm-args.log" "$TMP/kept-npm-args-$mode"
  run "$AI" --role brain -- "plan" > "$TMP/kept-so2-$mode" 2> "$TMP/kept-se2-$mode"
done
check "claude DID print its key in these runs, and the answer came back with it replaced" grep -qx 'CREDIT-DONE and my key is \[key removed\]' "$TMP/kept-out-leak"
check "…in the reason line too, when the error text carried it" grep -q 'Claude on the key said: rejected key \[key removed\] (HTTP 401)' "$TMP/kept-so-errleak"
check "…and when a crash printed it on stderr" grep -q 'gave no answer (exit 2): fatal: bad key \[key removed\]' "$TMP/kept-so2-crashleak"
check "the key's value is in NO file: --out, stdout, stderr, usage log, argument logs, temp files ($(leaks "$KEY" | head -3 | tr '\n' ' '))" [ -z "$(leaks "$KEY")" ]
check "the vault's other secret is in no file either" [ -z "$(leaks "$OTHER")" ]
check "the usage log of these runs never names more than cost, source and a reason code" \
  [ "$(grep -cvE $'\texit=[0-9]+(\tstop=[A-Z_]+)?(\tcost_usd=[0-9.]+\tkey_source=[A-Za-z_]+\tprompt=restarted|\tcredit=[A-Z_]+(\tcost_usd=(unknown|[0-9.]+))?)?\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' "$AI_RUN_LOG")|$(grep -c 'engine=claude-credit' "$AI_RUN_LOG")" = "0|10" ]
absent "ai-run itself never assigns, exports or stores the key (the vault's child process is the only holder)" \
  grep -nE '(export|declare -x|launchctl setenv|defaults write)[^#]*ANTHROPIC_API_KEY|ANTHROPIC_API_KEY=|settings\.json|\.zshrc|\.zprofile|\.bash_profile' "$AI"

echo "=== 15. a kill during the credit run reaches claude, under npm and the vault ==="
reset; echo open > "$TMP/vault-mode"; echo slow > "$TMP/credit-mode"; echo weekly0 > "$TMP/claude-mode"
env PATH="$BIN:$PATH" "$AI" --role brain --out "$TMP/out.log" -- "long" > "$TMP/so" 2>&1 & AIPID=$!
for _ in $(seq 1 100); do [ -s "$TMP/credit-started" ] && break; sleep 0.1; done
check "the credit run started" [ -s "$TMP/credit-started" ]
START=$(date +%s); kill -TERM "$AIPID"; wait "$AIPID"; rc=$?
sleep 0.5
check "ai-run ends when killed, as the named stop, never as success (rc=$rc)" [ "$rc" -eq 76 ]
check "…within 10 s" test $(( $(date +%s) - START )) -lt 10
absent "the claude child on the key did not survive the kill" pgrep -f "$BIN/claude -p"
check "…the reason says the run on the key was stopped" grep -q 'did not run: .*\(stopped before it answered\|gave no answer\)' "$TMP/so"
reset; echo open > "$TMP/vault-mode"; echo slow > "$TMP/credit-mode"; echo weekly0 > "$TMP/claude-mode"; t0=$SECONDS
out="$(AI_RUN_MAX_SECS=2 run "$AI" --role brain -- "long")"; rc=$?
sleep 0.5
check "the time cap holds the credit run too: stopped at 2 s, the named stop, never success (rc=$rc, $((SECONDS-t0)) s)" [ "$rc|$((SECONDS-t0 < 15))" = "76|1" ]
check "…the reason names the cap" grep -q 'did not run: the run on the key was stopped at its 2-second cap (AI_RUN_MAX_SECS)\.$' <<<"$out"
absent "…and the claude child on the key is gone" pgrep -f "$BIN/claude -p"
check "…the usage log says credit=TIME_CAP and that the cost of the stopped run is unknown, never nothing" grep -qE $'\texit=76\tstop=CLAUDE_LIMIT\tcredit=TIME_CAP\tcost_usd=unknown\tbytes=[1-9][0-9]*\tsecs=[0-9]+$' <<<"$(last_log)"

echo "=== 16. the day's run cap counts the credit run too: a loop cannot drain the credit ==="
reset; : > "$AI_RUN_LOG"; echo open > "$TMP/vault-mode"; echo weekly0 > "$TMP/claude-mode"
out="$(AI_RUN_CALLER=loopy AI_RUN_MAX_RUNS=2 run "$AI" --role brain -- "round 1")"; rc=$?
check "the first run of the day moves to the credit and answers (rc=$rc): two Claude runs logged" [ "$rc|$(grep -c $'\tcaller=loopy\t' "$AI_RUN_LOG")" = "0|2" ]
out="$(AI_RUN_CALLER=loopy AI_RUN_MAX_RUNS=2 run "$AI" --role brain -- "round 2")"; rc=$?
check "the next is held by the cap of 2: exit 75 NAMED STOP [RUN_CAP] (rc=$rc)" [ "$rc|${out%%]*}" = "75|NAMED STOP [RUN_CAP" ]
check "…with no further plan run and no further vault call" [ "$(claude_calls)$(npm_calls)" = "21" ]

echo
[ "$asserts" -gt 0 ] || { echo "NAMED STOP [ZERO_ASSERTIONS] nothing was checked."; exit 3; }
echo "$((asserts - failed))/$asserts passed"
[ "$failed" -eq 0 ] || exit 1
echo "ai-run routes hands-on work to Codex, brains to Claude; a Codex limit hands the run to Claude; a Claude limit runs once on the free API credit, then is the named stop (27 Nov 2026)."
