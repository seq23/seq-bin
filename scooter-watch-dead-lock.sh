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
    grep -vxF -f "$FIXLOCK/retry-ids" "$TAILED_FILE" > "$TAILED_FILE.tmp" || true
    mv "$TAILED_FILE.tmp" "$TAILED_FILE"
    cat "$FIXLOCK/retry-ids" >> "$RETRIED"
    N="$(wc -l < "$FIXLOCK/retry-ids" | tr -d ' ')"
  fi
fi
TOTAL="$( [ -s "$FIXLOCK/ids" ] && wc -l < "$FIXLOCK/ids" | tr -d ' ' || echo 0)"
echo "$NOW tail started $STARTED (pid ${PID:-none}) died with no exit or report — $N of $TOTAL email(s) re-queued for one retry" >> "$REPORT_LOG"
echo "[watch] DEAD_TAIL: the tail started $STARTED (pid ${PID:-none}) is gone with no exit — $N of $TOTAL email(s) re-queued"
rm -rf "$FIXLOCK"
exit 10
