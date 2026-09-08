#!/bin/bash
# Tell HER. Called by ci-sweep.sh for every outcome that needs a person.
#
# WHY THIS EXISTS
# Until 2026-09-08 the only record of a sweep was ~/Library/Logs/ci-sweep/latest.log,
# which is not a place she goes. So a red night and a green night looked exactly
# the same unless she went looking — the same defect as a sweep reporting success
# over a red lane, moved one layer out. Her words: "if there is a block it should
# exit and let me know some kind of way that i need to do something."
#
# WHY THESE TWO CHANNELS
# · macOS notification — immediate, lands while she is at the machine. Transient,
#   so it cannot be the only one.
# · GitHub issue — durable, and GitHub emails her, so it survives a closed laptop
#   and is still there tomorrow. `gh` is already a hard precondition of the sweep,
#   so this adds no new credential and no new failure mode.
#
# WHY NOT BOSS OS, which would have been the best place
# Today is the screen she opens every morning, and its Critical Alerts are exactly
# the right shape. But the alert list in routes/today.ts is assembled entirely from
# computed sources, and `owned_deliverables` — the mechanism that escalates and
# gets louder with age — HAS NO CREATE ROUTE. Rows are inserted by migration only;
# POST /api/boss/deliverables/:id can change the state of a row that already
# exists, and nothing else. Putting a CI escalation on Today therefore requires a
# new migration plus a TERMINAL_CHECKS entry IN THE BOSS-OS REPO, and another agent
# is working in that repo right now. POST /api/boss/tasks would take an arbitrary
# item, but it creates a task, not a Critical Alert, and it needs BOSS_PASSCODE
# injected by `npm run vault:run` from inside that same repo — coupling this
# scheduled job to a codebase under active edit for a weaker signal than an email.
#
# THIS IS THE HONEST STOP, NOT A SHRUG: when boss-os is free, the durable channel
# should move to a seeded owned_deliverable, because it escalates with age and this
# does not. Recorded here so the next person does not have to re-derive it.
#
# A GREEN SWEEP CALLS THIS SCRIPT NOT AT ALL. A notification that fires every day
# is one she learns to ignore, and then the red ones stop landing too.

set -uo pipefail

# `${1-}` not `${1:-...}`: an EMPTY first argument must reach the refusal below.
# With a default substituted for empty as well as unset, the "refuse to escalate
# nothing" guard was unreachable — it would have quietly escalated a blank verdict
# as MAIN-UNKNOWN, which is a validator passing on an empty input set wearing a
# different hat. Caught by its own negative proof.
VERDICT="${1-}"
DETAIL="${2:-}"
RUN_LOG="${3:-}"
ISSUE_REPO_FALLBACK="${CI_SWEEP_ISSUE_REPO:-seq23/west-peek-os}"
# Test seam: print what WOULD be sent instead of sending it, so the message can be
# proven correct without filing issues at her or firing banners.
DRY="${CI_SWEEP_NOTIFY_DRY:-}"

# --- refuse to escalate nothing ----------------------------------------------
# RULE 0. An escalation with no verdict is noise, and noise is how a channel dies.
case "$VERDICT" in
  MAIN-GREEN) echo "[notify] MAIN-GREEN does not notify — a daily alert is an ignored alert."; exit 0 ;;
  "") echo "[notify] NAMED STOP [NO_VERDICT] refusing to escalate without one."; exit 2 ;;
esac

# --- what she should DO ------------------------------------------------------
# "Something failed" is not actionable. Every branch below names the ONE next
# action, because an escalation she cannot act on is one she learns to close.
case "$VERDICT" in
  MAIN-RED-STUCK)
    HEAD="CI sweep stopped: a lane is not responding to fixes"
    ACT="Look at the failing job named below yourself — two rounds of automated fixes did not change its failure signature, so it is likely a decision, a credential, or a platform-side flag rather than a code bug." ;;
  MAIN-RED-BLOCKED)
    HEAD="CI sweep stopped: something needs you"
    ACT="The sweep found something only you can clear (a credential, an account, or a real decision) and stopped rather than spend its budget re-proving it. The blocker is named below." ;;
  MAIN-RED-EXHAUSTED)
    HEAD="CI sweep finished with main still red"
    ACT="The sweep used all its rounds and main is still red. Read the lanes below and decide whether to keep fixing or accept the break for now." ;;
  MAIN-RED-TIMEOUT)
    HEAD="CI sweep ran out of time with main still red"
    ACT="No action needed tonight — the next scheduled sweep will pick these up. If the same lanes appear tomorrow, they are not being fixed by iteration and need you." ;;
  MAIN-RED-TEMPFIX)
    HEAD="CI sweep caught itself weakening a test — DO NOT MERGE"
    ACT="A fixing agent tried to reach green by disabling a check. The pull request named below must be closed or rewritten; do not merge it." ;;
  MAIN-RED-HUNG)
    HEAD="CI sweep hung and was killed"
    ACT="Nothing is required from you unless it repeats. The sweep exceeded its two-hour ceiling, was killed from outside, and released its lock, so the next run starts clean. If this happens twice running, the headless claude session is wedging and that needs looking at." ;;
  MAIN-UNKNOWN)
    HEAD="CI sweep could not run"
    ACT="The sweep stopped before it could look at anything — usually the login keychain being locked, or gh/claude not being authenticated. Until it is cleared, NOTHING IS WATCHING CI. The named stop is in the log below." ;;
  *)
    HEAD="CI sweep: $VERDICT"
    ACT="See the log below." ;;
