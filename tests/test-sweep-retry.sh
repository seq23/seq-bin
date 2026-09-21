#!/bin/bash
# ci-sweep.sh end to end, against fakes: RETRY WHILE RED, SLEEP IS NOT A HANG,
# TEMPFIX DOES NOT END THE DAY.
#
# WHY THIS EXISTS
# 2026-09-21, 10:07 run: the Mac slept on battery 10:40-12:25 with round 1 in
# flight. At wake the half round was audited against a PR someone else had
# pushed in the gap (MAIN-RED-TEMPFIX), the wall-clock watchdog fired a minute
# later (MAIN-RED-HUNG), and nothing ran again until 18:07. Her ruling: "it
# should keep trying and never leave a main on red."
#
# Everything the wrapper talks to is faked here — claude, gh, the keychain, the
# probe, the audit — so the wrapper's OWN decisions are what is under test: the
# ledger it writes, the gate it reads, the sentry that ends a run, what it does
# to a PR (a note, never a merge or a close), and what it tells the next attempt.
# The notifier is the real one in dry mode, so the escalation subject is proven
# on the real text.
#
# RULE 0: zero assertions executed is NOT a pass. And one assertion is proven
# negatively: with the ledger write neutralised, "green means no retry" must
# stop holding, or the assertion was never reading the ledger.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SWEEP="$ROOT/ci-sweep.sh"
for f in "$SWEEP" "$ROOT/ci-sweep-notify.sh" "$ROOT/ci-sweep-stream.py"; do
  [ -x "$f" ] || { echo "NAMED STOP [MISSING] $f is missing or not executable."; exit 3; }
done
command -v timeout >/dev/null 2>&1 || { echo "NAMED STOP [NO_TIMEOUT] GNU timeout is required by the sweep."; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
asserts=0; failed=0
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check() { # check <description> <condition-command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}
# `!` is a reserved word, not a command: passed through "$@" it is looked up
# as a program and fails, which would make every "must NOT" check pass for the
# wrong reason. So the negation lives here.
absent() { # absent <description> <condition-command...>  — passes when the command FAILS
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$what"; else ok "$what"; fi
}

# --- the fakes ---------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/github" "$TMP/logs"
cat > "$BIN/claude" <<'SH'
#!/bin/bash
# The headless model. Its mode is a file so one shim serves every scenario.
case "$(cat "$FAKE_DIR/claude-mode" 2>/dev/null)" in
  sleep) echo "round started; working..."; sleep 300 ;;
  *)     echo "Dispatched one agent; watched the lane; landed a fix."; echo "CI-SWEEP-COMPLETE: fixed" ;;
esac
SH
cat > "$BIN/gh" <<'SH'
#!/bin/bash
# Every call is logged so the test can assert what the sweep did to a PR.
echo "$*" >> "$FAKE_DIR/gh-calls.log"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")   exit 0 ;;
  "pr list")
    repo=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = "--repo" ] && { j=$((i+1)); repo="${!j##*/}"; }; done
    [ -f "$FAKE_DIR/open-prs" ] && grep -E "^$repo	" "$FAKE_DIR/open-prs"; exit 0 ;;
  "pr view")     exit 0 ;;
  "pr comment")  exit 0 ;;
  *) exit 0 ;;
esac
SH
printf '#!/bin/bash\nexit 0\n' > "$BIN/security"
cat > "$TMP/probe.sh" <<'SH'
#!/bin/bash
case "$(cat "$FAKE_DIR/probe-mode")" in
  green) printf 'GREEN\talpha\tbuild\talpha|build|success|-\tok\n'; exit 0 ;;
  *)     printf 'RED\talpha\tbuild\talpha|build|failure|test\tfailed\n'; exit 1 ;;
