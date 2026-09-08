#!/bin/bash
# CI sweep — runs twice daily under launchd, independent of any chat session.
#
# WHY THIS EXISTS
# Red GitHub Actions were being "fixed" by re-running them, so the same lanes
# failed again the next day and Sequoia got paged daily. This runs Claude Code
# headless against every repo, dispatches one agent per broken repo, and holds
# each to a root-cause fix with a guard and a negative proof.
#
# RULE 0: this script may not exit 0 having done nothing. Either it swept and
# reported, or it exits non-zero with a named reason. A silent no-op here would
# be indistinguishable from a healthy day, which is the whole defect class it
# was built to catch.
#
# WHY IT NOW ITERATES (added 2026-09-08)
# On 2026-09-08 `local-guides-citation-velocity` had `Velocity Content Release`
# fail at 02:00 and 08:38. The 10:07 sweep ran. Its agents landed PRs #88, #89
# and #90 at 14:47/15:10/15:21. THE LANE FAILED AGAIN AT 15:21 AND STAYED RED.
#
# Nothing in the chain noticed, because nothing in the chain ever asked GitHub
# what state main was in. The only evidence was CI-SWEEP-COMPLETE: fixed — a
# sentinel the agent writes about its own work. The sweep dispatched, reported a
# success, and exited while main was red.
#
# Two changes follow from that, and they are the point of this file now:
#
#   1. AN AGENT REPORTING "FIXED" IS A CLAIM; A GREEN RUN ON MAIN IS EVIDENCE.
#      ci-sweep-probe.sh asks GitHub directly, after every round. A merged PR is
#      not evidence. The probe watches runs to a TERMINAL state and matches both
#      success and failure — a loop that waits only for success hangs silently
#      through a crash, and silence looks identical to "still running".
#
#   2. THE SWEEP IS NOT FINISHED WHILE MAIN IS RED. It re-dispatches, telling the
#      next round what the last one tried and why it did not work, so round two is
#      not a repeat of round one.
#
# AND THE FINAL LINE NOW CARRIES THE STATE OF MAIN, NOT JUST "I REACHED MY END".
# The old sentinel proved the sweep terminated. It could not distinguish a green
# fleet from a red one, which is exactly how 09-08 read as a good day.
#
# HONEST BOUNDS, NOT "FOREVER"
# "Do not stop until it is green" cannot mean an unattended job spinning all night
# on her Claude Max plan. Every stop this script can reach is NAMED, and the
# numbers are derived below at each knob rather than picked.

set -uo pipefail

# --- what the sweep is allowed to spend --------------------------------------
# TWO NUMBERS, TWO PURPOSES. She set the outer one herself: "if the sweep lasts
# more than 2hrs that is a problem". So anything past 120 minutes is a FAULT by
# definition, whether the script has noticed or not.
#
#   HARD_KILL_MIN = 120  the kernel-enforced backstop. Not a budget — a fault
#                        detector. Nothing normal ever reaches it; a run that does
#                        is broken, and is killed, unlocked, named and escalated.
#   DEADLINE_MIN  =  95  the convergence budget the sweep manages itself, with
#                        25 minutes of headroom under the backstop so an ordinary
#                        red night finishes and reports ON ITS OWN TERMS rather
#                        than being cut off mid-sentence at the wall.
#
# The first version of this file had one number, 270, derived from what converging
# might like to have. That was the wrong direction: FINISHING BEATS CONVERGING,
# and a sweep that stops at 95 minutes saying "still red, here is what and why"
# is worth more than one that grinds for hours. Everything below is derived
# downward from 95, never upward from what more rounds would like.
HARD_KILL_MIN="${CI_SWEEP_HARD_KILL_MIN:-120}"
DEADLINE_MIN="${CI_SWEEP_DEADLINE_MIN:-95}"

# MAX_ROUNDS = 2, and that is what 95 minutes buys. Round 1 discovers and
# dispatches; round 2 is the one 2026-09-08 was missing — the same agents, told
# what they landed and that the lane failed anyway. A third round does not fit
# without cutting rounds 1 and 2 below the length of a real fix, which would trade
# a round that can work for a round that cannot.
MAX_ROUNDS="${CI_SWEEP_MAX_ROUNDS:-2}"

# Per-round caps on the claude invocation, each additionally clamped to what is
# left. Round 1 is larger because it does the discovery — enumerating the fleet,
# reading breakers, dispatching. Round 2 starts from a named list of red lanes.
ROUND1_CAP_MIN="${CI_SWEEP_ROUND1_CAP_MIN:-45}"
ROUNDN_CAP_MIN="${CI_SWEEP_ROUNDN_CAP_MIN:-25}"

# How long to wait, after a round, for in-flight runs to reach a terminal state.
VERIFY_CAP_MIN="${CI_SWEEP_VERIFY_CAP_MIN:-8}"

