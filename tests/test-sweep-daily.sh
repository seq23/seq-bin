#!/bin/bash
# ci-sweep.sh end to end, against fakes: THE DAILY DESIGN (23 Sep 2026).
#
# WHAT IS UNDER TEST — the wrapper's OWN decisions, with claude, gh, land, the
# keychain, the probe and the audit all faked:
#   · a PARKED repo does not end the run; the other red repos are still worked;
#   · rounds continue while they make progress (past two), and the run is STUCK
#     only after two CONSECUTIVE rounds without progress;
#   · the sweep merges only PRs whose checks IT read green — `land` where land
#     knows the repo, `gh pr merge --merge --delete-branch` otherwise — never a
#     rejected, suspect, parked-repo or failing-check PR;
#   · every `claude -p` carries `--model opus`;
#   · every run ends with one banner; issues only for parked/stuck repos and
#     run-level faults; a green run files nothing; nothing schedules a retry;
#   · sleep is INTERRUPTED (not HUNG), a stall is HUNG, a TEMPFIX rejects the PR
#     without merging or closing it.
# The notifier is the real one in dry mode, so the summary and issues are proven on
# the real text.
#
# RULE 0: zero assertions executed is NOT a pass. One assertion is proven
# negatively: with the checks gate neutralised, the failing-check PR must get
# merged, or the assertion was never reading the gate.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SWEEP="$ROOT/ci-sweep.sh"
for f in "$SWEEP" "$ROOT/ci-sweep-notify.sh" "$ROOT/ci-sweep-stream.py"; do
  [ -x "$f" ] || { echo "NAMED STOP [MISSING] $f is missing or not executable."; exit 3; }
done
command -v timeout >/dev/null 2>&1 || { echo "NAMED STOP [NO_TIMEOUT] GNU timeout is required by the sweep."; exit 3; }

TMP="$(mktemp -d)"
# Scenario 8 backgrounds a real sweep run and only reaps it on the success
# path (after the sentry announces itself and `wait "$SWEEP_PID"` returns).
# When the sentry never announces itself, the `bad` branch used to fall
# through with the sweep (and its timeout/claude children) still running —
# confirmed 2026-09-24: four such orphans survived this trap's own `rm -rf`,
# still holding a path into the now-deleted $TMP. pkill by that unique path
# before removing it, so no run of this file can outlive it regardless of
# which branch exits.
trap 'pkill -TERM -f "$TMP" 2>/dev/null; sleep 1; pkill -KILL -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
asserts=0; failed=0
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
# `!` is a reserved word, not a command, so the negation lives here.
absent() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$what"; else ok "$what"; fi; }

# --- the fakes ---------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/github/gamma/.git" "$TMP/logs"
cat > "$BIN/claude" <<'SH'
#!/bin/bash
# Every invocation's argv (minus the prompt) is logged: --model opus must be on each.
args=""; skip=""
for a in "$@"; do [ -n "$skip" ] && { skip=""; continue; }; [ "$a" = "-p" ] && { args="$args -p <prompt>"; skip=1; continue; }; args="$args $a"; done
echo "$args" >> "$FAKE_DIR/claude-args.log"
case "$(cat "$FAKE_DIR/claude-mode" 2>/dev/null)" in
  sleep) echo "round started; working..."; sleep 300 ;;
  park-beta)
    echo "Both repos worked. alpha#7 is green and merged; checks all pass."
    echo "CI-SWEEP-PARKED: beta — rotate the BETA_API_KEY secret in the repo settings"
    echo "CI-SWEEP-PARKED: zeta — not a repo this round had"
    echo "CI-SWEEP-COMPLETE: fixed" ;;
  *) echo "Dispatched one opus agent; opened a PR; all checks green, merged."; echo "CI-SWEEP-COMPLETE: fixed" ;;
