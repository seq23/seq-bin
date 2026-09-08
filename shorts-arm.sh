#!/bin/bash
# Arm the How We Know Shorts lane: check the cut inventory and make sure the
# evening publishing ladder has something to publish.
#
# NOTE 2026-09-05: this header used to be a verbatim copy of kdp-watch.sh's,
# so the file claimed to watch an Amazon KDP support case. The code was always
# correct; the description was not. A script that misdescribes itself is worse
# than one with no comment, because the comment is what someone reads before
# deciding whether it is safe to change.
#
# Runs under launchd, independent of any chat session. Same shape as ci-sweep.sh,
# including the lessons that cost real debugging there:
#   - completion is proven by a SENTINEL, not by output length (a quiet day is
#     a one-line answer and would trip a byte threshold)
#   - log filenames carry seconds AND pid, because two runs in the same minute
#     shared a file and the second inherited the first's sentinel
#
# RULE 0: this script may not exit 0 having done nothing. Either it checked and
# reported, or it exits non-zero with a named reason.

set -uo pipefail

PROMPT_FILE="${SHORTS_ARM_PROMPT:-$HOME/bin/shorts-arm-prompt.md}"
LOG_DIR="$HOME/Library/Logs/shorts-arm"
LOCK="$LOG_DIR/.lock"
RUN_LOG="$LOG_DIR/$(date +%Y-%m-%d-%H%M%S)-$$.log"

mkdir -p "$LOG_DIR"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }

if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -f "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then
    say "NAMED STOP [ALREADY_RUNNING] pid $(cat "$LOCK/pid")"; exit 0
  fi
  say "stale lock; reclaiming"; rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { say "FAILED to lock"; exit 3; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

CLAUDE="$(command -v claude || echo /opt/homebrew/bin/claude)"
[ -x "$CLAUDE" ] || { say "NAMED STOP [NO_CLAUDE_CLI] $CLAUDE"; exit 4; }
[ -f "$PROMPT_FILE" ] || { say "NAMED STOP [NO_PROMPT_FILE] $PROMPT_FILE"; exit 5; }

# Gmail here is a claude.ai connector, not a local MCP server. It was confirmed
# reachable from a headless run on 2026-09-02, but a lapsed login would make this
# job silently find "no reply" forever — which is indistinguishable from good news
# and is exactly the failure this watcher exists to avoid.
if ! security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  say "NAMED STOP [CLAUDE_NOT_AUTHENTICATED] cannot read credentials from the login keychain."
  say "  Mac may be at the login window with the keychain locked, or the session signed out."
  exit 10
fi

say "=== Shorts lane arming starting ==="
cd "$HOME" || { say "NAMED STOP [NO_HOME]"; exit 8; }

"$CLAUDE" -p "$(cat "$PROMPT_FILE")" --dangerously-skip-permissions >> "$RUN_LOG" 2>&1
RC=$?
say "=== claude exited rc=$RC ==="

if ! grep -q "SHORTS-ARM-COMPLETE:" "$RUN_LOG"; then
  say "NAMED STOP [ARM_DID_NOT_COMPLETE] no sentinel in the log — the run started but never reached its end, so its silence is not evidence that the lane was not armed."
  exit 9
fi

STATE=$(grep -o 'SHORTS-ARM-COMPLETE:.*' "$RUN_LOG" | tail -1)
say "sentinel: $STATE"
ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
exit $RC