# Budget: probe 1.5 + round1 45 + audit 0.5 + verify 8 + round2 25 + audit 0.5
#       + final probe 8  =  88.5 ≤ 95 ≤ 120. A full-fleet probe measured 65s.
# THE SWEEP ALSO EXITS THE MOMENT IT HITS SOMETHING ONLY SHE CAN RESOLVE, rather
# than spending what is left re-proving it — see MAIN-RED-STUCK and
# MAIN-RED-BLOCKED below. Grinding through the remaining rounds on a known block
# is the six-hour behaviour in miniature.

# A lane whose failure SIGNATURE (repo|workflow|conclusion|failing jobs) is
# unchanged after this many fixing rounds is escalated instead of retried. Two
# rounds that moved nothing is evidence about the problem, not about effort.
STUCK_ROUNDS="${CI_SWEEP_STUCK_ROUNDS:-2}"

# Overridable so the plumbing (claude headless, logging, Rule 0, the lock, the
# convergence loop) can be exercised with a trivial prompt without dispatching a
# real sweep. A scheduled job whose only test is "it ran in production" is a job
# nobody can verify.
PROMPT_FILE="${CI_SWEEP_PROMPT:-$HOME/bin/ci-sweep-prompt.md}"
PROBE="${CI_SWEEP_PROBE_BIN:-$HOME/bin/ci-sweep-probe.sh}"
AUDIT="${CI_SWEEP_AUDIT_BIN:-$HOME/bin/ci-sweep-audit.sh}"
# Overridable for the same reason the prompt is: the lock, Rule 0, the round loop
# and the verdict must all be exercisable without touching the live lock or the
# real log directory. A test that has to share state with the production run is a
# test nobody dares to run.
LOG_DIR="${CI_SWEEP_LOG_DIR:-$HOME/Library/Logs/ci-sweep}"
LOCK="$LOG_DIR/.lock"
STAMP="$(date +%Y-%m-%dT%H:%M:%S)"
STARTED_AT="$(date +%s)"
DEADLINE_AT=$((STARTED_AT + DEADLINE_MIN * 60))
KILL_AT=$((STARTED_AT + HARD_KILL_MIN * 60))
# Seconds AND pid, not just HHMM. With minute resolution two runs in the same
# minute shared one log and appended to it — so the second run inherited the
# first run's CI-SWEEP-COMPLETE sentinel and passed Rule 0 without ever emitting
# one. A guard reading a previous run's evidence is worse than no guard. Found
# 2026-09-02 by the negative proof for exactly that case.
# Inherited from the supervisor when one is present, so the supervised body and the
# supervisor that may have to kill it write to the SAME log and work directory. A
# watchdog that reports a hang into a file nobody correlates with the run is a
# watchdog nobody can read.
RUN_ID="${CI_SWEEP_RUN_ID:-$(date +%Y-%m-%d-%H%M%S)-$$}"
RUN_LOG="$LOG_DIR/$RUN_ID.log"
WORK="$LOG_DIR/$RUN_ID.d"
NOTIFY="${CI_SWEEP_NOTIFY_BIN:-$HOME/bin/ci-sweep-notify.sh}"

mkdir -p "$LOG_DIR" "$WORK"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }

# Minutes left in the budget, floored at 0.
remaining_min() {
  local left=$(( (DEADLINE_AT - $(date +%s)) / 60 ))
  [ "$left" -lt 0 ] && left=0
  echo "$left"
}
# Clamp a requested minute budget to what is actually left.
capped() {
  local want="$1" left; left="$(remaining_min)"
  [ "$want" -gt "$left" ] && want="$left"
  echo "$want"
}

# The final line, written by BASH and not by the model, because the thing it
# reports on is the model's own claim about its work. Exactly one of these is the
# last line of every completed run.
VERDICT=""
VERDICT_DETAIL=""
finish() {
  VERDICT="$1"; VERDICT_DETAIL="$2"
  ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
  echo "CI-SWEEP-COMPLETE: $VERDICT — $VERDICT_DETAIL" | tee -a "$RUN_LOG"
  # A LOG FILE IS NOT A NOTIFICATION. ~/Library/Logs/ci-sweep/latest.log is not a
  # place she goes, so before this every red night was indistinguishable from a
  # green one unless she went looking — which is the same defect as a sweep that
  # reports success over a red lane, one layer out.
  #
  # MAIN-GREEN DELIBERATELY DOES NOT NOTIFY. A notification that arrives every day
  # is one she stops reading, and then the red ones do not land either.
  if [ "$VERDICT" != "MAIN-GREEN" ] && [ -x "$NOTIFY" ]; then
    "$NOTIFY" "$VERDICT" "$VERDICT_DETAIL" "$RUN_LOG" >>"$RUN_LOG" 2>&1 || \
      echo "[notify] escalation failed; see above" >> "$RUN_LOG"
  fi
  case "$VERDICT" in
    # Only one verdict means the job is done. Everything else exits non-zero so
    # that a red fleet can never be mistaken for a quiet one by anything reading
    # this script's status rather than its prose.
    MAIN-GREEN) exit 0 ;;
    *) exit 20 ;;
  esac
}