esac
SH
cat > "$BIN/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/gh-calls.log"
repo=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = "--repo" ] && { j=$((i+1)); repo="${!j##*/}"; }; done
case "$1 $2" in
  "auth status"|"repo view") exit 0 ;;
  "pr list") [ -f "$FAKE_DIR/open-prs" ] && grep -E "^$repo	" "$FAKE_DIR/open-prs"; exit 0 ;;
  "pr checks") [ -f "$FAKE_DIR/checks-$repo-$3" ] && cat "$FAKE_DIR/checks-$repo-$3"; exit 0 ;;
  "pr view")
    case "$*" in
      *mergeCommit*) [ -f "$FAKE_DIR/merged-$repo-$3" ] && echo "sha$3$repo" ;;
      *headRefOid*)  echo "head$3" ;;
    esac; exit 0 ;;
  "pr merge")
    : > "$FAKE_DIR/merged-$repo-$3"
    grep -vE "^$repo	$3	" "$FAKE_DIR/open-prs" > "$FAKE_DIR/open-prs.t"; mv "$FAKE_DIR/open-prs.t" "$FAKE_DIR/open-prs"; exit 0 ;;
  "run list") printf 'completed\tsuccess\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
cat > "$TMP/land" <<'SH'
#!/bin/bash
NAME="$(basename "$PWD")"
case "$NAME" in
  gamma)  DEPLOY="" ;;
  *) echo "no route"; exit 1 ;;
esac
echo "$PWD land $*" >> "$FAKE_DIR/land-calls.log"
: > "$FAKE_DIR/merged-$NAME-$1"
grep -vE "^$NAME	$1	" "$FAKE_DIR/open-prs" > "$FAKE_DIR/open-prs.t"; mv "$FAKE_DIR/open-prs.t" "$FAKE_DIR/open-prs"
echo "LANDED — #$1"
SH
printf '#!/bin/bash\nexit 0\n' > "$BIN/security"
# The probe replays a sequence, one entry per call; the last entry repeats.
cat > "$TMP/probe.sh" <<'SH'
#!/bin/bash
n="$(cat "$FAKE_DIR/probe-n" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$FAKE_DIR/probe-n"
mode="$(sed -n "$((n + 1))p" "$FAKE_DIR/probe-seq")"; [ -z "$mode" ] && mode="$(tail -1 "$FAKE_DIR/probe-seq")"
G() { printf 'GREEN\t%s\tbuild\t%s|build|success|-\tok\n' "$1" "$1"; }
R() { printf 'RED\t%s\tbuild\t%s|build|failure|%s\tfailed\n' "$1" "$1" "$2"; }
case "$mode" in
  green)   G alpha; G beta; exit 0 ;;
  red-ab)  R alpha test; R beta lint; exit 1 ;;
  red-a2b) R alpha test2; R beta lint; exit 1 ;;
  red-b)   G alpha; R beta lint; exit 1 ;;
  red-a*)  R alpha "${mode#red-}"; G beta; exit 1 ;;
  red-g)   R gamma unit; G alpha; exit 1 ;;
  green-g) G gamma; G alpha; exit 0 ;;
  pending) printf 'PENDING\talpha\tplaywright\talpha|playwright|PENDING\trun #1 is in_progress\n'; exit 2 ;;
esac
SH
cat > "$TMP/audit.sh" <<'SH'
#!/bin/bash
: > "$FAKE_DIR/audit-called"
case "$(cat "$FAKE_DIR/audit-mode")" in
  fatal)         echo "  ✗ FATAL alpha#7 (a fix) — a command's failure is being swallowed"; echo "TEMP FIXES DETECTED"; exit 1 ;;
  fatal-outside) echo "  ✗ FATAL zeta#9 (someone else's) — a command's failure is being swallowed"; echo "TEMP FIXES DETECTED"; exit 1 ;;
  suspect)       echo "  ? SUSPECT alpha#7 (a fix) — a broad except was added with no comment"; exit 3 ;;
  *)             echo "  ✓ alpha#7 — no weakening pattern"; echo "No weakening patterns found."; exit 0 ;;
