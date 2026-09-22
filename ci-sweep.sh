#!/bin/bash
# CI sweep — runs under launchd, independent of any chat session. launchd ticks
# it every 30 minutes (:07 and :37); the gate below decides whether a tick is a
# sweep (main not proven green recently, inside the window, not cooling down)
# or a one-line "not due". On a green day that reproduces the old 10:07 / 18:07
# cadence exactly; on a red day it keeps coming back.
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

# --- retry while red (added 2026-09-21) ---------------------------------------
# HER RULING, 21 Sep 2026: "we need to fix CI sweep from doing that hung with no
# verdict and not trying again. it should keep trying and never leave a main on
# red." That morning the 10:07 run's round 1 was cut in half by the Mac sleeping
# on battery (10:40-12:25), the audit then read a PR someone else touched during
# the gap as this round's weakening (MAIN-RED-TEMPFIX), the 120-minute watchdog
# fired on WALL time a minute later (MAIN-RED-HUNG), and nothing ran again until
# the 18:07 calendar slot. Two verdicts, no retry, main red for six hours.
#
# The 2-hour ceiling above bounds ONE RUN. It never bounded the day, and a day is
# what she cares about. So every non-green outcome now schedules another run.
#
# THE MECHANISM IS THE TICK. launchd fires this script every 30 minutes (Minute 7
# and Minute 37 of every hour, com.seq.ci-sweep). A tick reads the outcome ledger
# and either runs a sweep or prints one line and exits. It does not need a timer
# to survive a reboot or a sleep: launchd owns the schedule, and a calendar tick
# that fell during sleep fires once at wake.
#
# THE NUMBERS, each derived, none picked:
#   WINDOW 10:00-22:00 local. Starts are allowed inside it; the last start
#     (21:37) ends by 23:12 on budget, 23:37 at the hard kill. The old 10:07 slot
#     is kept as the day's first tick. Nothing starts overnight: her plan is not
#     an unattended all-night budget, and nobody is fixing at 03:00 anyway.
#   GREEN_TTL 450 min. The old cadence was two sweeps 8h apart. A green result is
#     trusted for 8h less one tick, so the 18:07 tick still runs after a 10:09
#     green (10:09+7h30 = 17:39 < 18:07) and a green at 18:10 next runs at 10:07
#     tomorrow. A tick inside the TTL is "not due".
#   RETRY_GAP 25 min after a non-green run ENDS. Ticks are 30 min apart, so the
#     first tick at least 25 min after the end is the retry: the gap lands in
#     [25, 55) min — "about 30 minutes later" at tick resolution. The gap is
#     what lets the CI runs the last attempt pushed reach a terminal state.
#   MAX_ATTEMPTS 6 non-green runs in a day before she is told. Derived from the
#     window: 12h / (95 min budget + 25 min gap) = 6 full-length attempts. Six
#     red runs either spent the whole day's budget or were short repeated stops;
#     both mean iteration is not working and she needs to hear it ONCE.
#   SLOW_GAP 120 min between attempts after that — one full budget plus headroom
#     so attempts cannot pile up, but never stopping: the ruling says keep trying.
#   SLEEP_GAP 180s. The sentry ticks every 20s; a gap of more than 9 ticks
#     between two of its own timestamps means the Mac was asleep, not that the
#     sweep was slow. Same 9x20s the lock reclaim already uses.
WINDOW_START_H="${CI_SWEEP_WINDOW_START_H:-10}"
WINDOW_END_H="${CI_SWEEP_WINDOW_END_H:-22}"
GREEN_TTL_MIN="${CI_SWEEP_GREEN_TTL_MIN:-450}"
RETRY_GAP_MIN="${CI_SWEEP_RETRY_GAP_MIN:-25}"
MAX_ATTEMPTS="${CI_SWEEP_MAX_ATTEMPTS:-6}"
SLOW_GAP_MIN="${CI_SWEEP_SLOW_GAP_MIN:-120}"
SLEEP_GAP_SECS="${CI_SWEEP_SLEEP_GAP_SECS:-180}"
TICK_SECS="${CI_SWEEP_TICK_SECS:-20}"

# Overridable so the plumbing (claude headless, logging, Rule 0, the lock, the
# convergence loop) can be exercised with a trivial prompt without dispatching a
# real sweep. A scheduled job whose only test is "it ran in production" is a job
# nobody can verify.
PROMPT_FILE="${CI_SWEEP_PROMPT:-$HOME/bin/ci-sweep-prompt.md}"
PROBE="${CI_SWEEP_PROBE_BIN:-$HOME/bin/ci-sweep-probe.sh}"
AUDIT="${CI_SWEEP_AUDIT_BIN:-$HOME/bin/ci-sweep-audit.sh}"
STREAM="${CI_SWEEP_STREAM_BIN:-$HOME/bin/ci-sweep-stream.py}"
# Overridable for the same reason the prompt is: the lock, Rule 0, the round loop
# and the verdict must all be exercisable without touching the live lock or the
# real log directory. A test that has to share state with the production run is a
# test nobody dares to run.
LOG_DIR="${CI_SWEEP_LOG_DIR:-$HOME/Library/Logs/ci-sweep}"
LOCK="$LOG_DIR/.lock"
STAMP="$(date +%Y-%m-%dT%H:%M:%S)"
STARTED_AT="${CI_SWEEP_STARTED_AT:-$(date +%s)}"
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
GITHUB_DIR="${CI_SWEEP_GITHUB_DIR:-$HOME/GitHub}"
GH_OWNER="${CI_SWEEP_GH_OWNER:-seq23}"