# =============================================================================
# SUPERVISOR — the ceiling is enforced from OUTSIDE the work, by the kernel
# =============================================================================
# THIS IS THE ACTUAL BUG FROM 2026-09-08, and the first fix did not fix it.
#
# That fix computed a deadline and checked it between rounds. A deadline checked
# by the process doing the work only bounds a process that is still working. THE
# 10:07 RUN REACHED SIX HOURS PRECISELY BECAUSE IT NEVER GOT BACK TO ITS OWN
# CHECK — it sat inside a headless `claude` that never returned, so every internal
# clamp in the world would have been skipped, and it held the lock the whole time.
#
# So the ceiling now lives in a supervisor that is NOT doing the work:
#   · the body runs in ITS OWN PROCESS GROUP (python's setsid, since macOS ships
#     no setsid binary), so the whole tree can be signalled at once. `timeout`
#     alone signals only its direct child, which would leave the wedged `claude`
#     running as an orphan — killing the bookkeeping and leaving the actual
#     resource hog behind;
#   · a watchdog that outlives the body kills that GROUP at the ceiling, TERM
#     first and KILL 20s later;
#   · the supervisor owns the lock, so a body that is killed outright — no traps,
#     no cleanup — still cannot leave it held;
#   · and a hang is a NAMED, ESCALATED outcome (MAIN-RED-HUNG), not silence.
#
# The supervisor re-executes this same file with CI_SWEEP_SUPERVISED=1.
if [ -z "${CI_SWEEP_SUPERVISED:-}" ]; then

  # --- single-flight -----------------------------------------------------------
  # The 10:07 run can still be working when 18:07 fires if a repo is slow. Two
  # concurrent sweeps would put two agents in the same repo, which is the exact
  # collision that makes branches rebuild repeatedly.
  #
  # RECLAIM IS NOW HEARTBEAT-BASED, not liveness-based. "Is the pid alive?" was
  # the wrong question: the 10:07 process was alive for six hours and wedged for
  # most of them, and a wedged holder is indistinguishable from a working one by
  # liveness alone. The supervisor ticks $LOCK/heartbeat every 20s while it is
  # genuinely supervising, so a stale heartbeat means the holder is dead, wedged,
  # or predates this mechanism — all three of which are reclaimable, and none of
  # which anyone should wait behind.
  LOCK_STALE_AFTER="${CI_SWEEP_LOCK_STALE_AFTER:-180}"   # 9x the 20s tick
  LOCK_MAX_AGE=$(( HARD_KILL_MIN * 60 + 300 ))
  if ! mkdir "$LOCK" 2>/dev/null; then
    holder="$(cat "$LOCK/pid" 2>/dev/null || echo "")"
    beat="$(cat "$LOCK/heartbeat" 2>/dev/null || echo 0)"
    started="$(cat "$LOCK/started" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    reclaim=""
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
      reclaim="its process is gone"
    elif [ "$beat" -eq 0 ]; then
      reclaim="its lock has no heartbeat, so it predates the supervisor and cannot be shown to be alive rather than merely running"
    elif [ $(( now - beat )) -gt "$LOCK_STALE_AFTER" ]; then
      reclaim="its heartbeat is $(( now - beat ))s stale (>${LOCK_STALE_AFTER}s) — the holder is wedged, not working"
    elif [ "$started" -gt 0 ] && [ $(( now - started )) -gt "$LOCK_MAX_AGE" ]; then
      reclaim="it has run $(( now - started ))s, past the ${LOCK_MAX_AGE}s ceiling"
    fi
    if [ -z "$reclaim" ]; then
      say "NAMED STOP [SWEEP_ALREADY_RUNNING] pid $holder, heartbeat $(( now - beat ))s ago — a healthy sweep is running; not starting a second."
      exit 0
    fi
    say "reclaiming the lock from pid ${holder:-none}: $reclaim."
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      kill -TERM "-$holder" 2>/dev/null || kill -TERM "$holder" 2>/dev/null
      sleep 5
      kill -KILL "-$holder" 2>/dev/null || kill -KILL "$holder" 2>/dev/null
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { say "FAILED to take lock"; exit 3; }
  fi
  echo $$ > "$LOCK/pid"
  echo "$STARTED_AT" > "$LOCK/started"
  date +%s > "$LOCK/heartbeat"
  # Only ever release a lock this process still owns — see the ordering note in the
  # reclaim path: a killed holder's cleanup can land after the new holder took it.
  release_lock() { [ "$(cat "$LOCK/pid" 2>/dev/null || echo)" = "$$" ] && rm -rf "$LOCK"; }

  say "=== CI sweep supervisor: convergence budget ${DEADLINE_MIN} min, hard kill at ${HARD_KILL_MIN} min ($(date -r "$KILL_AT" +%H:%M)) ==="

  export CI_SWEEP_SUPERVISED=1 CI_SWEEP_RUN_ID="$RUN_ID"

  # setsid via python: the body becomes a process-group leader, so PGID == its pid
  # and one signal reaches it AND every agent, gh and claude beneath it.
  /usr/bin/python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      /bin/bash "$0" "$@" &
  BODY=$!

  # The watchdog OUTLIVES the body on purpose. It is not a timer the body consults;
  # it is a separate process whose only job is to end the group at the ceiling.
  # >/dev/null 2>&1 MATTERS: without it these subshells inherit the supervisor's
  # stdout and hold that pipe or log file open for their whole sleep. A piped run
  # then never sees EOF and appears to hang even after the sweep has finished and
  # exited — which is how this was found. Worse in production: if the supervisor
  # itself is killed, an unredirected watchdog keeps launchd's log handle open for
  # up to two hours. They need no output; they are timers.
  ( sleep "$(( HARD_KILL_MIN * 60 ))"
    kill -TERM "-$BODY" 2>/dev/null
    sleep 20
    kill -KILL "-$BODY" 2>/dev/null ) >/dev/null 2>&1 & WATCHDOG=$!

  # The heartbeat proves the SUPERVISOR is alive, which is what the reclaim above
  # tests. It ticks from here rather than from the body so that a wedged body is
  # still killable but a busy one is never mistaken for dead.
  ( while :; do date +%s > "$LOCK/heartbeat" 2>/dev/null || exit 0; sleep 20; done ) >/dev/null 2>&1 & TICKER=$!

  wait "$BODY"; RC=$?
  # `disown` first so bash does not print "Terminated: 15" job notices into the
  # launchd log for timers whose death is entirely expected.
  disown "$WATCHDOG" "$TICKER" 2>/dev/null
  kill "$WATCHDOG" "$TICKER" 2>/dev/null
  ELAPSED=$(( $(date +%s) - STARTED_AT ))

  if [ "$ELAPSED" -ge $(( HARD_KILL_MIN * 60 )) ] || [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ]; then
    # Belt and braces: the watchdog signalled the group, but anything that somehow
    # survived is reaped here before the lock is released, so the next sweep never
    # inherits a live orphan holding files or agents open.
    kill -KILL "-$BODY" 2>/dev/null
    say "=== HUNG: the sweep did not finish within ${HARD_KILL_MIN} minutes and was killed from outside (rc=$RC, ${ELAPSED}s) ==="
    ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
    DET="the sweep was still running after ${HARD_KILL_MIN} minutes and was killed by its watchdog. It did not reach a verdict, so main's state is UNVERIFIED — treat it as red. The last thing it logged is at the bottom of $RUN_LOG."
    echo "CI-SWEEP-COMPLETE: MAIN-RED-HUNG — $DET" | tee -a "$RUN_LOG"
    [ -x "$NOTIFY" ] && "$NOTIFY" "MAIN-RED-HUNG" "$DET" "$RUN_LOG" >>"$RUN_LOG" 2>&1
    release_lock
    exit 21
  fi

  # A precondition stop (no claude, no gh, not authenticated, keychain locked) exits
  # non-zero WITHOUT reaching finish(), so it would otherwise escalate to nobody.
  # These are the cases where the sweep could not run at all, which is exactly when
  # she needs telling — CI is unwatched until she acts.
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 20 ]; then
    DET="the sweep could not run at all (exit $RC) — see the NAMED STOP line in $RUN_LOG. Until this is cleared, nothing is watching CI."
    echo "CI-SWEEP-COMPLETE: MAIN-UNKNOWN — $DET" | tee -a "$RUN_LOG"
    [ -x "$NOTIFY" ] && "$NOTIFY" "MAIN-UNKNOWN" "$DET" "$RUN_LOG" >>"$RUN_LOG" 2>&1
  fi

  release_lock
  exit "$RC"
