#!/bin/bash
# CI sweep retry gate — fired once a day at 08:00 CT by launchd
# (launchd/com.seq.ci-sweep-retry.plist), exactly one hour after the primary
# 07:00 run (launchd/com.seq.ci-sweep.plist, com.seq.ci-sweep.sh).
#
# THE DESIGN (her instruction, 24 Sep 2026): if the 07:00 run does not end
# MAIN-GREEN, try again once, an hour later. Not more than once — a second
# non-green ending still waits for tomorrow's 07:00 run.
#
# WHY A SEPARATE SCRIPT RATHER THAN A RETRY LOOP INSIDE ci-sweep.sh: the
# ledger (state/outcomes.tsv, one line per run) is already the source of
# truth for what ran today and how it ended, so the cap-at-one-retry rule is
# a read of that ledger, not new state. Keeping it out of ci-sweep.sh also
# means the primary script's own "one run a day, no self-retry" contract
# (tests/test-sweep-daily.sh's no_retry_anywhere checks) stays exactly what
# it says: ci-sweep.sh never retries itself. The retry is layered on from
# outside, the same way the supervisor bounds the body from outside.
#
# LOGIC (reads only, decides, then either execs ci-sweep.sh or exits 0):
#   no run recorded for today yet, and a sweep is IN FLIGHT (live lock holder)
#                                  -> WAIT for it, one bounded wait, then decide
#                                     from its row (26 Sep 2026: the 07:00 run was
#                                     in round 2 at 08:00, the gate ran the sweep,
#                                     the lock no-oped it, and the day had no retry
#                                     however the 07:00 run ended). The wait ends at
#                                     the holder's own ceiling; a holder still alive
#                                     past it is handed to ci-sweep.sh, whose lock
#                                     reclaims it and records MAIN-RED-RECLAIMED.
#   no run recorded, nothing in flight -> run (the 07:00 slot was missed, or the run
#                                     died without a row — ci-sweep.sh's reclaim
#                                     writes that row)
#   today already has a GREEN run  -> nothing to do, exit 0
#   today has a PAUSED run         -> the owner paused the sweep (state/pause-until,
#                                     26 Sep 2026); terminal for the day, exit 0
#   today has exactly one non-green run -> this is the one retry: run
#   today already has 2+ runs      -> the retry already happened; exit 0
#
# RULE 0: a day with nothing to do is a named, logged stop — not silence.
set -uo pipefail

LOG_DIR="${CI_SWEEP_LOG_DIR:-$HOME/Library/Logs/ci-sweep}"
LEDGER="$LOG_DIR/state/outcomes.tsv"
LOCK="$LOG_DIR/.lock"
SWEEP="${CI_SWEEP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-sweep.sh}"
GATE_LOG="$LOG_DIR/retry-gate.log"
# How long to wait for an in-flight run: its hard kill (240 awake min) plus the
# lock's 5-minute reclaim margin, counted from when it started.
HARD_KILL_MIN="${CI_SWEEP_HARD_KILL_MIN:-240}"
WAIT_POLL_SECS="${CI_SWEEP_RETRY_POLL_SECS:-30}"
mkdir -p "$LOG_DIR"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$GATE_LOG"; }
holder_pid() { local p; p="$(cat "$LOCK/pid" 2>/dev/null || echo)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; }

TODAY="$(date +%Y-%m-%d)"
read_rows() {
  rows=""
  [ -f "$LEDGER" ] && rows="$(awk -F'\t' -v d="$TODAY" '$2==d' "$LEDGER")"
  count=0; [ -n "$rows" ] && count="$(printf '%s\n' "$rows" | grep -c .)"
}
read_rows

if [ "$count" -eq 0 ] && holder="$(holder_pid)"; then
  started="$(cat "$LOCK/started" 2>/dev/null || date +%s)"
  deadline="${CI_SWEEP_RETRY_WAIT_UNTIL:-$(( started + HARD_KILL_MIN * 60 + 300 ))}"
  say "no run recorded for $TODAY yet, and pid $holder ($(cat "$LOCK/run-id" 2>/dev/null || echo '?')) is in flight — waiting for its verdict (until $(date -r "$deadline" +%H:%M 2>/dev/null || date -d "@$deadline" +%H:%M))."
  while [ -n "$(holder_pid)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep "$WAIT_POLL_SECS"; done
  if holder="$(holder_pid)"; then
    say "pid $holder is still running past its ceiling — handing it to ci-sweep.sh, whose lock reclaims it and records MAIN-RED-RECLAIMED."
    exec "$SWEEP"
  fi
  read_rows
  say "the in-flight run ended; $TODAY now has $count run(s) recorded: $(printf '%s\n' "$rows" | cut -f3 | tr '\n' ' ')"
fi

if [ "$count" -eq 0 ]; then
  say "no run recorded for $TODAY and none in flight — running (the 07:00 slot was missed, or its run died without a row; ci-sweep.sh records that one)."
elif printf '%s\n' "$rows" | awk -F'\t' '$3=="MAIN-GREEN"{f=1} END{exit !f}'; then
  say "$TODAY already has a MAIN-GREEN run — nothing to retry. Exiting."
  exit 0
elif printf '%s\n' "$rows" | awk -F'\t' '$3=="PAUSED"{f=1} END{exit !f}'; then
  say "$TODAY's run was PAUSED by the owner (state/pause-until) — terminal for the day, no retry. Exiting."
  exit 0
elif [ "$count" -ge 2 ]; then
  say "$TODAY already has $count runs (the retry already happened, still not green) — waiting for tomorrow's 07:00 run. Exiting."
  exit 0
else
  say "$TODAY's only run so far was not green — this is the one retry. Running."
fi

exec "$SWEEP"