# Cross-run state. ONE ledger, read by the gate and written by every outcome;
# the gate derives "last green", "attempts today" and "last end" from it rather
# than keeping three files that can disagree.
#   outcomes.tsv       end-epoch \t YYYY-MM-DD \t VERDICT \t run-id
#   carryover-next.md  what the last non-green run tried, rejected and parked —
#                      handed to the next run's round 1. Deleted by a green run.
#   escalated-<date>   the once-a-day MAX_ATTEMPTS escalation has been sent.
STATE_DIR="$LOG_DIR/state"
LEDGER="$STATE_DIR/outcomes.tsv"
NEXT_CARRY="$STATE_DIR/carryover-next.md"

# $WORK is created only once a tick has decided to sweep (see the gate), so 24
# ticks a day do not leave 24 empty directories behind.
mkdir -p "$LOG_DIR" "$STATE_DIR"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
# Format an epoch: BSD date takes -r, GNU date takes -d @. The tests run on both.
at_time() { local e="$1"; shift; date -r "$e" "$@" 2>/dev/null || date -d "@$e" "$@"; }
at_time_utc() { local e="$1"; shift; date -u -r "$e" "$@" 2>/dev/null || date -u -d "@$e" "$@"; }

# --- the outcome ledger --------------------------------------------------------
# Replaces any earlier line for this run id: the body may record a verdict and
# the supervisor may then overrule it (a sleep gap, a hang), and a run must count
# once. `now` is overridable so the gate's arithmetic can be tested at a chosen
# instant against a crafted ledger.
now_epoch() { echo "${CI_SWEEP_NOW:-$(date +%s)}"; }
record_outcome() {
  local verdict="$1" id="${2:-$RUN_ID}" ts; ts="$(now_epoch)"
  local tmp="$LEDGER.tmp.$$"
  { [ -f "$LEDGER" ] && awk -F'\t' -v id="$id" '$4!=id' "$LEDGER"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$(at_time "$ts" +%Y-%m-%d)" "$verdict" "$id"; } > "$tmp"
  mv "$tmp" "$LEDGER"
}
ledger_last_green()   { [ -f "$LEDGER" ] && awk -F'\t' '$3=="MAIN-GREEN"{g=$1} END{print g+0}' "$LEDGER" || echo 0; }
ledger_last_end()     { [ -f "$LEDGER" ] && awk -F'\t' '{e=$1} END{print e+0}' "$LEDGER" || echo 0; }
ledger_last_verdict() { [ -f "$LEDGER" ] && awk -F'\t' '{v=$3} END{print v}' "$LEDGER" || echo ""; }
# Non-green runs in the last 24 hours, counted from the last green (a green resets it).
# A ROLLING DAY, NOT A CALENDAR DAY. The first version matched the ledger's date column
# against "today", which is whatever timezone the clock is in: on the CI runner (UTC) a run
# that ended ten minutes before midnight was on a different "day" from the tick that read
# it, the count went to zero, and four assertions failed at 23:54Z on 21 Sep 2026 that had
# passed at 20:05Z. The escalation and the slow cadence mean "six attempts without a green
# in a day", and that is a window of seconds, not a date string.
ledger_attempts_today() {
  local now="$1"
  [ -f "$LEDGER" ] || { echo 0; return; }
  awk -F'\t' -v now="$now" '$3=="MAIN-GREEN"{n=0; next} $1+0 > now-86400 {n++} END{print n+0}' "$LEDGER"
}

# --- the gate: is this tick a sweep? -------------------------------------------
# Prints "RUN <why>" or "SKIP <why>". Pure: reads the ledger and the clock, writes
# nothing. Only a tick (CI_SWEEP_TICK=1, set by the plist) is gated; a person
# running the script by hand always gets a sweep, as before.
gate_decision() {
  local now hour day last_green last_end attempts since_end gap
  now="$(now_epoch)"; hour="$(at_time "$now" +%H | sed 's/^0//')"; day="$(at_time "$now" +%Y-%m-%d)"
  if [ "$hour" -lt "$WINDOW_START_H" ] || [ "$hour" -ge "$WINDOW_END_H" ]; then
    echo "SKIP outside the ${WINDOW_START_H}:00-${WINDOW_END_H}:00 window; the day's first tick is ${WINDOW_START_H}:07"; return
  fi
  last_green="$(ledger_last_green)"
  last_end="$(ledger_last_end)"
  attempts="$(ledger_attempts_today "$now")"
  # THE LATEST RUN DECIDES. A non-green run after a green one supersedes it —
  # main is known red now, however recent the green was — so the green TTL only
  # applies when the last line of the ledger IS the green.
  if [ "$(ledger_last_verdict)" = "MAIN-GREEN" ]; then
    if [ $(( now - last_green )) -lt $(( GREEN_TTL_MIN * 60 )) ]; then
      echo "SKIP main was proven green $(( (now - last_green) / 60 )) min ago (trusted for ${GREEN_TTL_MIN} min; next sweep at or after $(at_time $(( last_green + GREEN_TTL_MIN * 60 )) +%H:%M))"; return
    fi
  elif [ "$last_end" -gt 0 ]; then
    since_end=$(( now - last_end ))
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then gap=$(( SLOW_GAP_MIN * 60 )); else gap=$(( RETRY_GAP_MIN * 60 )); fi
    if [ "$since_end" -lt "$gap" ]; then
      echo "SKIP last attempt (#$attempts today) ended $(( since_end / 60 )) min ago; retry at or after $(at_time $(( last_end + gap )) +%H:%M)$( [ "$attempts" -ge "$MAX_ATTEMPTS" ] && printf ' (slow cadence: %s attempts today, she has been told)' "$attempts")"; return
    fi
    if [ "$attempts" -eq 0 ]; then
      echo "RUN main was not green at the last run ($(( since_end / 60 )) min ago); first attempt today"; return
    fi
    echo "RUN retry: main was not green at the last attempt (#$attempts today, ended $(( since_end / 60 )) min ago)"; return
  fi
  echo "RUN no green result inside the last ${GREEN_TTL_MIN} min"
}

# What a non-green run says about the future, so no log ends on a stop with
# nothing scheduled. Also fires the once-a-day escalation at MAX_ATTEMPTS.
schedule_next() {
  local day attempts gap next
  day="$(at_time "$(now_epoch)" +%Y-%m-%d)"
  attempts="$(ledger_attempts_today "$(now_epoch)")"
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then gap=$(( SLOW_GAP_MIN * 60 )); else gap=$(( RETRY_GAP_MIN * 60 )); fi
  next=$(( $(now_epoch) + gap ))
  if [ "$(at_time "$next" +%H | sed 's/^0//')" -ge "$WINDOW_END_H" ] || [ "$(at_time "$next" +%H | sed 's/^0//')" -lt "$WINDOW_START_H" ]; then
    say "RETRY: attempt #$attempts today was not green; the window closes at ${WINDOW_END_H}:00, so the next attempt is the ${WINDOW_START_H}:07 tick tomorrow (the day's count resets)."
  else
    say "RETRY: attempt #$attempts today was not green; the next attempt is the first tick at or after $(at_time "$next" +%H:%M) (fresh session, fresh budget)."
  fi
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ] && [ ! -f "$STATE_DIR/escalated-$day" ]; then
    : > "$STATE_DIR/escalated-$day"
    say "ESCALATING: $attempts non-green attempts today reached the ${MAX_ATTEMPTS}-attempt mark; telling her once, then continuing every ${SLOW_GAP_MIN} min."
    if [ -x "$NOTIFY" ]; then
      CI_SWEEP_ATTEMPTS="$attempts" "$NOTIFY" "SWEEP-ATTEMPTS-EXHAUSTED" \
        "$attempts consecutive non-green sweeps today (verdicts: $(awk -F'\t' -v d="$day" '$2==d{printf "%s ", $3}' "$LEDGER")). The sweep keeps retrying every ${SLOW_GAP_MIN} min until the window closes at ${WINDOW_END_H}:00, but iteration is not converging and the last attempt's carryover is in $NEXT_CARRY." \
        "$RUN_LOG" >>"$RUN_LOG" 2>&1 || echo "[notify] escalation failed; see above" >> "$RUN_LOG"
    fi
  fi
}