fi
# =============================================================================
# BODY — everything below runs supervised, inside the process group above
# =============================================================================

# --- preconditions, each a named stop rather than a crash --------------------
# These exit NON-ZERO on purpose: they mean the sweep could not run at all, which
# is a different thing from a sweep that ran and found red.
CLAUDE="$(command -v claude || echo /opt/homebrew/bin/claude)"
[ -x "$CLAUDE" ] || { say "NAMED STOP [NO_CLAUDE_CLI] not executable: $CLAUDE"; exit 4; }
[ -f "$PROMPT_FILE" ] || { say "NAMED STOP [NO_PROMPT_FILE] missing: $PROMPT_FILE"; exit 5; }

if ! command -v gh >/dev/null 2>&1; then
  say "NAMED STOP [NO_GH_CLI] the sweep cannot read GitHub without gh."; exit 6
fi
if ! gh auth status >/dev/null 2>&1; then
  say "NAMED STOP [GH_NOT_AUTHENTICATED] run: gh auth login"; exit 7
fi

# Claude's own credentials live in the login keychain. A launchd agent normally
# reaches it while the user is logged in, but NOT when the Mac is sitting at the
# login window with the keychain locked. Without this check that case surfaces as
# a generic claude failure with no sentinel — technically caught by Rule 0 below,
# but the log would not say why. Name it here instead.
if ! security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  say "NAMED STOP [CLAUDE_NOT_AUTHENTICATED] cannot read Claude credentials from the login keychain."
  say "  Either the Mac is at the login window with the keychain locked, or the session was signed out."
  say "  Fix: log in to macOS, then run 'claude' once and confirm it starts."
  exit 10
