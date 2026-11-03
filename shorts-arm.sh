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

# OWNER RULING 3 Nov 2026: Codex does the hands-on work, Claude only the brains. The arming is a
# Codex worker (`ai-run --role worker`) in how-we-know; the email to her goes out afterwards from a
# Claude brain run, because her Gmail is a claude.ai connector Codex cannot reach. A Codex limit
# WAITS (a named stop; tomorrow's 10:11 run retries) and is never handed to Claude.
AI_RUN="${SHORTS_ARM_AI_RUN_BIN:-$HOME/bin/ai-run}"
[ -x "$AI_RUN" ] || { say "NAMED STOP [NO_AI_RUN] $AI_RUN"; exit 4; }
REPO="$HOME/GitHub/how-we-know"
[ -f "$PROMPT_FILE" ] || { say "NAMED STOP [NO_PROMPT_FILE] $PROMPT_FILE"; exit 5; }

# Gmail here is a claude.ai connector, not a local MCP server — the brain run that
# emails her needs Claude signed in. A lapsed login would make the report silently
# never arrive, so it is checked before any work is done.
if ! security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  say "NAMED STOP [CLAUDE_NOT_AUTHENTICATED] cannot read credentials from the login keychain."
  say "  Mac may be at the login window with the keychain locked, or the session signed out."
  exit 10
fi

say "=== Shorts lane arming starting ==="
[ -d "$REPO" ] || { say "NAMED STOP [NO_REPO] $REPO"; exit 8; }

WORK_PROMPT="$(cat "$PROMPT_FILE")

## How this run is split (3 Nov 2026)
You are the hands-on worker. Do NOT send the email in the Notify section — you cannot reach her
Gmail. Write its body (under 150 words) as your final message, between a line holding only
NOTIFY-BEGIN and a line holding only NOTIFY-END, and then the required final line. The wrapper
has it emailed."
"$AI_RUN" --role worker --cwd "$REPO" --network --out "$RUN_LOG" -- "$WORK_PROMPT" < /dev/null > /dev/null 2>&1
RC=$?
say "=== worker exited rc=$RC ==="
if [ "$RC" -eq 75 ] || [ "$RC" -eq 69 ]; then
  say "$(grep -o 'NAMED STOP \[CODEX_[A-Z_]*\].*' "$RUN_LOG" | tail -1) — nothing was armed; the next 10:11 run retries. Never handed to Claude."
  ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
  exit 0
fi

# Line start only: `codex exec` echoes the prompt, whose sentinel templates are indented.
if ! grep -qE '^SHORTS-ARM-COMPLETE: (armed|deferred|failed|already-armed)' "$RUN_LOG"; then
  say "NAMED STOP [ARM_DID_NOT_COMPLETE] no sentinel in the log — the run started but never reached its end, so its silence is not evidence that the lane was not armed."
  exit 9
fi

STATE=$(grep -oE '^SHORTS-ARM-COMPLETE:.*' "$RUN_LOG" | tail -1)
say "sentinel: $STATE"

# The email to her: a brain run (Claude, her Gmail connector) sends exactly what the worker wrote.
BODY="$(awk '/^NOTIFY-BEGIN$/{b=""; f=1; next} /^NOTIFY-END$/{f=0; last=b} f{b=b $0 "\n"} END{printf "%s", last}' "$RUN_LOG")"
[ -n "$BODY" ] || BODY="The Shorts lane run ended $STATE but wrote no summary. Log: $RUN_LOG"
"$AI_RUN" --role brain --out "$RUN_LOG" -- "Send one email with the Gmail connector to seq.taylor@gmail.com, subject \`Shorts lane\`, with exactly this body and nothing else, then print SHORTS-ARM-EMAILED on its own line:

$BODY" < /dev/null > /dev/null 2>&1
grep -q '^SHORTS-ARM-EMAILED' "$RUN_LOG" && say "emailed her the result" || say "NAMED STOP [EMAIL_NOT_SENT] the brain run did not confirm the email; the result is in $RUN_LOG"
ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
exit $RC
