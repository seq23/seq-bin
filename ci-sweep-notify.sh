#!/bin/bash
# Tell HER. Called by ci-sweep.sh once at the end of EVERY run, green or not.
#
#   ci-sweep-notify.sh <VERDICT> <SUMMARY> <RUN_LOG> [ISSUES_TSV] [DETAIL]
#
# THE MORNING SUMMARY (design of 23 Sep 2026: one run a day at 07:00, one answer;
# one automatic retry at 08:00 added 24 Sep 2026 if the 07:00 run was not green)
# · A macOS banner, ALWAYS: which repos are green, fixed, parked, stuck. One banner
#   per run — so a retry day gets two — replacing the old 30-minute retry loop's
#   many banners; a green one is information, not noise.
# · A GitHub issue per PARKED or STUCK repo (ISSUES_TSV lines: KIND \t repo \t
#   what is needed), filed on that repo, naming the one decision or credential. Deduped
#   by exact title: a repeat the same day comments on the open issue instead.
# · One run-level issue for a run that could not reach a verdict about the fleet
#   (TEMPFIX, HUNG, INTERRUPTED, UNKNOWN), or for any red verdict that somehow named
#   no repo — a red ending is never silent.
# · A green run files nothing.
#
# WHY GITHUB ISSUES: durable, and GitHub emails her, so it survives a closed laptop.
# `gh` is already a hard precondition of the sweep: no new credential.

set -uo pipefail

# `${1-}` not `${1:-...}`: an EMPTY first argument must reach the refusal below.
VERDICT="${1-}"
SUMMARY="${2:-}"
RUN_LOG="${3:-}"
ISSUES="${4:-}"
DETAIL="${5:-}"
GH_OWNER="${CI_SWEEP_GH_OWNER:-seq23}"
ISSUE_REPO_FALLBACK="${CI_SWEEP_ISSUE_REPO:-$GH_OWNER/west-peek-os}"
# Test seam: print what WOULD be sent instead of sending it.
DRY="${CI_SWEEP_NOTIFY_DRY:-}"

# RULE 0: a notification with no verdict is noise, and noise is how a channel dies.
[ -n "$VERDICT" ] || { echo "[notify] NAMED STOP [NO_VERDICT] refusing to notify without one."; exit 2; }

# --- the headline and what she should DO -------------------------------------
RUN_LEVEL=""   # set for verdicts that are about the run itself, not a repo
case "$VERDICT" in
  MAIN-GREEN)
    HEAD="every main is green"
    ACT="Nothing needed from you." ;;
  MAIN-PENDING)
    HEAD="nothing red; some runs still in flight"
    ACT="Nothing needed from you. A run still in progress is unproven, not failed." ;;
  MAIN-RED-BLOCKED)
    HEAD="the repos still red need you"
    ACT="Every repo still red is parked on something only you can clear. Each has an issue on its repo naming the one decision or credential needed." ;;
  MAIN-RED-STUCK)
    HEAD="repos stuck red — fixes stopped changing the failure"
    ACT="Two rounds in a row changed nothing, so the stuck repos need a look or a decision. Each has an issue on its repo; parked ones name the decision needed." ;;
  MAIN-RED-UNFINISHED)
    HEAD="work left unfinished — not green yet"
    ACT="The run ended with work the sweep could not finish here: lanes still red when the 3h30 budget ran out, fixes merged whose lanes have not re-run on main, or its own fix PRs still open. The exact list is in the carryover, and the next run (today's 08:00 retry if this wasn't green, otherwise tomorrow's 07:00) resumes from it." ;;
  MAIN-RED-KILLED)
    HEAD="was killed before it reached a verdict"
    ACT="Something ended the sweep from outside (a signal to its supervisor). Main is unverified; the next run resumes."
    RUN_LEVEL=1 ;;
  MAIN-RED-TEMPFIX)
    HEAD="caught a fix weakening a test — DO NOT MERGE it"
    ACT="A fixing agent tried to reach green by disabling a check. The PR is marked REJECTED on the PR itself and the run ended. Close or rewrite that PR; tomorrow's run is told to fix the root cause."
    RUN_LEVEL=1 ;;
  MAIN-RED-HUNG)
    HEAD="hung and was killed"
    ACT="The sweep exceeded its awake ceiling and was killed from outside; its open PRs are parked, not merged. If this repeats, the headless claude session is wedging."
    RUN_LEVEL=1 ;;
  MAIN-RED-INTERRUPTED)
    HEAD="interrupted by the Mac sleeping"
    ACT="The round in flight was ended, not finished; its open PRs are parked, never merged. Main is unverified until the next run (today's 08:00 retry, or tomorrow's 07:00). Check pmset if it recurs: sleep should be 0."
    RUN_LEVEL=1 ;;
  MAIN-UNKNOWN)
    HEAD="could not run"
    ACT="The sweep stopped before it could look at anything — usually the login keychain locked, or gh/claude not authenticated. Until cleared, NOTHING IS WATCHING CI. The named stop is in the log."
    RUN_LEVEL=1 ;;
  *)
    HEAD="$VERDICT"
    ACT="See the log."
    RUN_LEVEL=1 ;;
esac

n_issue_lines=0
[ -n "$ISSUES" ] && [ -f "$ISSUES" ] && n_issue_lines="$(grep -c . "$ISSUES")"
# Red, and yet no repo named: file the run-level issue so a red ending is never silent.
case "$VERDICT" in
  MAIN-GREEN|MAIN-PENDING) : ;;
  *) [ "$n_issue_lines" -eq 0 ] && RUN_LEVEL=1 ;;
esac