fi

# The convergence criterion has to exist or the loop is decorative. Without the
# probe this script would be back to trusting the agent's own sentinel, which is
# precisely the 09-08 failure.
[ -x "$PROBE" ] || { say "NAMED STOP [NO_PROBE] $PROBE missing — nothing could verify main is green."; exit 13; }
# The guard on the guard is not optional, and convergence pressure makes it MORE
# load-bearing: an agent told "keep going until it is green" is more tempted to
# switch a test off than one asked to look once.
[ -x "$AUDIT" ] || { say "NAMED STOP [NO_AUDITOR] $AUDIT is missing, so nothing would verify that the fixes were real."; exit 12; }

cd "$HOME/GitHub" || { say "NAMED STOP [NO_GITHUB_DIR]"; exit 8; }

say "=== CI sweep starting ($STAMP) ==="
say "claude: $CLAUDE"
say "budget: ${MAX_ROUNDS} round(s) max, ${DEADLINE_MIN} min deadline (hard stop $(date -r "$DEADLINE_AT" +%H:%M))"
say "work dir: $WORK"

# --- probe main, waiting for in-flight runs to reach a TERMINAL state ---------
# Writes lanes to $1. Returns 0 green, 1 red/silent, 2 still pending at the cap,
# 3 named stop. It polls on PENDING and breaks on EITHER outcome: a loop watching
# only for the success marker hangs silently through a crash, because silence and
# "still running" are the same observation.
probe_main() {
  local out="$1" cap_min; cap_min="$(capped "$VERIFY_CAP_MIN")"
  local until_ts=$(( $(date +%s) + cap_min * 60 )) rc=0
  while :; do
    "$PROBE" > "$out" 2>>"$RUN_LOG"; rc=$?
    [ "$rc" -eq 3 ] && return 3
    [ "$rc" -ne 2 ] && return "$rc"          # 0 green or 1 red — both terminal
    if [ "$(date +%s)" -ge "$until_ts" ]; then
      say "  runs still in flight after ${cap_min} min; treating unsettled lanes as NOT green."
      sed -i '' 's/^PENDING\t/RED\t/' "$out" 2>/dev/null || true
      return 1
    fi
    say "  runs in flight; re-checking in 60s (until $(date -r "$until_ts" +%H:%M))"
    sleep 60
  done
}

# --- the convergence loop ----------------------------------------------------
round=0
prev_sigs=""          # red-lane signatures seen on the PREVIOUS probe
STUCK_FILE="$WORK/stuck.tsv"; : > "$STUCK_FILE"