esac
SH
cat > "$TMP/audit.sh" <<'SH'
#!/bin/bash
: > "$FAKE_DIR/audit-called"
case "$(cat "$FAKE_DIR/audit-mode")" in
  fatal)         echo "  ✗ FATAL alpha#7 (a fix) — a command's failure is being swallowed"; echo "TEMP FIXES DETECTED"; exit 1 ;;
  fatal-outside) echo "  ✗ FATAL zeta#9 (someone else's) — a command's failure is being swallowed"; echo "TEMP FIXES DETECTED"; exit 1 ;;
  *)             echo "  ✓ alpha#7 — no weakening pattern"; echo "No weakening patterns found."; exit 0 ;;
esac
SH
chmod +x "$BIN"/* "$TMP/probe.sh" "$TMP/audit.sh"
echo "trivial prompt" > "$TMP/prompt.md"
export FAKE_DIR="$TMP"
echo green > "$TMP/probe-mode"; echo clean > "$TMP/audit-mode"; echo fixed > "$TMP/claude-mode"

LOGS="$TMP/logs"; LEDGER="$LOGS/state/outcomes.tsv"; CARRY="$LOGS/state/carryover-next.md"
NOW="$(date +%s)"
at() { python3 -c 'import datetime,sys; d=datetime.datetime.now().replace(hour=int(sys.argv[1]),minute=0,second=0,microsecond=0); print(int(d.timestamp()))' "$1"; }

# Window forced open for every scenario except the one that tests the window,
# so the suite does not depend on the hour it happens to run at.
sweep() { # sweep <run-id> [ENV=VAL ...]
  local id="$1"; shift
  env PATH="$BIN:$PATH" CI_SWEEP_LOG_DIR="$LOGS" CI_SWEEP_PROMPT="$TMP/prompt.md" \
      CI_SWEEP_PROBE_BIN="$TMP/probe.sh" CI_SWEEP_AUDIT_BIN="$TMP/audit.sh" \
      CI_SWEEP_NOTIFY_BIN="$ROOT/ci-sweep-notify.sh" CI_SWEEP_NOTIFY_DRY=1 \
      CI_SWEEP_STREAM_BIN="$ROOT/ci-sweep-stream.py" CI_SWEEP_CLAUDE_BIN="$BIN/claude" \
      CI_SWEEP_GITHUB_DIR="$TMP/github" CI_SWEEP_RUN_ID="$id" \
      CI_SWEEP_WINDOW_START_H=0 CI_SWEEP_WINDOW_END_H=24 CI_SWEEP_MAX_ROUNDS=1 \
      "$@" "$SWEEP" >"$TMP/$id.out" 2>&1
}
gate() { # gate <now-epoch> [ENV=VAL ...] -> prints the decision
  local now="$1"; shift
  env CI_SWEEP_LOG_DIR="$LOGS" CI_SWEEP_GATE_ONLY=1 CI_SWEEP_NOW="$now" \
      CI_SWEEP_WINDOW_START_H=0 CI_SWEEP_WINDOW_END_H=24 "$@" "$SWEEP" 2>&1 | sed 's/^\[gate\] //'
}
last_verdict() { awk -F'\t' 'END{print $3}' "$LEDGER" 2>/dev/null; }

# =============================================================================
echo "=== 1. a GREEN run schedules NO retry ==="
sweep run-green; rc=$?
check "green run exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "the ledger records MAIN-GREEN" [ "$(last_verdict)" = "MAIN-GREEN" ]
d="$(gate "$NOW")"
check "the next tick is NOT DUE: $d" grep -q '^SKIP.*proven green' <<<"$d"
d="$(gate $(( NOW + 470 * 60 )))"
check "a tick after the green TTL IS due: $d" grep -q '^RUN' <<<"$d"
check "no carryover is left for a next attempt" [ ! -f "$CARRY" ]
absent "a green run notifies nobody" grep -q 'notify:dry' "$LOGS/run-green.log"

# =============================================================================
echo "=== 2. a non-green run schedules a retry ~30 min later, inside the window ==="
echo red > "$TMP/probe-mode"
sweep run-red1; rc=$?
check "red run exits 20 (rc=$rc)" [ "$rc" -eq 20 ]
check "verdict is MAIN-RED-EXHAUSTED (1 round allowed)" [ "$(last_verdict)" = "MAIN-RED-EXHAUSTED" ]
check "the log names the retry" grep -q '^\[.*\] RETRY: attempt #1 today was not green; the next attempt is the first tick at or after' "$LOGS/run-red1.log"
END="$(awk -F'\t' 'END{print $1}' "$LEDGER")"
d="$(gate $(( END + 10 * 60 )))"
check "10 min after the end: cooling, NOT due: $d" grep -q '^SKIP last attempt (#1 today) ended 10 min ago' <<<"$d"
d="$(gate $(( END + 30 * 60 )))"
check "30 min after the end: retry IS due: $d" grep -q '^RUN retry' <<<"$d"
d="$(gate "$(at 3)" CI_SWEEP_WINDOW_START_H=10 CI_SWEEP_WINDOW_END_H=22)"
check "03:00 is outside the window even when red: $d" grep -q '^SKIP outside the 10:00-22:00 window' <<<"$d"
d="$(gate "$(at 23)" CI_SWEEP_WINDOW_START_H=10 CI_SWEEP_WINDOW_END_H=22)"
check "23:00 is outside the window even when red: $d" grep -q '^SKIP outside' <<<"$d"
check "a carryover for the next attempt exists and names the verdict" grep -q 'MAIN-RED-EXHAUSTED' "$CARRY"

# =============================================================================
echo "=== 3. the retry is briefed with the previous attempt ==="
sweep run-red2
check "round 1 of the retry opened with the previous attempt's carryover" grep -q 'A PREVIOUS ATTEMPT TODAY DID NOT REACH GREEN' "$LOGS/run-red2.d/carryover-1.md"
check "the run log says it was a retry" grep -q 'round 1 is a RETRY' "$LOGS/run-red2.log"
check "the carryover was consumed and rewritten for the next attempt" grep -q 'run-red2' "$CARRY"

# =============================================================================
echo "=== 4. TEMPFIX rejects the PR — never merges, never closes — and does not end the day ==="
echo fatal > "$TMP/audit-mode"; : > "$TMP/gh-calls.log"
sweep run-tempfix; rc=$?
check "verdict is MAIN-RED-TEMPFIX" [ "$(last_verdict)" = "MAIN-RED-TEMPFIX" ]
check "the PR is recorded as rejected" grep -q '^alpha#7' "$LOGS/run-tempfix.d/rejected"
check "a REJECTED note went on the PR" grep -q '^pr comment 7 --repo seq23/alpha' "$TMP/gh-calls.log"
absent "the sweep never merged or closed anything" grep -qE '^pr (merge|close)' "$TMP/gh-calls.log"
check "the next attempt is told what was rejected and why" grep -q 'REJECTED by the audit' "$CARRY"
check "…naming the PR" grep -q 'alpha#7' "$CARRY"
check "…and still schedules the retry" grep -q 'RETRY: attempt #' "$LOGS/run-tempfix.log"
check "the escalation text says DO NOT MERGE" grep -q 'DO NOT MERGE' "$LOGS/run-tempfix.log"
echo fatal-outside > "$TMP/audit-mode"; : > "$TMP/gh-calls.log"
sweep run-tempfix-outside
check "a FATAL outside the round's repos is not the sweep's to reject" grep -q 'not rejecting zeta#9: outside this run' "$LOGS/run-tempfix-outside.log"
absent "…so no note went on that PR" grep -q '^pr comment 9' "$TMP/gh-calls.log"
echo clean > "$TMP/audit-mode"

# =============================================================================
echo "=== 5. the sixth non-green attempt escalates ONCE, then the cadence slows ==="
rm -rf "$LOGS/state"; mkdir -p "$LOGS/state"
TODAY="$(date +%Y-%m-%d)"
for i in 5 4 3 2 1; do printf '%s\t%s\tMAIN-RED-STUCK\tcrafted-%s\n' $(( NOW - i * 3600 )) "$TODAY" "$i"; done > "$LEDGER"
sweep run-sixth
check "attempt #6 is named in the log" grep -q 'RETRY: attempt #6 today' "$LOGS/run-sixth.log"
check "it escalates" grep -q '^\[.*\] ESCALATING: 6 non-green attempts today' "$LOGS/run-sixth.log"
check "the subject says main is still red after 6 attempts and needs her" grep -qF 'CI sweep: main still red after 6 attempts today — needs you' "$LOGS/run-sixth.log"
check "the once-a-day marker exists" [ -f "$LOGS/state/escalated-$TODAY" ]
check "…and the retry is still scheduled after escalating" grep -q 'RETRY: attempt #6' "$LOGS/run-sixth.log"
END="$(awk -F'\t' 'END{print $1}' "$LEDGER")"
d="$(gate $(( END + 30 * 60 )))"
check "30 min later: slow cadence, NOT due: $d" grep -q 'slow cadence' <<<"$d"
d="$(gate $(( END + 125 * 60 )))"
check "125 min later: due again — it never stops: $d" grep -q '^RUN retry' <<<"$d"
sweep run-seventh
absent "the seventh attempt does not escalate twice" grep -q 'ESCALATING' "$LOGS/run-seventh.log"
echo green > "$TMP/probe-mode"; sweep run-green-again
d="$(gate $(( $(date +%s) + 60 )))"
check "a green run resets the day: $d" grep -q '^SKIP.*proven green' <<<"$d"
echo red > "$TMP/probe-mode"

# =============================================================================
echo "=== 6. SLEEP IS NOT A HANG: a heartbeat gap ends the run as INTERRUPTED and parks its PR ==="
echo sleep > "$TMP/claude-mode"; rm -f "$TMP/audit-called"; : > "$TMP/gh-calls.log"
printf 'alpha\t11\twork/half-done\tHalf a fix\n' > "$TMP/open-prs"
sweep run-sleep CI_SWEEP_TICK_SECS=1 CI_SWEEP_SLEEP_GAP_SECS=3 CI_SWEEP_DEADLINE_MIN=30 CI_SWEEP_HARD_KILL_MIN=45 &
SWEEP_PID=$!
for _ in $(seq 1 40); do [ -s "$LOGS/run-sleep.d/sentry-pid" ] && break; sleep 0.5; done
SENTRY="$(cat "$LOGS/run-sleep.d/sentry-pid" 2>/dev/null || echo "")"
if [ -z "$SENTRY" ]; then
  bad "the sentry never announced itself; cannot simulate a sleep"
else
  sleep 2
  kill -STOP "$SENTRY"; sleep 6; kill -CONT "$SENTRY"   # the Mac "sleeps" for 6s > 3s gap
  wait "$SWEEP_PID"; rc=$?
  check "the run ends as MAIN-RED-INTERRUPTED (rc=$rc)" [ "$rc" -eq 22 ]
  check "the ledger says INTERRUPTED, not HUNG" [ "$(last_verdict)" = "MAIN-RED-INTERRUPTED" ]
  check "the gap is named in seconds" grep -qE 'no heartbeat for [0-9]+s' "$LOGS/run-sleep.d/interrupted"
  check "the half round was NOT audited as landed work" [ ! -f "$TMP/audit-called" ]
  check "the PR the cut-off round opened is PARKED" grep -q 'PARKED alpha#11' "$LOGS/run-sleep.log"
  check "…with a note on the PR" grep -q '^pr comment 11 --repo seq23/alpha' "$TMP/gh-calls.log"
  absent "…and never merged or closed" grep -qE '^pr (merge|close)' "$TMP/gh-calls.log"
  check "the next attempt is told the PR is parked" grep -q 'PARKED' "$CARRY"
  check "the lock was released" [ ! -d "$LOGS/.lock" ]
  check "a retry is scheduled" grep -q 'RETRY: attempt #' "$LOGS/run-sleep.log"
fi
rm -f "$TMP/open-prs"

# =============================================================================
echo "=== 7. a stall with NO gap is still HUNG, on awake time ==="
rm -f "$TMP/audit-called"
sweep run-hang CI_SWEEP_TICK_SECS=1 CI_SWEEP_DEADLINE_MIN=30 CI_SWEEP_HARD_KILL_MIN=1; rc=$?
check "the run ends as MAIN-RED-HUNG (rc=$rc)" [ "$rc" -eq 21 ]
check "the ledger says HUNG" [ "$(last_verdict)" = "MAIN-RED-HUNG" ]
check "no sleep gap was recorded" [ ! -f "$LOGS/run-hang.d/interrupted" ]
check "the ceiling was counted in ticks" grep -q 'ticks of 1s awake' "$LOGS/run-hang.d/hung"
check "a retry is scheduled after a hang too" grep -q 'RETRY: attempt #' "$LOGS/run-hang.log"
echo fixed > "$TMP/claude-mode"

# =============================================================================
echo "=== 8. a precondition stop is an attempt too (retried, never silent) ==="
mkdir -p "$TMP/nogh"; printf '#!/bin/bash\n[ "$1 $2" = "auth status" ] && exit 1; exit 0\n' > "$TMP/nogh/gh"; chmod +x "$TMP/nogh/gh"
sweep run-noauth PATH="$TMP/nogh:$BIN:$PATH"
check "gh unauthenticated is MAIN-UNKNOWN" [ "$(last_verdict)" = "MAIN-UNKNOWN" ]
check "…and schedules a retry" grep -q 'RETRY: attempt #' "$LOGS/run-noauth.log"

# =============================================================================
echo "=== negative proof: with the ledger write neutralised, green must STOP meaning no retry ==="
sed 's/^record_outcome() {$/record_outcome() { return 0; }\nrecord_outcome_disabled() {/' "$SWEEP" > "$TMP/crippled.sh"
chmod +x "$TMP/crippled.sh"
if ! grep -q 'record_outcome_disabled' "$TMP/crippled.sh"; then
  bad "SETUP BROKEN — could not neutralise the ledger write, so the negative proof is void"
else
  rm -rf "$LOGS/state"; echo green > "$TMP/probe-mode"
  SWEEP_SAVE="$SWEEP"; SWEEP="$TMP/crippled.sh"
  sweep run-crippled
  d="$(gate "$NOW")"
  SWEEP="$SWEEP_SAVE"
  if grep -q '^SKIP.*proven green' <<<"$d"; then
    bad "NO TEETH — the gate still said 'proven green' with no ledger written: $d"
  else
    ok "PROVEN   without the ledger write the gate no longer sees the green ($d), so section 1 reads the ledger"
  fi
fi

# --- Rule 0 ------------------------------------------------------------------
if [ "$asserts" -eq 0 ]; then
  echo "RULE 0 [ASSERTED_NOTHING] this suite executed zero assertions."; exit 2
fi
echo "=== $asserts assertion(s) executed ==="
if [ "$failed" -gt 0 ]; then
  echo "SWEEP RETRY TESTS FAILED: $failed of $asserts."
  for f in "$TMP"/*.out; do [ -s "$f" ] && { echo "--- $(basename "$f")"; tail -20 "$f"; }; done
  exit 1
fi
echo "ci-sweep.sh retries every non-green outcome, stops on green, escalates once at $(grep -oE 'MAX_ATTEMPTS:-[0-9]+' "$SWEEP" | head -1 | cut -d- -f2), classes a sleep as INTERRUPTED and a stall as HUNG, and never merges or closes a PR."
exit 0