# --- park and reject: a PR the sweep opened is never silently landed work --------
# Open PRs in the repos this run was dispatched to, created since it started.
# The sweep itself never merges anything; its agents do, and a round that was
# cut off (sleep, hang) may have left a half-finished PR behind. Those are named
# on the PR and in the next run's carryover as PARKED — the next attempt re-reads
# them, it does not inherit them as done.
sweep_prs_opened_this_run() {
  local repo since
  since="$(at_time_utc "$STARTED_AT" +%Y-%m-%dT%H:%M:%SZ)"
  command -v gh >/dev/null 2>&1 || return 0
  for repo in $(cat "$WORK/red-repos" 2>/dev/null); do
    gh pr list --repo "$GH_OWNER/$repo" --state open --limit 30 --json number,createdAt,title,headRefName \
      --jq ".[] | select(.createdAt >= \"$since\") | \"$repo\t\(.number)\t\(.headRefName)\t\(.title)\"" 2>/dev/null
  done
}
pr_note() {   # repo num marker body — one note per PR per marker, never a merge or close
  local repo="$1" num="$2" marker="$3" body="$4"
  command -v gh >/dev/null 2>&1 || return 0
  if gh pr view "$num" --repo "$GH_OWNER/$repo" --json comments --jq '.comments[].body' 2>/dev/null | grep -qF "$marker"; then
    return 0
  fi
  gh pr comment "$num" --repo "$GH_OWNER/$repo" --body "$marker
$body" >/dev/null 2>&1 || say "  (could not comment on $repo#$num)"
}
park_open_prs() {
  local why="$1" line repo num branch title n=0
  while IFS=$'\t' read -r repo num branch title; do
    [ -z "$num" ] && continue
    n=$((n + 1))
    printf '%s#%s\t%s\t%s\n' "$repo" "$num" "$branch" "$title" >> "$WORK/parked"
    say "  PARKED $repo#$num ($branch): $why"
    pr_note "$repo" "$num" "[ci-sweep] PARKED — not landed work" \
      "The sweep round that opened this pull request did not finish: $why. Nothing here has been verified green on main, and the sweep will not merge it. The next attempt is told about this PR and re-reads it; a person may close it or take it over. Run log: $RUN_LOG"
  done < <(sweep_prs_opened_this_run)
  [ "$n" -eq 0 ] && say "  (no open PR of this run's to park in [$(cat "$WORK/red-repos" 2>/dev/null | tr '\n' ' ')])"
  return 0
}
# A PR the audit found FATAL is rejected on the PR itself and recorded for the
# next attempt. Rejected, not closed: the same repo may hold a person's PR touched
# in the window (today's boss-os#33 was exactly that), and a close is destructive
# where a note is not. The sweep never merges it; the carryover says why.
reject_audited_prs() {
  local audit_file="$1" round="$2" ref repo num why n=0
  while IFS= read -r line; do
    ref="$(printf '%s' "$line" | grep -oE 'FATAL [A-Za-z0-9._-]+#[0-9]+' | head -1 | sed 's/^FATAL //')"
    [ -z "$ref" ] && continue
    repo="${ref%#*}"; num="${ref#*#}"
    # Only a PR in a repo this run was dispatched to is the sweep's to reject;
    # the audit has already downgraded the rest to SUSPECT, but a FATAL line for
    # an out-of-scope PR can still sit next to an in-scope one in the same file.
    grep -qxF "$repo" "$WORK/red-repos" 2>/dev/null || { say "  (not rejecting $ref: outside this run's scope)"; continue; }
    why="$(printf '%s' "$line" | sed 's/.*— //')"
    n=$((n + 1))
    printf '%s\t%s\n' "$ref" "$why" >> "$WORK/rejected"
    say "  REJECTED $ref: $why"
    pr_note "$repo" "$num" "[ci-sweep] REJECTED by the audit — do not merge" \
      "ci-sweep-audit.sh found a weakening in this pull request during sweep round $round: **$why**. The sweep will not merge it and stops this attempt here. The next attempt (~30 min) is told what was rejected and why, and goes for the root cause instead. Either fix this PR so the weakening is gone, or close it. Run log: $RUN_LOG"
  done < <(grep -E '✗ FATAL ' "$audit_file" 2>/dev/null)
  [ "$n" -eq 0 ] && say "  (the audit reported FATAL but named no PR the sweep could act on)"
  return 0
}

# What the NEXT run's round 1 is told. Written by every non-green outcome, from
# whichever process reached it (body or supervisor), and deleted by a green run.
write_next_carryover() {
  local verdict="$1" detail="$2" day last_probe last_audit last_round
  day="$(at_time "$(now_epoch)" +%Y-%m-%d)"
  last_probe="$(ls -1 "$WORK"/probe-*.tsv 2>/dev/null | sort -V | tail -1)"
  last_audit="$(ls -1 "$WORK"/audit-*.txt 2>/dev/null | sort -V | tail -1)"
  last_round="$(ls -1 "$WORK"/round-*.log 2>/dev/null | sort -V | tail -1)"
  {
    echo "# A PREVIOUS ATTEMPT TODAY DID NOT REACH GREEN — this is a RETRY, not the first look"
    echo
    echo "Verdict of the last attempt ($RUN_ID): **$verdict** — $detail"
    echo
    echo "Attempts today so far (the ledger): $(awk -F'\t' -v d="$day" '$2==d{print $1, $3}' "$LEDGER" 2>/dev/null | while read -r e v; do printf '%s %s; ' "$(at_time "$e" +%H:%M)" "$v"; done)"
    echo
    if [ -s "$WORK/rejected" ]; then
      echo "## REJECTED by the audit — these PRs contain a weakening. DO NOT MERGE THEM."
      echo "The previous attempt reached for green cheaply and was stopped for it. Go for the"
      echo "ROOT CAUSE this time. You may fix the named PR so the weakening is gone, or close"
      echo "it and open a proper one; merging it as-is is the one thing you may not do."
      awk -F'\t' '{print "  - " $1 ": " $2}' "$WORK/rejected"
      echo
    fi
    if [ -s "$WORK/parked" ]; then
      echo "## PARKED — opened by a round that was cut off; NOT finished, NOT verified"
      echo "Read them before doing anything else in that repo: reuse what is sound, close"
      echo "what is not. Do not assume any of it is landed work."
      awk -F'\t' '{print "  - " $1 " (" $2 "): " $3}' "$WORK/parked"
      echo
    fi
    if [ -n "$last_probe" ]; then
      echo "## What was not green when the last attempt looked (straight from GitHub)"
      echo '```'; grep -E '^(RED|SILENT)	' "$last_probe" || echo "(the probe had not found red lanes yet)"; echo '```'
      echo
    fi
    if [ -n "$last_audit" ]; then
      echo "## What the last attempt's audit said"
      echo '```'; tail -c 3000 "$last_audit"; echo '```'
      echo
    fi
    if [ -n "$last_round" ]; then
      echo "## The last attempt's own account of what it tried (tail)"
      echo '```'; tail -c 6000 "$last_round"; echo '```'
      echo
    fi
    echo "## The rails have not loosened because this is a retry"
    echo "No re-running, pinning, skipping, xfail, continue-on-error, \`|| true\` or deleted"
    echo "assertions. The audit reads every round's diff. A named stop beats a false green."
  } > "$NEXT_CARRY"
}

# Everything a completed run does with its verdict, from whichever process
# reached it. The body calls it through finish(); the supervisor calls it for
# the outcomes only it can see (interrupted, hung, could-not-run).
conclude() {
  local verdict="$1" detail="$2"
  ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
  echo "$verdict" > "$WORK/verdict" 2>/dev/null
  echo "CI-SWEEP-COMPLETE: $verdict — $detail" | tee -a "$RUN_LOG"
  record_outcome "$verdict"
  # A LOG FILE IS NOT A NOTIFICATION. ~/Library/Logs/ci-sweep/latest.log is not a
  # place she goes, so before this every red night was indistinguishable from a
  # green one unless she went looking — which is the same defect as a sweep that
  # reports success over a red lane, one layer out.
  #
  # MAIN-GREEN DELIBERATELY DOES NOT NOTIFY. A notification that arrives every day
  # is one she stops reading, and then the red ones do not land either.
  if [ "$verdict" = "MAIN-GREEN" ]; then
    rm -f "$NEXT_CARRY"
    return 0
  fi
  write_next_carryover "$verdict" "$detail"
  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" "$verdict" "$detail" "$RUN_LOG" >>"$RUN_LOG" 2>&1 || \
      echo "[notify] escalation failed; see above" >> "$RUN_LOG"
  fi
  schedule_next
}

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
finish() {
  conclude "$1" "$2"
  case "$1" in
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

  # --- the gate: a tick is not always a sweep -----------------------------------
  # CI_SWEEP_GATE_ONLY=1 prints the decision and exits — the dry run used to prove
  # an installed plist without starting a 95-minute sweep.
  if [ -n "${CI_SWEEP_TICK:-}" ] || [ -n "${CI_SWEEP_GATE_ONLY:-}" ]; then
    DECISION="$(gate_decision)"
    if [ -n "${CI_SWEEP_GATE_ONLY:-}" ]; then
      echo "[gate] $DECISION"; exit 0
    fi
    case "$DECISION" in
      SKIP*) echo "[$(date +%H:%M:%S)] tick: not due — ${DECISION#SKIP }"; exit 0 ;;
      *)     echo "[$(date +%H:%M:%S)] tick: sweeping — ${DECISION#RUN }" ;;
    esac
  fi
  mkdir -p "$WORK"

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
      # A STALE HEARTBEAT AT WAKE IS THE HOLDER'S SENTRY ABOUT TO ACT, NOT A WEDGE.
      # When the Mac sleeps, launchd fires the missed tick at wake — the same
      # instant the holder's sentry sees its own gap and ends that run as
      # INTERRUPTED. Reclaiming here would kill the holder before it could record
      # that outcome, and an unrecorded run is the silence the ledger exists to
      # end. So give it two ticks: if it exits, the lock is simply free; if it
      # ticks again, it is healthy; only a holder that does neither is wedged.
      sleep $(( LOCK_STALE_AFTER / 3 ))
      beat="$(cat "$LOCK/heartbeat" 2>/dev/null || echo 0)"; now="$(date +%s)"
      if ! kill -0 "$holder" 2>/dev/null; then
        reclaim="its process ended while this tick waited (it recorded its own outcome)"
      elif [ $(( now - beat )) -le "$LOCK_STALE_AFTER" ]; then
        reclaim=""
      else
        reclaim="its heartbeat is $(( now - beat ))s stale (>${LOCK_STALE_AFTER}s) — the holder is wedged, not working"
      fi
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
      # A run killed here never recorded itself. It counts as an attempt — the
      # ledger is what the gate and the escalation read, and a wedged run that
      # vanished from it would make a red day look shorter than it was.
      old_id="$(cat "$LOCK/run-id" 2>/dev/null || echo "")"
      if [ -n "$old_id" ]; then
        record_outcome "MAIN-RED-RECLAIMED" "$old_id"
        say "recorded $old_id as MAIN-RED-RECLAIMED (it was killed here without a verdict)."
      fi
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { say "FAILED to take lock"; exit 3; }
  fi
  echo $$ > "$LOCK/pid"
  echo "$RUN_ID" > "$LOCK/run-id"
  echo "$STARTED_AT" > "$LOCK/started"
  date +%s > "$LOCK/heartbeat"
  # Only ever release a lock this process still owns — see the ordering note in the
  # reclaim path: a killed holder's cleanup can land after the new holder took it.
  release_lock() { [ "$(cat "$LOCK/pid" 2>/dev/null || echo)" = "$$" ] && rm -rf "$LOCK"; }

  say "=== CI sweep supervisor: convergence budget ${DEADLINE_MIN} min, hard kill at ${HARD_KILL_MIN} min ($(at_time "$KILL_AT" +%H:%M)) ==="

  export CI_SWEEP_SUPERVISED=1 CI_SWEEP_RUN_ID="$RUN_ID" CI_SWEEP_STARTED_AT="$STARTED_AT"

  # setsid via python: the body becomes a process-group leader, so PGID == its pid
  # and one signal reaches it AND every agent, gh and claude beneath it.
  /usr/bin/python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      /bin/bash "$0" "$@" &
  BODY=$!

  # THE SENTRY: heartbeat, watchdog and sleep detector in ONE loop, because they
  # are one measurement. It OUTLIVES the body on purpose — a separate process the
  # body never consults, whose job is to end the group when the run is over.
  #
  #   · every TICK_SECS it stamps $LOCK/heartbeat (what the reclaim above reads)
  #     and appends the instant to $WORK/heartbeats;
  #   · THE CEILING IS COUNTED IN TICKS, NOT READ FROM THE CLOCK. `sleep 7200`
  #     was wall time: on 2026-09-21 the Mac slept 10:40-12:25 and the watchdog
  #     fired at wake, calling a run that had been AWAKE for 35 minutes HUNG. A
  #     tick that spanned a sleep counts as one tick, so the ceiling is awake time;
  #   · a gap of more than SLEEP_GAP_SECS between two of its own stamps IS the
  #     Mac having slept. The round that was running is a half round now — its
  #     `claude` was frozen, its agents' CI waits are stale — so the sentry ends
  #     the body at once and names the run INTERRUPTED. Finishing that round and
  #     auditing what it half-did is what produced today's false TEMPFIX.
  #
  # >/dev/null 2>&1 MATTERS: without it the subshell inherits the supervisor's
  # stdout and holds launchd's log handle open for its whole life.
  : > "$WORK/heartbeats"
  ( prev="$(date +%s)"; ticks=0; limit=$(( HARD_KILL_MIN * 60 / TICK_SECS ))
    # $BASHPID is bash 4; /bin/bash on macOS is 3.2. Ask a child for its parent.
    sh -c 'echo $PPID' > "$WORK/sentry-pid"
    while :; do
      sleep "$TICK_SECS"
      now="$(date +%s)"; ticks=$(( ticks + 1 ))
      date +%s > "$LOCK/heartbeat" 2>/dev/null || exit 0
      echo "$now" >> "$WORK/heartbeats"
      if [ $(( now - prev )) -gt "$SLEEP_GAP_SECS" ]; then
        echo "no heartbeat for $(( now - prev ))s, from $(at_time "$prev" +%H:%M:%S) to $(at_time "$now" +%H:%M:%S) — the Mac was asleep" > "$WORK/interrupted"
        kill -TERM "-$BODY" 2>/dev/null; sleep 20; kill -KILL "-$BODY" 2>/dev/null; exit 0
      fi
      prev="$now"
      if [ "$ticks" -ge "$limit" ]; then
        echo "$ticks ticks of ${TICK_SECS}s awake" > "$WORK/hung"
        kill -TERM "-$BODY" 2>/dev/null; sleep 20; kill -KILL "-$BODY" 2>/dev/null; exit 0
      fi
    done ) >/dev/null 2>&1 & SENTRY=$!

  wait "$BODY"; RC=$?
  # `disown` first so bash does not print "Terminated: 15" job notices into the
  # launchd log for a timer whose death is entirely expected.
  disown "$SENTRY" 2>/dev/null
  kill "$SENTRY" 2>/dev/null
  ELAPSED=$(( $(date +%s) - STARTED_AT ))
  ASLEEP="$(awk -v gap="$SLEEP_GAP_SECS" -v tick="$TICK_SECS" 'NR>1 && $1-p>gap {s+=$1-p-tick} {p=$1} END{print s+0}' "$WORK/heartbeats")"
  AWAKE=$(( ELAPSED - ASLEEP ))
  BODY_VERDICT="$(cat "$WORK/verdict" 2>/dev/null || echo "")"

  # Belt and braces for every path the sentry ended: anything that somehow
  # survived is reaped before the lock is released, so the next sweep never
  # inherits a live orphan holding files or agents open.
  if [ -f "$WORK/interrupted" ] && [ "$BODY_VERDICT" != "MAIN-GREEN" ]; then
    kill -KILL "-$BODY" 2>/dev/null
    say "=== INTERRUPTED: $(cat "$WORK/interrupted") (rc=$RC, ${ELAPSED}s wall, ${AWAKE}s awake) ==="
    say "--- parking anything the cut-off round left open ---"
    park_open_prs "the Mac slept mid-round ($(cat "$WORK/interrupted"))"
    conclude "MAIN-RED-INTERRUPTED" "the Mac slept during the sweep ($(cat "$WORK/interrupted")), so the round in flight was ended, not finished. Nothing it half-did counts as landed; its open PRs are parked. Main's state is UNVERIFIED — treat it as red. This is not a hang: the run was awake ${AWAKE}s of ${ELAPSED}s."
    release_lock
    exit 22
  fi

  if [ -f "$WORK/hung" ] || [ "$AWAKE" -ge $(( HARD_KILL_MIN * 60 )) ] || [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ]; then
    kill -KILL "-$BODY" 2>/dev/null
    say "=== HUNG: the sweep did not finish within ${HARD_KILL_MIN} awake minutes and was killed from outside (rc=$RC, ${AWAKE}s awake of ${ELAPSED}s) ==="
    say "--- parking anything the killed round left open ---"
    park_open_prs "the sweep hung and was killed at its ${HARD_KILL_MIN}-minute ceiling"
    conclude "MAIN-RED-HUNG" "the sweep was still running after ${HARD_KILL_MIN} awake minutes and was killed by its sentry. It did not reach a verdict, so main's state is UNVERIFIED — treat it as red. Its open PRs are parked. The last thing it logged is at the bottom of $RUN_LOG."
    release_lock
    exit 21
  fi

  # A precondition stop (no claude, no gh, not authenticated, keychain locked) exits
  # non-zero WITHOUT reaching finish(), so it would otherwise escalate to nobody.
  # These are the cases where the sweep could not run at all, which is exactly when
  # she needs telling — CI is unwatched until she acts. It is still an attempt:
  # the retry comes back in ~30 min in case the keychain has been unlocked since.
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 20 ]; then
    conclude "MAIN-UNKNOWN" "the sweep could not run at all (exit $RC) — see the NAMED STOP line in $RUN_LOG. Until this is cleared, nothing is watching CI; the sweep retries anyway."
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
CLAUDE="${CI_SWEEP_CLAUDE_BIN:-$(command -v claude || echo /opt/homebrew/bin/claude)}"
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