while :; do
  say "--- probing main (after round $round) ---"
  PROBE_OUT="$WORK/probe-$round.tsv"
  probe_main "$PROBE_OUT"; PRC=$?

  if [ "$PRC" -eq 3 ]; then
    finish "MAIN-UNKNOWN" "the probe could not read the fleet (named stop above); main's state is UNVERIFIED — treat as red."
  fi

  RED_LINES="$(grep -E '^(RED|SILENT)	' "$PROBE_OUT" || true)"
  if [ -z "$RED_LINES" ]; then
    say "every lane on main is green."
    if [ "$round" -eq 0 ]; then
      finish "MAIN-GREEN" "all $(grep -cE '^GREEN	' "$PROBE_OUT") lane(s) green on main; nothing was red, no rounds needed."
    fi
    finish "MAIN-GREEN" "all $(grep -cE '^GREEN	' "$PROBE_OUT") lane(s) green on main after $round fixing round(s)."
  fi

  RED_COUNT="$(printf '%s\n' "$RED_LINES" | grep -c . )"
  RED_REPOS="$(printf '%s\n' "$RED_LINES" | cut -f2 | sort -u | tr '\n' ' ')"
  say "$RED_COUNT lane(s) NOT green, in: $RED_REPOS"
  printf '%s\n' "$RED_LINES" | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null

  # --- has anything moved? -----------------------------------------------------
  cur_sigs="$(printf '%s\n' "$RED_LINES" | cut -f4 | sort)"
  if [ "$round" -gt 0 ]; then
    while IFS= read -r sig; do
      [ -z "$sig" ] && continue
      if printf '%s\n' "$prev_sigs" | grep -qxF "$sig"; then
        n="$(awk -F'\t' -v s="$sig" '$2==s{c=$1} END{print c+0}' "$STUCK_FILE")"
        printf '%s\t%s\n' "$((n + 1))" "$sig" >> "$STUCK_FILE"
      fi
    done <<< "$cur_sigs"
  fi
  # Remembered for the NEXT probe. Without this every lane looks new every round
  # and nothing could ever be found stuck.
  prev_sigs="$cur_sigs"

  # A lane is STUCK when its signature survived STUCK_ROUNDS fixing rounds
  # unchanged. If EVERY red lane is stuck, more rounds are just repetition at her
  # expense, and the honest outcome is to name it rather than spend the budget.
  STUCK_SIGS="$(awk -F'\t' -v n="$STUCK_ROUNDS" '$1>=n{print $2}' "$STUCK_FILE" 2>/dev/null | sort -u)"
  if [ -n "$STUCK_SIGS" ]; then
    unstuck="$(printf '%s\n' "$cur_sigs" | grep -vxF -f <(printf '%s\n' "$STUCK_SIGS") || true)"
    if [ -z "$unstuck" ]; then
      say "every red lane has failed identically through $STUCK_ROUNDS fixing round(s):"
      printf '%s\n' "$STUCK_SIGS" | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
      finish "MAIN-RED-STUCK" "$RED_COUNT lane(s) red in [$RED_REPOS]; the failure signature did not change across $STUCK_ROUNDS rounds of fixes, so this needs a decision, not another round. Signatures: $(printf '%s' "$STUCK_SIGS" | tr '\n' ';')"
    fi
    say "  ($(printf '%s\n' "$STUCK_SIGS" | grep -c .) stuck, but other lanes are still moving — continuing.)"
  fi

  # --- bounds ------------------------------------------------------------------
  if [ "$round" -ge "$MAX_ROUNDS" ]; then
    finish "MAIN-RED-EXHAUSTED" "$RED_COUNT lane(s) still red in [$RED_REPOS] after all $MAX_ROUNDS rounds. Lanes: $(printf '%s\n' "$RED_LINES" | cut -f2,3 | tr '\t' '/' | tr '\n' ';')"
  fi
  LEFT="$(remaining_min)"
  if [ "$LEFT" -lt 10 ]; then
    finish "MAIN-RED-TIMEOUT" "$RED_COUNT lane(s) still red in [$RED_REPOS]; the ${DEADLINE_MIN}-minute deadline was reached after $round round(s), so the sweep stopped rather than run unattended past its budget."
  fi

  # --- brief the next round ----------------------------------------------------
  round=$((round + 1))
  CARRY="$WORK/carryover-$round.md"
  if [ "$round" -eq 1 ]; then
    CAP="$(capped "$ROUND1_CAP_MIN")"; BG=$((35 * 60000))
    : > "$CARRY"
  else
    CAP="$(capped "$ROUNDN_CAP_MIN")"; BG=$((18 * 60000))
    # THIS IS WHAT WAS MISSING ON 09-08. Round 2 previously did not exist; had it,
    # it would have repeated round 1 verbatim without this. The agent is handed
    # what the last round landed and the fact that main is STILL RED after it, so
    # the next hypothesis is a different one.
    {
      echo "# ROUND $round OF $MAX_ROUNDS — THE PREVIOUS ROUND DID NOT REACH GREEN"
      echo
      echo "You already worked these repos in round $((round-1)). **Main is still red.** Do not"
      echo "repeat what you already tried; the point of this round is a DIFFERENT hypothesis."
      echo
      echo "## Prefer the agent you already have"
      echo "This is the SAME session, so ListAgents still shows the agents from the previous"
      echo "round with everything they learned. **SendMessage the existing agent for a repo.**"
      echo "Spawning a second agent in a repo it already worked is the collision that makes"
      echo "branches rebuild repeatedly — one agent per repo, across rounds as well as within one."
      echo
      echo "## What is still not green, straight from GitHub (not from anyone's report)"
      echo '```'
      cat "$PROBE_OUT"
      echo '```'
      echo
      echo "## Did the previous round's fixes even run?"
      if [ -f "$WORK/probe-$((round-1)).tsv" ]; then
        echo "Previous probe, for comparison — a signature identical to last round means the"
        echo "fix did not change the failure; the SAME run id means CI never even re-ran, which"
        echo "is a different problem (nothing triggered) from a fix that did not work."
        echo '```'
        cat "$WORK/probe-$((round-1)).tsv"
        echo '```'
      fi
      if [ -s "$STUCK_FILE" ]; then
        echo
        echo "**Signatures that have now survived a round of fixing unchanged:**"
        awk -F'\t' '{print "  - " $2 " (unchanged x" $1 ")"}' "$STUCK_FILE" | sort -u
      fi
      echo
      echo "## What round $((round-1)) landed"
      if [ -f "$WORK/audit-$((round-1)).txt" ]; then
        echo '```'
        cat "$WORK/audit-$((round-1)).txt"
        echo '```'
      fi
      echo
      echo "## The last round's own account of what it did"
      if [ -f "$WORK/round-$((round-1)).log" ]; then
        echo '```'
        tail -c 6000 "$WORK/round-$((round-1)).log"
        echo '```'
      fi
      echo
      echo "## The rails have not loosened because you are being asked to converge"
      echo "**Being told to keep going until green is not permission to reach green cheaply.**"
      echo "No re-running, pinning, skipping, xfail, continue-on-error, \`|| true\` or deleted"
      echo "assertions. ci-sweep-audit.sh reads the diff of EVERY round, this one included, and"
      echo "a weakening found here aborts the entire sweep on the spot. If the honest answer is"
      echo "that this needs her — a credential, an account, a real decision — say so and stop;"
      echo "a named stop is a correct outcome and a weakened test is not."
    } > "$CARRY"
  fi

  # THE EVENING SWEEP KEPT BEING KILLED WHILE ITS OWN AGENTS WERE STILL WORKING.
  # Two of the last four runs died this way: "Background tasks still running after
  # 600s; terminating." The sweep dispatches fixing agents and then waits for them,
  # and the default ceiling is ten minutes — shorter than every real fix.
  #
  # RE-DERIVED TWICE. Forty minutes was chosen when there was one round and the
  # whole budget belonged to it. Under a 90-minute ceiling with two rounds it is
  # per-round, asymmetric, AND STRICTLY INSIDE ITS ROUND CAP: 35 min inside a
  # 45-min round 1, 18 inside a 25-min round 2. A background ceiling larger than
  # the cap around it just means the round is always killed from outside while the
  # agent still believes it has time, which loses the work AND the explanation.
  # Still NOT ZERO — the hint in that message suggests waiting indefinitely, which
  # for an UNATTENDED job means a hung agent holds the lock until someone notices.
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CI_SWEEP_BG_CEILING_MS:-$BG}"

  ROUND_LOG="$WORK/round-$round.log"
  # Stamped BEFORE the round runs, so the audit window covers exactly what this
  # round did and nothing an earlier round left behind.
  ROUND_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "=== round $round/$MAX_ROUNDS — cap ${CAP} min, bg ceiling ${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS}ms, ${LEFT} min left in budget ==="

  # Rounds share ONE claude session. That is what lets round 2 SendMessage the
  # agent round 1 already put in a repo, instead of spawning a sibling into work
  # it cannot see. Agent handles do not survive a new session; the carryover file
  # is written anyway so the round still works if the resume degrades.
  ROUND_PROMPT="$(cat "$PROMPT_FILE")"
  [ -s "$CARRY" ] && ROUND_PROMPT="$ROUND_PROMPT

