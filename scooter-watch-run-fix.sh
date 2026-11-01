#!/bin/bash
# Runs the partner-tail agent for one event, emails her the report, then releases the fix lock.
# Launched detached (nohup, disowned) by scooter-watch.sh so a long tail never blocks a tick.
#
# 6 Oct 2026: claude now runs as a background child whose PID is recorded in $FIXLOCK/claude_pid,
# because the watchdog used to kill THIS wrapper's PID and leave claude running orphaned. The
# watchdog kills claude; `wait` returns here; the report goes out either way (the watchdog writes
# an INCOMPLETE body into $REPORT_FILE before it kills). The lock is released here, last.
set -uo pipefail
PROMPT_FILE="$1" TAIL_LOG="$2" FIXLOCK="$3" CLAUDE="$4" REPORT_FILE="${5:-}" SUBJECT="${6:-}"
STATE_DIR="$(dirname "$TAIL_LOG")"
FIXLOG="$STATE_DIR/fix-log.md"
REPO="$HOME/GitHub/west-peek-os"
REPORT_LOG="$STATE_DIR/report.log"

"$CLAUDE" -p "$(cat "$PROMPT_FILE")" --model opus --output-format stream-json --verbose \
  >> "$TAIL_LOG" 2>&1 &
echo $! > "$FIXLOCK/claude_pid"
wait $! ; RC=$?
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) agent exited rc=$RC log=$TAIL_LOG" >> "$REPORT_LOG"

if [ -n "$REPORT_FILE" ]; then
  sleep 2   # let a watchdog kill finish writing its INCOMPLETE body
  if [ ! -s "$REPORT_FILE" ]; then
    {
      echo "${SUBJECT:-partner email}"
      echo
      echo "The tail agent exited (rc=$RC) without writing its report. Its last fix-log entry, if any:"
      echo
      awk '/^## /{n++} {if (n==c) print} /^## /{c=n}' "$FIXLOG" 2>/dev/null | tail -n 12
      echo
      echo "Tail log: $TAIL_LOG"
      echo "FRICTION_FIXED: 0"
    } > "$REPORT_FILE"
  fi
  N="$(grep -oE '^FRICTION_FIXED: *[0-9]+' "$REPORT_FILE" | tail -1 | grep -oE '[0-9]+' || true)"
  SUBJ="Partner tail: ${SUBJECT:-partner email} — ${N:-0} fixed"
  grep -q "INCOMPLETE" "$REPORT_FILE" && SUBJ="Partner tail: ${SUBJECT:-partner email} — INCOMPLETE (killed at the 2h cap)"
  if OUT="$(cd "$REPO" && node scripts/vault/vault.mjs run -- node "$HOME/bin/scooter-watch-report.mjs" "$REPORT_FILE" "$SUBJ" 2>&1)"; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $OUT" >> "$REPORT_LOG"
  else
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED to send $REPORT_FILE: $OUT" >> "$REPORT_LOG"
    /usr/bin/osascript -e "display notification \"Report email failed — see $REPORT_LOG\" with title \"Partner tail\" subtitle \"needs a look\" sound name \"Basso\"" >/dev/null 2>&1
  fi
fi

rm -rf "$FIXLOCK"
rm -f "$PROMPT_FILE"