cd "$GITHUB_DIR" || { say "NAMED STOP [NO_GITHUB_DIR] $GITHUB_DIR"; exit 8; }

say "=== CI sweep starting ($STAMP) ==="
say "claude: $CLAUDE"
say "budget: ${MAX_ROUNDS} round(s) max, ${DEADLINE_MIN} min deadline (hard stop $(at_time "$DEADLINE_AT" +%H:%M))"
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
    say "  runs in flight; re-checking in 60s (until $(at_time "$until_ts" +%H:%M))"
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
  # The repos this run's agents are dispatched to — the scope of the audit and
  # of any parking. Written for the supervisor, which may have to park what a
  # round left open after the body is gone.
  printf '%s\n' "$RED_LINES" | cut -f2 | sort -u > "$WORK/red-repos"
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
    # A RETRY IS NOT A FIRST LOOK. If an earlier attempt today ended non-green,
    # its carryover — what it tried, what the audit rejected, what was parked —
    # is this round's opening brief, so the fresh session goes for a different
    # hypothesis instead of re-landing the PR that was just rejected. Consumed
    # here (moved into this run's work dir) so it cannot be fed twice.
    if [ -f "$NEXT_CARRY" ]; then
      mv "$NEXT_CARRY" "$WORK/carryover-from-previous-attempt.md"
      cat "$WORK/carryover-from-previous-attempt.md" > "$CARRY"
      say "round 1 is a RETRY: briefed with the previous attempt's carryover ($(wc -c < "$CARRY" | tr -d ' ') bytes)."
    fi
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

  # THE ROUND LOG FILLS AS THE ROUND RUNS, NOT AT ITS END. On 2026-09-20 both
  # rounds hit their caps and both round logs were 0 bytes: `claude -p` in text
  # mode prints only its final answer, and a process `timeout` kills has none.
  # So a capped round left no record of the PR it had landed, the second root
  # cause it had found, or the decision it was about to name - the only
  # transcript was ~/.claude/projects/*/<session>.jsonl. stream-json events are
  # flattened to text by ci-sweep-stream.py, line by line, flushed per line;
  # the sentinel is assistant text, so the grep below reads it unchanged.
  # `set -o pipefail` above makes $? the timeout's exit code, not the filter's.
  run_round() {
    timeout --signal=TERM --kill-after=60 "${CAP}m" \
      "$CLAUDE" -p "$ROUND_PROMPT" "$@" \
      --output-format stream-json --verbose \
      --dangerously-skip-permissions < /dev/null 2>&1 | python3 "$STREAM" > "$ROUND_LOG"
  }
  if [ "$round" -eq 1 ]; then
    SESSION_ID="$( (uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())') | tr 'A-Z' 'a-z')"
    echo "$SESSION_ID" > "$WORK/session-id"
    run_round --session-id "$SESSION_ID"
    RC=$?
  else
    SESSION_ID="$(cat "$WORK/session-id" 2>/dev/null || true)"
    ROUND_T0=$(date +%s)
    run_round --resume "$SESSION_ID"
    RC=$?
    # A resume that dies IMMEDIATELY is a broken handle, not a finished round.
    # Fall back to a fresh session rather than burn the round: the carryover
    # carries the context that the session would have.
    #
    # "Immediately" is measured, not inferred from an empty log. On 2026-09-20
    # the resume ran the full 25-minute cap (rc=124), left an empty log for the
    # reason above, and was read as a dead handle - so a SECOND 25-minute cap
    # was spent on a fresh session that could not see round 1's agent. A capped
    # round (124/137) is never a broken handle, and a handle that was alive for
    # more than RESUME_DEAD_SECS did not die on resume.
    RESUME_DEAD_SECS="${CI_SWEEP_RESUME_DEAD_SECS:-90}"
    ELAPSED=$(( $(date +%s) - ROUND_T0 ))
    if [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ] && [ "$RC" -ne 137 ] && [ "$ELAPSED" -le "$RESUME_DEAD_SECS" ] && ! grep -q '^\[tool\]\|^\[result' "$ROUND_LOG"; then
      say "resume of session $SESSION_ID died after ${ELAPSED}s with no tool call (rc=$RC); retrying this round as a fresh session."
      run_round
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
  # SCOPED TO THE REPOS THIS ROUND WAS DISPATCHED TO. The audit reads every PR in
  # the fleet updated in the window; on 2026-09-21 that was boss-os#33, a PR a
  # person's session touched while this round sat frozen in a Mac sleep, and the
  # sweep aborted with MAIN-RED-TEMPFIX over work that was never its own. A
  # weakening OUTSIDE the round's scope is still named — as SUSPECT, for a
  # person — but it is not this round cheating and does not end the attempt.
  CI_SWEEP_AUDIT_SINCE="$ROUND_START_UTC" CI_SWEEP_AUDIT_REPOS="$RED_REPOS" "$AUDIT" > "$WORK/audit-$round.txt" 2>&1
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
    3) # SUSPECT, not FATAL. The auditor could not prove a change either way, and
       # it has named the specific pull request. THE SWEEP CONTINUES.
       #
       # This branch exists because of 2026-09-09. The audit flagged
       # authority-backlink-network#99 for adding `if: always()` to a REPORTING
       # step, the sweep aborted at 10:57 with MAIN-RED-TEMPFIX, filed
       # west-peek-os#21 and discarded a whole morning's work. The finding was
       # false and was proven false: run 34371631703 ran on b2e1790 — the merge
       # commit carrying that exact `if: always()` — and still concluded FAILURE,
       # so it masks nothing.
       #
       # An unproven finding must cost the pull request it names, not the sweep.
       say "round $round audit: SUSPECT change(s) named above — NOT aborting."
       say "  These need a person's eye on the named PR. Discarding a whole sweep over an"
       say "  unproven finding is what happened on 2026-09-09, and it is not repeated here."
       SUSPECT_ROUNDS="${SUSPECT_ROUNDS:-}$round " ;;
    *) say "TEMP FIXES DETECTED IN ROUND $round — the sweep was reaching green by weakening something."
       say "  Ending this attempt rather than continuing to push an agent that is cheating;"
       say "  convergence pressure is exactly when this is most likely, so it is treated as fatal"
       say "  FOR THIS SESSION. It does not end the day: the offending PR is rejected on the PR"
       say "  itself (never merged, never closed by the sweep), and the next attempt is told what"
       say "  was rejected and why, so it goes for the root cause."
       reject_audited_prs "$WORK/audit-$round.txt" "$round"
       finish "MAIN-RED-TEMPFIX" "round $round weakened a test or a check in [$RED_REPOS] (see the audit section of $RUN_LOG). The PR is marked REJECTED and must not be merged; the next attempt is briefed with the rejection and tries the root cause instead. Rejected: $(awk -F'\t' '{printf "%s (%s); ", $1, $2}' "$WORK/rejected" 2>/dev/null)" ;;
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
