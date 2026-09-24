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
#   no run recorded for today yet  -> run (the 07:00 slot was missed or is
#                                     still starting up; ci-sweep.sh's own
#                                     lock makes a second concurrent run a
#                                     safe no-op, so it's never wrong to try)
#   today already has a GREEN run  -> nothing to do, exit 0
#   today has exactly one non-green run -> this is the one retry: run
#   today already has 2+ runs      -> the retry already happened; exit 0
#
# RULE 0: a day with nothing to do is a named, logged stop — not silence.
set -uo pipefail

LOG_DIR="${CI_SWEEP_LOG_DIR:-$HOME/Library/Logs/ci-sweep}"
LEDGER="$LOG_DIR/state/outcomes.tsv"
SWEEP="${CI_SWEEP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-sweep.sh}"
GATE_LOG="$LOG_DIR/retry-gate.log"
mkdir -p "$LOG_DIR"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$GATE_LOG"; }

TODAY="$(date +%Y-%m-%d)"
rows=""
[ -f "$LEDGER" ] && rows="$(awk -F'\t' -v d="$TODAY" '$2==d' "$LEDGER")"
count=0; [ -n "$rows" ] && count="$(printf '%s\n' "$rows" | grep -c .)"

if [ "$count" -eq 0 ]; then
  say "no run recorded for $TODAY yet — running (07:00 slot missed, or still in flight; ci-sweep.sh's own lock makes this safe either way)."
elif printf '%s\n' "$rows" | awk -F'\t' '$3=="MAIN-GREEN"{f=1} END{exit !f}'; then
  say "$TODAY already has a MAIN-GREEN run — nothing to retry. Exiting."
  exit 0
elif [ "$count" -ge 2 ]; then
  say "$TODAY already has $count runs (the retry already happened, still not green) — waiting for tomorrow's 07:00 run. Exiting."
  exit 0
else
  say "$TODAY's only run so far was not green — this is the one retry. Running."
fi

exec "$SWEEP"