WHEN="$(date '+%Y-%m-%d %H:%M %Z')"
DAY="$(date +%Y-%m-%d)"
TAIL=""
[ -n "$RUN_LOG" ] && [ -f "$RUN_LOG" ] && TAIL="$(tail -c 3000 "$RUN_LOG")"
rc=0

# --- 1. the banner, ALWAYS -----------------------------------------------------
# Truncated hard: an overflowing body is silently dropped by Notification Center.
SHORT="$(printf '%s' "${SUMMARY:-$ACT}" | head -c 200)"
SOUND='sound name "Basso"'; [ "$VERDICT" = "MAIN-GREEN" ] && SOUND=""
if [ -n "$DRY" ]; then
  echo "[notify:dry] banner: \"CI sweep: $HEAD\" / \"$SHORT\""
else
  /usr/bin/osascript -e "display notification \"$(printf '%s' "$SHORT" | sed 's/"/\\"/g')\" with title \"CI sweep\" subtitle \"$(printf '%s' "$HEAD" | sed 's/"/\\"/g')\" $SOUND" \
    >/dev/null 2>&1 || { echo "[notify] the macOS banner failed (no GUI session?)"; rc=1; }
fi

# --- 2. durable issues ---------------------------------------------------------
file_issue() { # repo title body
  local repo="$1" title="$2" body="$3" existing url
  if [ -n "$DRY" ]; then
    echo "[notify:dry] issue -> $repo"
    echo "[notify:dry] title: $title"
    printf '%s\n' "$body" | head -8 | sed 's/^/[notify:dry]   /'
    return 0
  fi
  existing="$(gh issue list --repo "$repo" --state open --search "$title in:title" \
              --json number,title --jq ".[]|select(.title==\"$title\")|.number" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    if gh issue comment "$existing" --repo "$repo" --body "$body" >/dev/null 2>&1; then
      echo "[notify] commented on $repo#$existing (recurrence)"
    else
      echo "[notify] FAILED to comment on $repo#$existing"; rc=1
    fi
  else
    if url="$(gh issue create --repo "$repo" --title "$title" --body "$body" 2>&1)"; then
      echo "[notify] filed $url"
    else
      echo "[notify] FAILED to file an issue on $repo: $url"; rc=1
    fi
  fi
}

FOOTER="---
Filed by \`~/bin/ci-sweep.sh\` (07:00 daily, one retry at 08:00 if not green). **Run verdict:** \`$VERDICT\` · **When:** $WHEN · **Log:** \`$RUN_LOG\`

**Morning summary:** $SUMMARY"

if [ "$n_issue_lines" -gt 0 ]; then
  while IFS=$'\t' read -r kind repo need; do
    [ -z "$repo" ] && continue
    target="$GH_OWNER/$repo"
    if [ -z "$DRY" ] && ! gh repo view "$target" >/dev/null 2>&1; then target="$ISSUE_REPO_FALLBACK"; fi
    case "$kind" in
      PARKED)
        title="[ci-sweep] $repo is parked on your decision — $DAY"
        body="**$repo: main is red and only you can clear it.**

**What is needed:** $need

The sweep stopped working this repo and carried on with the rest. The next run (today's 08:00 retry if this wasn't green, otherwise tomorrow's 07:00) re-checks it; record the decision (or supply the credential) and it will pick it up.

$FOOTER" ;;
      UNVERIFIED)
        title="[ci-sweep] $repo: fix merged, lane not yet re-run on main — $DAY"
        body="**$repo: main is not verified green yet.**

**Unfinished:** $need

The fix is merged, but the lane has not run on main since, so the sweep cannot call it green. The sweep dispatches such a lane itself where it can; this one it could not (no manual trigger, or a repo whose lanes it never runs by hand). The next run (today's 08:00 retry if this wasn't green, otherwise tomorrow's 07:00) re-checks it from GitHub.

$FOOTER" ;;
      *)
        title="[ci-sweep] $repo is stuck red — $DAY"
        body="**$repo: main is still red after the sweep's fixing rounds.**

**Still failing:** $need

Rounds stopped changing this failure (or the budget ran out while it was still red). It likely needs a decision, a credential, or a platform-side flag rather than another code fix — say which, and the next run (today's 08:00 retry if this wasn't green, otherwise tomorrow's 07:00) will act on it.

$FOOTER" ;;
    esac
    file_issue "$target" "$title" "$body"
  done < "$ISSUES"
fi

if [ -n "$RUN_LEVEL" ]; then
  # The repo to file against: the first one named in [brackets] in the detail, so a
  # TEMPFIX lands where the PR is; otherwise the ops home.
  REPO="$(printf '%s' "$DETAIL" | grep -oE '\[[a-z0-9 .-]+\]' | head -1 | tr -d '[]' | awk '{print $1}')"
  if [ -n "$REPO" ] && { [ -n "$DRY" ] || gh repo view "$GH_OWNER/$REPO" >/dev/null 2>&1; }; then
    TARGET="$GH_OWNER/$REPO"
  else
    TARGET="$ISSUE_REPO_FALLBACK"
  fi
  file_issue "$TARGET" "[ci-sweep] CI sweep $HEAD — $DAY" "**CI sweep $HEAD**

**What to do:** $ACT

**What the sweep found:** $DETAIL

<details><summary>Last 3000 bytes of the run log</summary>

\`\`\`
$TAIL
\`\`\`

</details>

$FOOTER"
fi

[ "$VERDICT" = "MAIN-GREEN" ] && [ "$n_issue_lines" -eq 0 ] && echo "[notify] green: banner only, no issue filed."
# A NOTIFIER THAT FAILS SILENTLY IS WORSE THAN NO NOTIFIER.
[ "$rc" -ne 0 ] && echo "[notify] AT LEAST ONE CHANNEL FAILED — she may not have been told."
exit "$rc"
