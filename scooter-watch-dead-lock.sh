#!/bin/bash
# Partner tail: a tail lock whose wrapper is gone, with no exit written, puts its emails back on the queue ONCE.
#
# Why (28 Nov 2026): the tail dispatched at 02:53Z (pid 79800) died with no "agent exited" line and no report.
# At the next dispatch (16:06Z) scooter-watch.sh removed its lock silently, so its two emails stayed marked tailed
# and Scooter's reply on the Productions preview (wc_59ef2d40) was never looked at. scooter-watch-run-fix.sh
# removes the lock itself on every normal end, so a lock naming a dead wrapper always means the wrapper was killed.
#
# Usage: scooter-watch-dead-lock.sh <fixlock dir> <state dir>
#   exit 0 = no lock, or a live wrapper (nothing done); exit 10 = a dead lock was recovered and removed.
FIXLOCK="$1" STATE_DIR="$2"
[ -d "$FIXLOCK" ] || exit 0
PID="$(cat "$FIXLOCK/pid" 2>/dev/null)"
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && exit 0
# The wrapper can die while its agent still works (reviewer note on #212): leave the lock until the agent is gone too,
# so the same email is never handed to a second agent. The watchdog's cap still stops a runaway agent.
CPID="$(cat "$FIXLOCK/claude_pid" 2>/dev/null)"
[ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null && exit 0

REPORT_LOG="$STATE_DIR/report.log"
TAILED_FILE="$STATE_DIR/tailed-message-ids.txt"; RETRIED="$STATE_DIR/retried-message-ids.txt"
touch "$RETRIED" "$TAILED_FILE"
STARTED="$(cat "$FIXLOCK/started_at" 2>/dev/null || echo unknown)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
N=0
if [ -s "$FIXLOCK/ids" ]; then
  NEW_IDS="$(grep -vxF -f "$RETRIED" "$FIXLOCK/ids" || true)"
  if [ -n "$NEW_IDS" ]; then
    printf '%s\n' "$NEW_IDS" > "$FIXLOCK/retry-ids"
    # grep exits 1 when every line was removed (a valid empty list) and 2 on an error: only 0/1 replace the list,
    # so a read error never wipes the record of emails already tailed.
    grep -vxF -f "$FIXLOCK/retry-ids" "$TAILED_FILE" > "$TAILED_FILE.tmp"; G=$?
    if [ "$G" -le 1 ]; then mv "$TAILED_FILE.tmp" "$TAILED_FILE"; else rm -f "$TAILED_FILE.tmp"; NEW_IDS=""; fi
    if [ -n "$NEW_IDS" ]; then cat "$FIXLOCK/retry-ids" >> "$RETRIED"; N="$(wc -l < "$FIXLOCK/retry-ids" | tr -d ' ')"; fi
  fi
fi
TOTAL="$( [ -s "$FIXLOCK/ids" ] && wc -l < "$FIXLOCK/ids" | tr -d ' ' || echo 0)"
echo "$NOW tail started $STARTED (pid ${PID:-none}) died with no exit or report — $N of $TOTAL email(s) re-queued for one retry" >> "$REPORT_LOG"
echo "[watch] DEAD_TAIL: the tail started $STARTED (pid ${PID:-none}) is gone with no exit — $N of $TOTAL email(s) re-queued"
# A second death of the same email is not retried again, so she is told by email (reviewer note on #212).
if [ "$N" -lt "$TOTAL" ]; then
  REPORT_FILE="$STATE_DIR/report-dead-$(date -u +%Y%m%dT%H%M%SZ).txt"
  { echo "Partner tail died twice"; echo
    echo "The tail started $STARTED died with no exit or report, and $((TOTAL - N)) of its $TOTAL email(s) had already been retried once."
    echo "They are not retried again. Their message ids:"; grep -xF -f "$RETRIED" "$FIXLOCK/ids" | sed 's/^/  /'
    echo; echo "FRICTION_FIXED: 0"; } > "$REPORT_FILE"
  SEND="${SCOOTER_WATCH_REPORT_SEND:-$HOME/bin/scooter-watch-report.mjs}"
  if (cd "${SCOOTER_WATCH_REPO:-$HOME/GitHub/west-peek-os}" && node scripts/vault/vault.mjs run -- node "$SEND" "$REPORT_FILE" "Partner tail: died twice — $((TOTAL - N)) email(s) not retried") >/dev/null 2>&1; then
    echo "$NOW dead-tail email sent ($REPORT_FILE)" >> "$REPORT_LOG"
  else
    echo "$NOW DEAD_TAIL_EMAIL_FAILED ($REPORT_FILE)" >> "$REPORT_LOG"
  fi
fi
rm -rf "$FIXLOCK"
exit 10