esac
SH
chmod +x "$BIN"/* "$TMP/probe.sh" "$TMP/audit.sh" "$TMP/land"
echo "trivial prompt" > "$TMP/prompt.md"
export FAKE_DIR="$TMP"
LOGS="$TMP/logs"; LEDGER="$LOGS/state/outcomes.tsv"; CARRY="$LOGS/state/carryover-next.md"

# setup <probe-seq...> — fresh fakes for one scenario
setup() {
  printf '%s\n' "$@" > "$TMP/probe-seq"; rm -f "$TMP/probe-n" "$TMP"/merged-* "$TMP"/checks-* "$TMP/audit-called"
  : > "$TMP/open-prs"; : > "$TMP/gh-calls.log"; : > "$TMP/claude-args.log"; : > "$TMP/land-calls.log"
  echo clean > "$TMP/audit-mode"; echo fixed > "$TMP/claude-mode"
}
sweep() { # sweep <run-id> [ENV=VAL ...]
  local id="$1"; shift
  env PATH="$BIN:$PATH" CI_SWEEP_LOG_DIR="$LOGS" CI_SWEEP_PROMPT="$TMP/prompt.md" \
      CI_SWEEP_PROBE_BIN="$TMP/probe.sh" CI_SWEEP_AUDIT_BIN="$TMP/audit.sh" \
      CI_SWEEP_NOTIFY_BIN="$ROOT/ci-sweep-notify.sh" CI_SWEEP_NOTIFY_DRY=1 \
      CI_SWEEP_STREAM_BIN="$ROOT/ci-sweep-stream.py" CI_SWEEP_CLAUDE_BIN="$BIN/claude" \
      CI_SWEEP_LAND_BIN="$TMP/land" CI_SWEEP_POLL_SECS=1 \
      CI_SWEEP_GITHUB_DIR="$TMP/github" CI_SWEEP_RUN_ID="$id" \
      "$@" "$SWEEP" >"$TMP/$id.out" 2>&1
}
last_verdict() { awk -F'\t' 'END{print $3}' "$LEDGER" 2>/dev/null; }
last_line() { tail -1 "$LOGS/$1.log"; }
rounds() { grep -c . "$TMP/claude-args.log"; }
every_claude_is_opus() { [ "$(rounds)" -gt 0 ] && ! grep -v -- '--model opus' "$TMP/claude-args.log" | grep -q .; }
no_retry_anywhere() { ! grep -qiE 'RETRY:|next attempt is|ESCALATING' "$LOGS/$1.log"; }

# =============================================================================
echo "=== 1. GREEN: no rounds, one banner, no issue, no retry ==="
setup green
sweep run-green; rc=$?
check "green run exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "the ledger records MAIN-GREEN" [ "$(last_verdict)" = "MAIN-GREEN" ]
check "the LAST line is the verdict plus the summary: $(last_line run-green)" grep -q '^CI-SWEEP-COMPLETE: MAIN-GREEN — green (2): alpha, beta' <<<"$(last_line run-green)"
check "a banner is sent even when green" grep -q '^\[notify:dry\] banner: "CI sweep: every main is green"' "$LOGS/run-green.log"
absent "a green run files no issue" grep -q 'notify:dry\] issue' "$LOGS/run-green.log"
check "no claude round was run" [ "$(rounds)" -eq 0 ]
check "no carryover is left" [ ! -f "$CARRY" ]
check "the log names tomorrow's 07:00 run, nothing more today" grep -q 'next run: 07:00 tomorrow (launchd com.seq.ci-sweep). Nothing else runs today.' "$LOGS/run-green.log"
check "nothing schedules a retry" no_retry_anywhere run-green

# =============================================================================
echo "=== 2. a PARKED repo does not end the run; the others are fixed and merged ==="
setup red-ab red-a2b red-b
echo park-beta > "$TMP/claude-mode"
printf 'alpha\t7\tfix/a\tFix alpha\nalpha\t9\tfix/a2\tClaims green\nbeta\t8\tfix/b\tHalf of beta\n' > "$TMP/open-prs"
echo pass > "$TMP/checks-alpha-7"; printf 'pass\nfail\n' > "$TMP/checks-alpha-9"; echo pass > "$TMP/checks-beta-8"
sweep run-park; rc=$?
check "ends MAIN-RED-BLOCKED once only parked repos are red (rc=$rc)" [ "$(last_verdict)" = "MAIN-RED-BLOCKED" ]
check "beta was parked with its reason" grep -q 'PARKED beta on her decision: rotate the BETA_API_KEY' "$LOGS/run-park.log"
check "a park for a repo the round did not have is ignored" grep -q 'ignoring CI-SWEEP-PARKED for zeta' "$LOGS/run-park.log"
check "the run CONTINUED: round 2 ran after the park" [ "$(rounds)" -eq 2 ]
check "round 2's brief lists beta as PARKED, not to be worked" grep -q 'PARKED — do NOT work' "$LOGS/run-park.d/carryover-2.md"
work_block() { awk '/^## Red lanes to work/{f=1; next} /^## /{f=0} f' "$LOGS/run-park.d/carryover-2.md"; }
check "round 2's work list holds alpha" grep -qE $'^RED\talpha' <(work_block)
absent "…and not beta's lanes" grep -qE $'^RED\tbeta' <(work_block)
check "alpha#7 (checks green, read by the sweep) merged with gh pr merge --merge --delete-branch" grep -q '^pr merge 7 --repo seq23/alpha --merge --delete-branch --match-head-commit head7' "$TMP/gh-calls.log"
check "…after the sweep read its checks itself" grep -q '^pr checks 7 --repo seq23/alpha' "$TMP/gh-calls.log"
absent "alpha#9 is NOT merged: the agent said green, gh pr checks says fail" grep -q '^pr merge 9' "$TMP/gh-calls.log"
check "…and the log says why" grep -q 'alpha#9: checks are red (read with gh pr checks)' "$LOGS/run-park.log"
absent "beta#8 is NOT merged: its repo is parked" grep -q '^pr merge 8' "$TMP/gh-calls.log"
check "main was watched after the merge" grep -q 'alpha#7 merged as sha7alpha; main after it: success' "$LOGS/run-park.log"
check "summary: fixed alpha with its PR number" grep -q 'fixed this run: alpha (#7)' <<<"$(last_line run-park)"
check "summary: parked beta with the decision needed" grep -q 'parked on her decision: beta — rotate the BETA_API_KEY' <<<"$(last_line run-park)"
check "an issue is filed on beta naming the decision" grep -q 'notify:dry\] issue -> seq23/beta' "$LOGS/run-park.log"
check "…titled as parked" grep -q 'title: \[ci-sweep\] beta is parked on your decision' "$LOGS/run-park.log"
absent "no issue is filed on alpha (it is fixed)" grep -q 'notify:dry\] issue -> seq23/alpha' "$LOGS/run-park.log"
check "every claude -p ran with --model opus" every_claude_is_opus
check "round 2 resumed round 1's session" grep -q -- '--resume' <(sed -n 2p "$TMP/claude-args.log")
check "tomorrow's carryover names the parked repo" grep -q 'beta: rotate the BETA_API_KEY' "$CARRY"
check "nothing schedules a retry" no_retry_anywhere run-park
absent "nothing was ever closed" grep -q '^pr close' "$TMP/gh-calls.log"

# =============================================================================
echo "=== 3. STUCK only after TWO CONSECUTIVE rounds without progress ==="
setup red-a1
sweep run-stuck; rc=$?
check "an unchanging red lane is STUCK (rc=$rc)" [ "$(last_verdict)" = "MAIN-RED-STUCK" ]
check "…after exactly 2 rounds" [ "$(rounds)" -eq 2 ]
check "an issue is filed on the stuck repo" grep -q 'title: \[ci-sweep\] alpha is stuck red' "$LOGS/run-stuck.log"
check "summary names alpha as stuck" grep -q 'stuck: alpha — build RED' <<<"$(last_line run-stuck)"
setup red-a1 red-a2 red-a2 red-a3 red-a3 red-a3
sweep run-stuck2
check "progress in between resets the count: 5 rounds (p, -, p, -, -)" [ "$(rounds)" -eq 5 ]
check "…then STUCK" [ "$(last_verdict)" = "MAIN-RED-STUCK" ]
check "the progress ledger reads progress,none,progress,none,none" [ "$(cut -f2 "$LOGS/run-stuck2.d/progress.tsv" | tr '\n' ,)" = "progress,none,progress,none,none," ]

# =============================================================================
echo "=== 4. rounds are NOT capped at 2 while each makes progress ==="
setup red-a1 red-a2 red-a3 red-a4 green
sweep run-progress; rc=$?
check "a new failure signature each round keeps it going to green (rc=$rc)" [ "$(last_verdict)" = "MAIN-GREEN" ]
check "…in 4 rounds" [ "$(rounds)" -eq 4 ]
check "summary calls alpha fixed" grep -q 'fixed this run: alpha' <<<"$(last_line run-progress)"

# =============================================================================
echo "=== 5. land is the merge route where land knows the repo ==="
setup red-g green-g
printf 'gamma\t5\tfix/g\tFix gamma\n' > "$TMP/open-prs"; echo pass > "$TMP/checks-gamma-5"
sweep run-land; rc=$?
check "land 5 ran inside gamma's checkout" grep -q "$TMP/github/gamma land 5" "$TMP/land-calls.log"
absent "…and gh pr merge was not used for it" grep -q '^pr merge 5' "$TMP/gh-calls.log"
check "green after landing (rc=$rc)" [ "$(last_verdict)" = "MAIN-GREEN" ]
check "summary: fixed gamma (#5)" grep -q 'fixed this run: gamma (#5)' <<<"$(last_line run-land)"

# =============================================================================
echo "=== 6. SUSPECT and failing checks are never merged ==="
setup red-a1 green
echo suspect > "$TMP/audit-mode"
printf 'alpha\t7\tfix/a\tFix alpha\n' > "$TMP/open-prs"; echo pass > "$TMP/checks-alpha-7"
sweep run-suspect
absent "a PR the audit named SUSPECT is not merged" grep -q '^pr merge 7' "$TMP/gh-calls.log"
check "…and the log says so" grep -q 'alpha#7: the audit named it SUSPECT' "$LOGS/run-suspect.log"

# =============================================================================
echo "=== 7. TEMPFIX rejects the PR — never merges, never closes — and ends the run ==="
setup red-a1
echo fatal > "$TMP/audit-mode"
printf 'alpha\t7\tfix/a\tFix alpha\n' > "$TMP/open-prs"; echo pass > "$TMP/checks-alpha-7"
sweep run-tempfix
check "verdict is MAIN-RED-TEMPFIX" [ "$(last_verdict)" = "MAIN-RED-TEMPFIX" ]
check "a REJECTED note went on the PR" grep -q '^pr comment 7 --repo seq23/alpha' "$TMP/gh-calls.log"
absent "the sweep never merged or closed anything" grep -qE '^pr (merge|close)' "$TMP/gh-calls.log"
check "tomorrow is told what was rejected" grep -q 'alpha#7' "$CARRY"
check "a run-level issue is filed on alpha" grep -q 'notify:dry\] issue -> seq23/alpha' "$LOGS/run-tempfix.log"
check "nothing schedules a retry" no_retry_anywhere run-tempfix
setup red-a1
echo fatal-outside > "$TMP/audit-mode"
sweep run-tempfix-outside
check "a FATAL outside the run's repos is not the sweep's to reject" grep -q 'not rejecting zeta#9: outside this run' "$LOGS/run-tempfix-outside.log"
absent "…so no note went on that PR" grep -q '^pr comment 9' "$TMP/gh-calls.log"

# =============================================================================
echo "=== 8. SLEEP IS NOT A HANG: a heartbeat gap is INTERRUPTED and parks its PR ==="
setup red-a1
echo sleep > "$TMP/claude-mode"
printf 'alpha\t11\twork/half-done\tHalf a fix\n' > "$TMP/open-prs"; echo pass > "$TMP/checks-alpha-11"
sweep run-sleep CI_SWEEP_TICK_SECS=1 CI_SWEEP_SLEEP_GAP_SECS=3 CI_SWEEP_HARD_KILL_MIN=45 &
SWEEP_PID=$!
for _ in $(seq 1 40); do [ -s "$LOGS/run-sleep.d/sentry-pid" ] && break; sleep 0.5; done
SENTRY="$(cat "$LOGS/run-sleep.d/sentry-pid" 2>/dev/null || echo "")"
if [ -z "$SENTRY" ]; then
  bad "the sentry never announced itself; cannot simulate a sleep"
else
  sleep 2
  kill -STOP "$SENTRY"; sleep 6; kill -CONT "$SENTRY"   # the Mac "sleeps" 6s > 3s gap
  wait "$SWEEP_PID"; rc=$?
  check "the run ends as MAIN-RED-INTERRUPTED (rc=$rc)" [ "$rc" -eq 22 ]
  check "the ledger says INTERRUPTED, not HUNG" [ "$(last_verdict)" = "MAIN-RED-INTERRUPTED" ]
  check "the half round was NOT audited as landed work" [ ! -f "$TMP/audit-called" ]
  check "the PR the cut-off round opened is PARKED" grep -q 'PARKED PR alpha#11' "$LOGS/run-sleep.log"
  absent "…and never merged or closed" grep -qE '^pr (merge|close)' "$TMP/gh-calls.log"
  check "the lock was released" [ ! -d "$LOGS/.lock" ]
  check "a banner still went out" grep -q 'notify:dry\] banner: "CI sweep: interrupted' "$LOGS/run-sleep.log"
  check "nothing schedules a retry" no_retry_anywhere run-sleep
fi

# =============================================================================
echo "=== 9. a stall with NO gap is HUNG, on awake time ==="
setup red-a1
echo sleep > "$TMP/claude-mode"
sweep run-hang CI_SWEEP_TICK_SECS=1 CI_SWEEP_HARD_KILL_MIN=1; rc=$?
check "the run ends as MAIN-RED-HUNG (rc=$rc)" [ "$rc" -eq 21 ]
check "no sleep gap was recorded" [ ! -f "$LOGS/run-hang.d/interrupted" ]
check "the ceiling was counted in ticks" grep -q 'ticks of 1s awake' "$LOGS/run-hang.d/hung"

# =============================================================================
echo "=== 10. a precondition stop is MAIN-UNKNOWN, with a banner and an issue ==="
setup green
mkdir -p "$TMP/nogh"; printf '#!/bin/bash\n[ "$1 $2" = "auth status" ] && exit 1; exit 0\n' > "$TMP/nogh/gh"; chmod +x "$TMP/nogh/gh"
sweep run-noauth PATH="$TMP/nogh:$BIN:$PATH"
check "gh unauthenticated is MAIN-UNKNOWN" [ "$(last_verdict)" = "MAIN-UNKNOWN" ]
check "…and it is filed, not silent" grep -q 'notify:dry\] issue -> seq23/west-peek-os' "$LOGS/run-noauth.log"

# =============================================================================
echo "=== 11. a run still in flight is PENDING, not red: banner, no issue ==="
setup pending
sweep run-pending CI_SWEEP_VERIFY_CAP_MIN=0; rc=$?
check "a pending run exits 2 (rc=$rc)" [ "$rc" -eq 2 ]
check "the verdict is MAIN-PENDING" [ "$(last_verdict)" = "MAIN-PENDING" ]
check "a banner went out" grep -q 'notify:dry\] banner' "$LOGS/run-pending.log"
absent "nothing is filed for a run in flight" grep -q 'notify:dry\] issue' "$LOGS/run-pending.log"

# =============================================================================
echo "=== 12. the dry run prints the plan and dispatches nothing ==="
setup red-ab
out="$(env PATH="$BIN:$PATH" CI_SWEEP_DRY_RUN=1 CI_SWEEP_LOG_DIR="$LOGS" CI_SWEEP_PROBE_BIN="$TMP/probe.sh" \
        CI_SWEEP_LAND_BIN="$TMP/land" CI_SWEEP_GITHUB_DIR="$TMP/github" "$SWEEP" 2>&1)"; rc=$?
check "dry run exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "it names the schedule and the model" grep -q '07:00 CT.*retry at 08:00' <<<"$out"
check "…the model" grep -q 'model: every claude -p runs --model opus' <<<"$out"
check "…and the repos round 1 would dispatch to, with their merge route" grep -q 'beta — build — merge route: gh' <<<"$out"
check "no claude was invoked" [ "$(rounds)" -eq 0 ]
check "no lock was taken" [ ! -d "$LOGS/.lock" ]

# =============================================================================
# 13-14: the 08:00 retry note, read from the SAME ledger the standalone
# ci-sweep-retry-if-red.sh reads (state/outcomes.tsv). The ledger accumulates
# across every scenario above in this one test run, all dated "today" — that's
# fine for last_verdict() (it only reads the tail), but this check counts
# TODAY's rows, so it needs a clean ledger to mean anything.
echo "=== 13. a non-green run that is the day's only run so far names the 08:00 retry ==="
setup green
rm -f "$LEDGER"
sweep run-retry1 PATH="$TMP/nogh:$BIN:$PATH"
check "still MAIN-UNKNOWN (gh unauthenticated)" [ "$(last_verdict)" = "MAIN-UNKNOWN" ]
check "the log names today's 08:00 retry, once" \
  grep -q 'next run: 08:00 today, once (launchd com.seq.ci-sweep-retry -> ci-sweep-retry-if-red.sh) — this run did not end green.' \
  "$LOGS/run-retry1.log"

echo "=== 14. a SECOND non-green run today (the retry already ran) names tomorrow, not another retry ==="
setup green
sweep run-retry2 PATH="$TMP/nogh:$BIN:$PATH"
check "still MAIN-UNKNOWN" [ "$(last_verdict)" = "MAIN-UNKNOWN" ]
check "the log names tomorrow's 07:00 run, not another retry" \
  grep -q "next run: 07:00 tomorrow (launchd com.seq.ci-sweep). Today's one retry already ran and was not green; nothing more today." \
  "$LOGS/run-retry2.log"
rm -f "$LEDGER"

# =============================================================================
echo "=== negative proof: with the checks gate neutralised, the failing-check PR MUST get merged ==="
sed 's/^pr_checks_state() {$/pr_checks_state() { echo green; return; }\npr_checks_state_disabled() {/' "$SWEEP" > "$TMP/crippled.sh"
chmod +x "$TMP/crippled.sh"
if ! grep -q 'pr_checks_state_disabled' "$TMP/crippled.sh"; then
  bad "SETUP BROKEN — could not neutralise the checks gate, so the negative proof is void"
else
  setup red-a1 green
  printf 'alpha\t9\tfix/a2\tClaims green\n' > "$TMP/open-prs"; printf 'pass\nfail\n' > "$TMP/checks-alpha-9"
  SWEEP_SAVE="$SWEEP"; SWEEP="$TMP/crippled.sh"; sweep run-crippled; SWEEP="$SWEEP_SAVE"
  if grep -q '^pr merge 9' "$TMP/gh-calls.log"; then
    ok "PROVEN   without the gate the failing PR is merged, so section 2's 'not merged' reads the gate"
  else
    bad "NO TEETH — the failing PR was not merged even with the gate removed"
  fi
fi

# --- Rule 0 ------------------------------------------------------------------
if [ "$asserts" -eq 0 ]; then
  echo "RULE 0 [ASSERTED_NOTHING] this suite executed zero assertions."; exit 2
fi
echo "=== $asserts assertion(s) executed ==="
if [ "$failed" -gt 0 ]; then
  echo "SWEEP DAILY TESTS FAILED: $failed of $asserts."
  for f in "$TMP"/*.out; do [ -s "$f" ] && { echo "--- $(basename "$f")"; tail -20 "$f"; }; done
  exit 1
fi
echo "ci-sweep.sh parks per repo, iterates while it makes progress, merges only what it read green, pins opus, reports every morning, and never retries or closes a PR."
exit 0