esac

WHEN="$(date '+%Y-%m-%d %H:%M %Z')"
TAIL=""
[ -n "$RUN_LOG" ] && [ -f "$RUN_LOG" ] && TAIL="$(tail -c 3000 "$RUN_LOG")"

# The repo to file against: the first one named in the detail line, so the issue
# lands where the fix belongs. Falls back to the ops home for verdicts that are
# about the sweep itself (hung, could-not-run) and name no repo.
REPO="$(printf '%s' "$DETAIL" | grep -oE '\[[a-z0-9 .-]+\]' | head -1 | tr -d '[]' | awk '{print $1}')"
if [ -n "$REPO" ] && gh repo view "seq23/$REPO" >/dev/null 2>&1; then
  ISSUE_REPO="seq23/$REPO"
else
  ISSUE_REPO="$ISSUE_REPO_FALLBACK"
fi

TITLE="[ci-sweep] $HEAD — $(date +%Y-%m-%d)"
BODY="$(cat <<EOF
**$HEAD**

**What to do:** $ACT

**Verdict:** \`$VERDICT\`
**When:** $WHEN
**Log:** \`$RUN_LOG\`

**What the sweep found**

$DETAIL

<details><summary>Last 3000 bytes of the run log — what it already tried</summary>

\`\`\`
$TAIL
\`\`\`

</details>

---
Filed automatically by \`~/bin/ci-sweep.sh\`. This issue exists because a red night
and a green night were otherwise indistinguishable without opening a log file.
A green sweep files nothing.
EOF
)"

rc=0

# --- 1. immediate: macOS notification ----------------------------------------
# Truncated hard: a notification body that overflows is silently dropped by
# Notification Center, which would make the loud channel the unreliable one.
SHORT="$(printf '%s' "$ACT" | head -c 180)"
if [ -n "$DRY" ]; then
  echo "[notify:dry] banner: \"$HEAD\" / \"$SHORT\""
else
  /usr/bin/osascript -e "display notification \"$(printf '%s' "$SHORT" | sed 's/"/\\"/g')\" with title \"CI sweep\" subtitle \"$(printf '%s' "$HEAD" | sed 's/"/\\"/g')\" sound name \"Basso\"" \
    >/dev/null 2>&1 || { echo "[notify] the macOS banner failed (no GUI session?)"; rc=1; }
fi

# --- 2. durable: a GitHub issue, which emails her -----------------------------
# DEDUPED BY TITLE. Two sweeps a day plus repeats would otherwise bury the first
# report under identical issues, and a channel that floods is a channel she mutes.
# A repeat comments on the open issue instead, which is also the more useful
# signal: it shows the thing recurring in one place.
if [ -n "$DRY" ]; then
  echo "[notify:dry] issue -> $ISSUE_REPO"
  echo "[notify:dry] title: $TITLE"
  printf '%s\n' "$BODY" | head -14 | sed 's/^/[notify:dry]   /'
else
  EXISTING="$(gh issue list --repo "$ISSUE_REPO" --state open --search "$TITLE in:title" \
              --json number,title --jq ".[]|select(.title==\"$TITLE\")|.number" 2>/dev/null | head -1)"
  if [ -n "$EXISTING" ]; then
    if gh issue comment "$EXISTING" --repo "$ISSUE_REPO" --body "$BODY" >/dev/null 2>&1; then
      echo "[notify] commented on $ISSUE_REPO#$EXISTING (recurrence)"
    else
      echo "[notify] FAILED to comment on $ISSUE_REPO#$EXISTING"; rc=1
    fi
  else
    URL="$(gh issue create --repo "$ISSUE_REPO" --title "$TITLE" --body "$BODY" 2>&1)"
    if [ $? -eq 0 ]; then echo "[notify] filed $URL"
    else echo "[notify] FAILED to file an issue on $ISSUE_REPO: $URL"; rc=1; fi
  fi
fi

# A NOTIFIER THAT FAILS SILENTLY IS WORSE THAN NO NOTIFIER — it makes everyone
# downstream believe she was told. Non-zero propagates into the run log.
[ "$rc" -ne 0 ] && echo "[notify] AT LEAST ONE CHANNEL FAILED — she may not have been told."
exit "$rc"