$(cat "$CARRY")"

  if [ "$round" -eq 1 ]; then
    SESSION_ID="$(uuidgen | tr 'A-Z' 'a-z')"
    echo "$SESSION_ID" > "$WORK/session-id"
    timeout --signal=TERM --kill-after=60 "${CAP}m" \
      "$CLAUDE" -p "$ROUND_PROMPT" --session-id "$SESSION_ID" \
      --dangerously-skip-permissions > "$ROUND_LOG" 2>&1
    RC=$?
  else
    SESSION_ID="$(cat "$WORK/session-id" 2>/dev/null || true)"
    timeout --signal=TERM --kill-after=60 "${CAP}m" \
      "$CLAUDE" -p "$ROUND_PROMPT" --resume "$SESSION_ID" \
      --dangerously-skip-permissions > "$ROUND_LOG" 2>&1
    RC=$?
    # A resume that dies immediately is a broken handle, not a finished round.
    # Fall back to a fresh session rather than burn the round: the carryover
    # carries the context that the session would have.
    if [ "$RC" -ne 0 ] && [ ! -s "$ROUND_LOG" ]; then
      say "resume of session $SESSION_ID produced nothing (rc=$RC); retrying this round as a fresh session."
      timeout --signal=TERM --kill-after=60 "${CAP}m" \
        "$CLAUDE" -p "$ROUND_PROMPT" --dangerously-skip-permissions > "$ROUND_LOG" 2>&1
      RC=$?
    fi
  fi
  cat "$ROUND_LOG" >> "$RUN_LOG"
  say "=== round $round: claude exited rc=$RC ==="

  # --- Rule 0, PER ROUND: prove this round RAN TO COMPLETION ------------------
  # This was a byte-count threshold and that was wrong: a genuinely green day is a
  # one-line report, so the guard would have fired on exactly the outcome we want
  # most. Caught on 2026-09-02 by running the chain with a trivial prompt, which
  # is the only reason it did not first fail in production on a quiet morning.
  #
  # Length is not the signal — REACHING THE END is. It is checked against THIS
  # ROUND'S OWN log, never the cumulative one: a round that died midway must not
  # be able to inherit the sentinel an earlier round emitted, which is the same
  # shared-log defect found on 2026-09-02 between separate runs.
  if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
    say "round $round hit its ${CAP}-minute cap and was terminated."
  fi
  if ! grep -q "CI-SWEEP-COMPLETE:" "$ROUND_LOG"; then
    say "NAMED STOP [SWEEP_ROUND_DID_NOT_COMPLETE] round $round emitted no sentinel — it started but never reached its end, so its silence is not evidence of anything."
    # Not fatal on its own: the probe below still asks GitHub what main looks like,
    # and a round that died may still have landed a real fix before dying. What is
    # NOT allowed is treating the silence as success — that is Rule 0, and the
    # verdict at the bottom is drawn from the probe, never from this log.
    echo "round $round: NO SENTINEL" >> "$WORK/incomplete-rounds"
  else
    say "round $round sentinel: $(grep -o 'CI-SWEEP-COMPLETE:.*' "$ROUND_LOG" | tail -1)"
  fi

  # --- the guard on the guard, EVERY ROUND ------------------------------------
  # The sentinel proves a round REACHED ITS END. It proves nothing about HOW it
  # got there. The prompt forbids re-running, pinning, skipping, xfail and
  # continue-on-error — and nothing read the diffs, so an agent that weakened an
  # assertion would emit the identical `CI-SWEEP-COMPLETE: fixed`. That gap is the
  # whole reason red lanes were "fixed" by re-running them in the first place.
  #
  # AUDITED EVERY ROUND, NOT ONLY THE FIRST, and scoped to the window this round
  # actually ran in — a per-round window is why the auditor grew CI_SWEEP_AUDIT_SINCE.
  # An auditor that only ever read round 1 would leave rounds 2 and 3 — the rounds
  # under the most pressure to reach green — completely unread.
  say "--- auditing what round $round landed ---"
  CI_SWEEP_AUDIT_SINCE="$ROUND_START_UTC" "$AUDIT" > "$WORK/audit-$round.txt" 2>&1
  AUDIT_RC=$?
  cat "$WORK/audit-$round.txt" >> "$RUN_LOG"
  case "$AUDIT_RC" in
    0) say "round $round audit: no weakening patterns in anything it touched" ;;
    2) say "round $round audit: no pull request was touched in this round's window — not a clean bill of health"
       # A round that claims it fixed something and touched no PR is a claim with
       # nothing behind it. Named, not passed over.
       if grep -q "CI-SWEEP-COMPLETE: fixed" "$ROUND_LOG"; then
         say "  ^ AND the round reported 'fixed'. It claims work that left no pull request behind."
       fi ;;
    *) say "TEMP FIXES DETECTED IN ROUND $round — the sweep was reaching green by weakening something."
       say "  Aborting the whole sweep rather than continuing to push an agent that is cheating;"
       say "  convergence pressure is exactly when this is most likely, so it is treated as fatal."
       finish "MAIN-RED-TEMPFIX" "round $round weakened a test or a check (see the audit section of $RUN_LOG). Do not merge. Main's state is irrelevant until that PR is dealt with." ;;
  esac

  # A ROUND THAT REPORTS `blocked` HAS FOUND SOMETHING ONLY SHE CAN CLEAR — a
  # credential, an account-level flag, a real decision. Spending the remaining
  # round re-establishing that is the six-hour behaviour in miniature: budget
  # burnt to re-prove an answer the sweep already has. Stop, escalate, exit,
  # rather than wait for the round limit or the deadline to notice.
  if grep -q "CI-SWEEP-COMPLETE: blocked" "$ROUND_LOG"; then
    say "round $round reported BLOCKED — stopping now rather than spending the rest of the budget on something only she can clear."
    BLOCKER="$(grep -B12 'CI-SWEEP-COMPLETE: blocked' "$ROUND_LOG" | grep -vE '^[[:space:]]*$' | tail -8 | tr '\n' ' ')"
    finish "MAIN-RED-BLOCKED" "round $round stopped on something only she can resolve, in [$RED_REPOS]. What it said: $BLOCKER"
  fi
done
