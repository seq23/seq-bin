#!/bin/bash
# Runs the partner-tail agent for one event, emails her the report, then releases the fix lock.
# Launched detached (nohup, disowned) by scooter-watch.sh so a long tail never blocks a tick.
#
# 3 Nov 2026 (owner ruling: Codex does the hands-on work, Claude only the brains): the agent is
# `~/bin/ai-run --role worker` (Codex) in west-peek-os with network on; the state dir is writable to
# it for the report and fix-log. Its pid goes in $FIXLOCK/claude_pid (the name the watchdog reads);
# ai-run passes a kill on to Codex. A Codex limit (exit 75) or a Codex that cannot run (69) WAITS:
# the events are un-tailed so a later tick retries them, $STATE_DIR/codex-wait pauses dispatch for
# an hour at a time, and she gets ONE email for the wait — never a Claude fallback.
#
# 6 Oct 2026: claude now runs as a background child whose PID is recorded in $FIXLOCK/claude_pid,
# because the watchdog used to kill THIS wrapper's PID and leave claude running orphaned. The
# watchdog kills claude; `wait` returns here; the report goes out either way (the watchdog writes
# an INCOMPLETE body into $REPORT_FILE before it kills). The lock is released here, last.
set -uo pipefail
PROMPT_FILE="$1" TAIL_LOG="$2" FIXLOCK="$3" AI_RUN="$4" REPORT_FILE="${5:-}" SUBJECT="${6:-}"
STATE_DIR="$(dirname "$TAIL_LOG")"
FIXLOG="$STATE_DIR/fix-log.md"
REPO="$HOME/GitHub/west-peek-os"
REPORT_LOG="$STATE_DIR/report.log"

# 6 Nov 2026, her words: "A partner tail is a Claude Job" — the tail runs on Claude, never Codex.
AI_RUN_WORKER=claude AI_RUN_ADD_DIRS="$STATE_DIR" AI_RUN_CALLER="scooter-watch-run-fix.sh" \
  "$AI_RUN" --role worker --cwd "$REPO" --network --out "$TAIL_LOG" -- "$(cat "$PROMPT_FILE")" \
  < /dev/null > /dev/null 2>&1 &
echo $! > "$FIXLOCK/claude_pid"
wait $! ; RC=$?
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) agent exited rc=$RC log=$TAIL_LOG" >> "$REPORT_LOG"

CODEX_WAIT="$STATE_DIR/codex-wait"
if [ "$RC" -eq 75 ] || [ "$RC" -eq 69 ]; then
  STOPLINE="$(grep -o 'NAMED STOP \[[A-Z_]*\].*' "$TAIL_LOG" | tail -1)"
  [ -n "$STOPLINE" ] || STOPLINE="NAMED STOP [CODEX_UNAVAILABLE] ai-run exited $RC"
  FIRST_WAIT=1; [ -f "$CODEX_WAIT" ] && FIRST_WAIT=0
  echo "$STOPLINE" > "$CODEX_WAIT"
  TAILED_FILE="$STATE_DIR/tailed-message-ids.txt"
  if [ -s "$FIXLOCK/ids" ] && [ -f "$TAILED_FILE" ]; then
    grep -vxF -f "$FIXLOCK/ids" "$TAILED_FILE" > "$TAILED_FILE.tmp"; mv "$TAILED_FILE.tmp" "$TAILED_FILE"
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $STOPLINE — events re-queued; dispatch waits" >> "$REPORT_LOG"
  if [ "$FIRST_WAIT" -eq 1 ] && [ -n "$REPORT_FILE" ]; then
    { echo "${SUBJECT:-partner email}"; echo
      echo "WAITING: Codex could not take this tail — $STOPLINE."
      echo "Nothing was changed. The email stays queued and is tailed automatically once Codex is back;"
      echo "it is never handed to Claude. You hear from me again only with the real report."
      echo; echo "FRICTION_FIXED: 0"; } > "$REPORT_FILE"
  else
    REPORT_FILE=""   # told once already; the real report follows when Codex is back
  fi
else
  rm -f "$CODEX_WAIT"
fi

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
  grep -q "^WAITING: Codex" "$REPORT_FILE" && SUBJ="Partner tail: ${SUBJECT:-partner email} — waiting for Codex"
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
