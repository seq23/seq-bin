#!/bin/bash
# CI sweep resume-on-wake — fired every 300 s by launchd (launchd/com.seq.ci-sweep-resume.plist).
#
# THE DESIGN (owner, 12 Oct 2026: "can we change everything so that it just picks up
# where it left off if I close the lid and then re-open?"). The sweep runs Monday and
# Friday at 08:00 CT (com.seq.ci-sweep) with one 09:00 retry if not green
# (com.seq.ci-sweep-retry -> ci-sweep-retry-if-red.sh). When the lid closes mid-run, the
# supervisor's sentry sees the heartbeat gap at wake and ends the run as
# MAIN-RED-INTERRUPTED (12 Oct 2026, 08:04 run: "no heartbeat for 627s, from 08:20:36 to
# 08:31:03"). Until today that was final. Now an INTERRUPTED run is RESUMABLE while its
# budget has room, and this script is what resumes it.
#
# WHY A 300 s TICK, NOT A WAKE HOOK: macOS has no wake event a launchd agent can key on
# without a new dependency (sleepwatcher is not installed and is not added). A tick that
# decides in under a second costs nothing, and the first tick after wake does the work.
#
# LOGIC (reads only, decides, then either execs ci-sweep.sh or exits 0 with one line in
# ~/Library/Logs/ci-sweep/resume.log, kept to the last RESUME_LOG_KEEP lines):
#   a sweep is running (live lock holder)      -> no-op: it is working, or its sentry is
#                                                 about to record the interruption. The
#                                                 holder/heartbeat judgement itself stays in
#                                                 ci-sweep.sh's lock, which also guards
#                                                 the exec below.
#   no run recorded today                      -> no-op
#   today's latest row is not INTERRUPTED      -> no-op (GREEN/PENDING are answers, KILLED is
#                                                 a signal from outside, HUNG a fault — none
#                                                 is a sleep; conclude() in ci-sweep.sh writes
#                                                 INTERRUPTED only for a sentry sleep gap)
#   fewer than RESUME_MIN_LEFT_MIN minutes before the run's stop-by
#                                              -> no-op: left INTERRUPTED; the 09:00 retry
#                                                 (or the next Mon/Fri 08:00 run) applies
#   the 240-awake-minute ceiling nearly spent  -> no-op, same
#   otherwise                                  -> exec ci-sweep.sh as a RESUME of that run:
#                                                 same ledger row, same stop-by, same claude
#                                                 session, the awake time already spent
#                                                 counted against the hard kill.
# The resumed run REPLACES the interrupted row (fifth column resumed-by=<run-id>), so the
# 09:00 gate still counts one attempt and keeps its own one-retry rule.
#
# RULE 0: every tick leaves one line saying what it decided and why.
set -uo pipefail

LOG_DIR="${CI_SWEEP_LOG_DIR:-$HOME/Library/Logs/ci-sweep}"
LEDGER="$LOG_DIR/state/outcomes.tsv"
LOCK="$LOG_DIR/.lock"
SWEEP="${CI_SWEEP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-sweep.sh}"
RESUME_LOG="$LOG_DIR/resume.log"
RESUME_LOG_KEEP="${CI_SWEEP_RESUME_LOG_KEEP:-1000}"
# The same limits ci-sweep.sh enforces; resumption never extends either.
DEADLINE_MIN="${CI_SWEEP_DEADLINE_MIN:-210}"
HARD_KILL_MIN="${CI_SWEEP_HARD_KILL_MIN:-240}"
TICK_SECS="${CI_SWEEP_TICK_SECS:-20}"
# Less than this left is not worth a resume: one round, a verify and a merge pass.
RESUME_MIN_LEFT_MIN="${CI_SWEEP_RESUME_MIN_LEFT_MIN:-20}"
mkdir -p "$LOG_DIR"

# One line per tick to resume.log (bounded below). Under launchd (XPC_SERVICE_NAME is the
# job label) stdout is resume-launchd.log, which nothing trims, so the line goes only to
# resume.log there; by hand it is echoed too.
say() {
  local line; line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" >> "$RESUME_LOG"
  [ "${XPC_SERVICE_NAME:-}" = "com.seq.ci-sweep-resume" ] || echo "$line"
  if [ "$(wc -l < "$RESUME_LOG")" -gt "$RESUME_LOG_KEEP" ]; then
    tail -n "$RESUME_LOG_KEEP" "$RESUME_LOG" > "$RESUME_LOG.tmp.$$" && mv "$RESUME_LOG.tmp.$$" "$RESUME_LOG"
  fi
}
holder_pid() { local p; p="$(cat "$LOCK/pid" 2>/dev/null || echo)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; }
# "YYYY-MM-DD HH:MM[:SS]" -> epoch, BSD date or GNU date (the tests run on both).
to_epoch() {
  local t="$1"; [ "${#t}" -eq 16 ] && t="$t:00"
  date -j -f '%Y-%m-%d %H:%M:%S' "$t" +%s 2>/dev/null || date -d "$t" +%s 2>/dev/null
}
hm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M; }

