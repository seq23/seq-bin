#!/bin/bash
# Outer safety cap on a partner-tail agent. Sleeps CAP_SECONDS; if the agent is still alive after
# that, writes the INCOMPLETE report body (so scooter-watch-run-fix.sh emails it to her), kills
# the agent, appends a NAMED failure to the fix log (never silent), and files/comments a durable
# GitHub issue in west-peek-os — a macOS banner alone disappears and does nothing if she's away.
# If the agent already finished (fix lock gone), this is a no-op.
#
# 13 Nov 2026: the lock is one shared directory, so a watchdog whose own agent finished long ago
# woke at its 2 h mark, found the NEXT agent's lock, and killed that agent 15 minutes into its
# work (twice in one morning, each logged as "did not finish within 120 minutes"). A watchdog now
# acts only while the lock still names the wrapper it was started for ($FIXLOCK/pid).
#
# 6 Oct 2026: kills claude's own PID ($FIXLOCK/claude_pid), not the wrapper's — killing the
# wrapper left claude running orphaned. The wrapper's `wait` returns on the kill and it sends the
# report and releases the lock; the lock is only removed here if the wrapper itself is gone.
set -uo pipefail
WRAPPER_PID="$1" CAP_SECONDS="$2" FIXLOCK="$3" FIXLOG="$4" TAIL_LOG="$5" REPORT_FILE="${6:-}" SUBJECT="${7:-}"
GH_REPO="${SCOOTER_WATCH_GH_REPO:-seq23/west-peek-os}"
OSA="${SCOOTER_WATCH_OSASCRIPT:-/usr/bin/osascript}"
mine() { [ -d "$FIXLOCK" ] && [ "$(cat "$FIXLOCK/pid" 2>/dev/null)" = "$WRAPPER_PID" ]; }

sleep "$CAP_SECONDS"

mine || exit 0   # no lock, or a later agent's lock: not this watchdog's to touch
AGENT_PID="$(cat "$FIXLOCK/claude_pid" 2>/dev/null || echo "$WRAPPER_PID")"

if kill -0 "$AGENT_PID" 2>/dev/null; then
  CAP_MIN=$((CAP_SECONDS/60))
  WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ENTRY="## $WHEN — INCOMPLETE (killed at ${CAP_MIN}min cap)
- **Partner's email:** ${SUBJECT:-see tail log}
- **What happened:** the tail/fix agent did not finish within ${CAP_MIN} minutes and was killed.
- **Needs:** a human look — read $TAIL_LOG for where it got stuck (mid-diagnosis vs. mid-fix), then re-run by hand."
  { echo; echo "$ENTRY"; } >> "$FIXLOG"
  if [ -n "$REPORT_FILE" ] && [ ! -s "$REPORT_FILE" ]; then
    { echo "${SUBJECT:-partner email}"; echo; echo "$ENTRY"; echo; echo "FRICTION_FIXED: 0"; } > "$REPORT_FILE"
  fi

  kill "$AGENT_PID" 2>/dev/null
  sleep 2
  kill -9 "$AGENT_PID" 2>/dev/null

  "$OSA" -e "display notification \"Tail agent ran ${CAP_MIN}min without finishing — killed, see fix-log.md\" with title \"Partner tail\" subtitle \"needs a look\" sound name \"Basso\"" \
    >/dev/null 2>&1

  TITLE="[partner-tail] agent killed at ${CAP_MIN}min cap — $(date -u +%Y-%m-%d)"
  BODY="**A partner-tail agent ran ${CAP_MIN} minutes without finishing and was killed.**

**When:** $WHEN
**Partner's email:** ${SUBJECT:-see tail log}
**Tail log:** \`$TAIL_LOG\`
**Fix log entry:** \`$FIXLOG\`

It was mid-diagnosis or mid-fix on a work card opened or steered by the partner's mail — read the tail log to see which, and where it got stuck, then re-run by hand. Nothing it half-did was landed unverified (fixes only merge after the repo's own tests/validators pass), but the card itself is unresolved.

Filed by \`~/bin/scooter-watch-watchdog.sh\`."

  gh label create partner-tail --repo "$GH_REPO" --color 7057ff --description "Friction found by the partner tail" --force >/dev/null 2>&1
  EXISTING="$(gh issue list --repo "$GH_REPO" --state open --search "$TITLE in:title" \
              --json number,title --jq ".[]|select(.title==\"$TITLE\")|.number" 2>/dev/null | head -1)"
  if [ -n "$EXISTING" ]; then
    gh issue comment "$EXISTING" --repo "$GH_REPO" --body "$BODY" >/dev/null 2>&1 \
      && echo "[watchdog] commented on $GH_REPO#$EXISTING" >> "$FIXLOG.alerts.log" \
      || echo "[watchdog] FAILED to comment on $GH_REPO#$EXISTING" >> "$FIXLOG.alerts.log"
  else
    if URL="$(gh issue create --repo "$GH_REPO" --label partner-tail --title "$TITLE" --body "$BODY" 2>&1)"; then
      echo "[watchdog] filed $URL" >> "$FIXLOG.alerts.log"
    else
      echo "[watchdog] FAILED to file GitHub issue: $URL" >> "$FIXLOG.alerts.log"
      "$OSA" -e "display alert \"partner-tail: could not file the 2h-cap GitHub issue\" message \"gh issue create failed — check $FIXLOG.alerts.log\"" \
        >/dev/null 2>&1
    fi
  fi
fi

# The wrapper releases the lock after it emails the report; only clean up if the wrapper is gone.
sleep "${SCOOTER_WATCH_WATCHDOG_GRACE:-30}"
mine || exit 0
kill -0 "$WRAPPER_PID" 2>/dev/null || rm -rf "$FIXLOCK"