if holder="$(holder_pid)"; then
  say "no-op: a sweep is running (pid $holder, $(cat "$LOCK/run-id" 2>/dev/null || echo '?')) — nothing to resume while it holds the lock."
  exit 0
fi

TODAY="$(date +%Y-%m-%d)"
latest=""
# File order is time order: record_outcome rewrites a run's row at the end of the ledger.
[ -f "$LEDGER" ] && latest="$(awk -F'\t' -v d="$TODAY" '$2==d' "$LEDGER" | tail -1)"
if [ -z "$latest" ]; then
  say "no-op: no sweep run recorded for $TODAY."
  exit 0
fi
verdict="$(printf '%s' "$latest" | cut -f3)"
ledger_id="$(printf '%s' "$latest" | cut -f4)"
attempt="$(printf '%s' "$latest" | cut -f5 | sed -n 's/^resumed-by=//p')"
[ -z "$attempt" ] && attempt="$ledger_id"
if [ "$verdict" != "MAIN-RED-INTERRUPTED" ]; then
  say "no-op: today's latest run $ledger_id ended $verdict — not a sleep interruption, nothing to resume."
  exit 0
fi

# The stop-by time: the attempt's own "stop by HH:MM" line (a resumed attempt prints the
# original's), else its started-at, else the epoch in its run id (YYYY-MM-DD-HHMMSS-pid).
ATTEMPT_LOG="$LOG_DIR/$attempt.log"; ATTEMPT_WORK="$LOG_DIR/$attempt.d"
stop_by=""
sb="$(grep -oE 'stop by [0-9]{2}:[0-9]{2}' "$ATTEMPT_LOG" 2>/dev/null | tail -1 | sed 's/stop by //')"
[ -n "$sb" ] && stop_by="$(to_epoch "$TODAY $sb")"
if [ -z "$stop_by" ] && [ -s "$ATTEMPT_WORK/started-at" ]; then
  stop_by=$(( $(cat "$ATTEMPT_WORK/started-at") + DEADLINE_MIN * 60 ))
fi
if [ -z "$stop_by" ] && printf '%s' "$ledger_id" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}'; then
  s="$(printf '%s' "$ledger_id" | sed -E 's/^([0-9-]{10})-([0-9]{2})([0-9]{2})([0-9]{2}).*/\1 \2:\3:\4/')"
  st="$(to_epoch "$s")"; [ -n "$st" ] && stop_by=$(( st + DEADLINE_MIN * 60 ))
fi
if [ -z "$stop_by" ]; then
  say "no-op: $ledger_id is INTERRUPTED but its stop-by time cannot be read ($ATTEMPT_LOG) — left for the 09:00 retry."
  exit 0
fi
now="$(date +%s)"
left_min=$(( (stop_by - now) / 60 ))
if [ "$left_min" -lt "$RESUME_MIN_LEFT_MIN" ]; then
  say "no-op: $ledger_id is INTERRUPTED but its budget ends at $(hm "$stop_by") (${left_min} min left, under ${RESUME_MIN_LEFT_MIN}) — left INTERRUPTED; the 09:00 retry or the next Mon/Fri 08:00 run applies."
  exit 0
fi

# Awake time already spent: one sentry heartbeat per TICK_SECS awake, plus what any
# earlier resume of the same attempt carried in.
beats="$(grep -c . "$ATTEMPT_WORK/heartbeats" 2>/dev/null)"; beats="${beats:-0}"
prior="$(cat "$ATTEMPT_WORK/prior-awake-secs" 2>/dev/null || echo 0)"
awake=$(( beats * TICK_SECS + prior ))
if [ $(( HARD_KILL_MIN * 60 - awake )) -lt $(( RESUME_MIN_LEFT_MIN * 60 )) ]; then
  say "no-op: $ledger_id is INTERRUPTED but has spent ${awake}s awake of its ${HARD_KILL_MIN}-minute ceiling — left INTERRUPTED."
  exit 0
fi

started=$(( stop_by - DEADLINE_MIN * 60 ))
if [ -n "${CI_SWEEP_RESUME_DRY_RUN:-}" ]; then
  say "dry-run: would resume $ledger_id (attempt $attempt): ${left_min} min left to stop-by $(hm "$stop_by"), ${awake}s awake spent."
  exit 0
fi
say "RESUMING $ledger_id (attempt $attempt) after sleep: ${left_min} min left to stop-by $(hm "$stop_by"), ${awake}s of ${HARD_KILL_MIN} awake min spent."
exec env CI_SWEEP_RESUME_FROM="$attempt" CI_SWEEP_LEDGER_ID="$ledger_id" \
  CI_SWEEP_STARTED_AT="$started" CI_SWEEP_PRIOR_AWAKE_SECS="$awake" "$SWEEP"
