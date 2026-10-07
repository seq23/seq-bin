#!/bin/bash
# Boss OS's grid tasks, as lanes the CI sweep works (7 Oct 2026).
#
# WHY THIS EXISTS
# From 16 Sep Boss OS's grid watcher filed a "fix this repo" task for Danielle on every
# red build, stuck pull request and quiet lane it saw — 48 by 7 Oct — and nothing claimed
# any of them: the Worker's model drain refuses them by design (one agent per repo), and no
# other executor read them. Lane health is what this sweep's probe already reads, so Boss OS
# now files a task ONLY for what the probe cannot see — a stale pull request — one open task
# per repo, and `npm run grid:post` (boss-os scripts/ops/grid-watch.mjs) rewrites the open set
# into the inbox below every day. THIS is the claim: each line becomes a RED lane while its
# pull request is still open, so the sweep dispatches one agent to that repo to land it (via
# ~/bin/land) or close it with a reason, and the lane goes GREEN when the PR is gone — no one
# edits the inbox, and the next grid run closes the Boss OS task.
#
# INPUT  $CI_SWEEP_GRID_INBOX (default ~/Library/Logs/ci-sweep/state/grid-inbox.tsv)
#        owner/repo \t kind \t evidence-url \t boss-task-id \t headline
# OUTPUT the probe's lane format: STATE \t repo \t workflow \t signature \t detail
#        RED   the pull request is still open
#        GREEN it was merged or closed
#        QUIET it could not be read (not blocking: unproven is not red)
#        Lines of any other kind are ignored here: the probe's own lanes judge lane health.
#        The detail never says "run #N", so the FIXED-UNVERIFIED logic never tries to
#        `gh workflow run` a pull request.
# ENV    CI_SWEEP_ONLY_REPOS restricts to those bare repo names, as the probe does.
# EXIT   always 0; a missing or empty inbox prints nothing.
set -uo pipefail
INBOX="${CI_SWEEP_GRID_INBOX:-$HOME/Library/Logs/ci-sweep/state/grid-inbox.tsv}"
ONLY_REPOS="${CI_SWEEP_ONLY_REPOS:-}"
[ -s "$INBOX" ] || exit 0
seen=""
while IFS=$'\t' read -r grepo gkind gevidence gtask ghead; do
  [ "$gkind" = "pr_stale" ] || continue
  bare="${grepo#*/}"
  [ -n "$bare" ] || continue
  if [ -n "$ONLY_REPOS" ]; then case " $ONLY_REPOS " in *" $bare "*) ;; *) continue ;; esac; fi
  num="${gevidence##*/pull/}"; num="${num%%[^0-9]*}"
  [ -n "$num" ] || continue
  case " $seen " in *" $bare#$num "*) continue ;; esac
  seen="$seen $bare#$num"
  state="$(gh pr view "$num" --repo "$grepo" --json state --jq .state 2>/dev/null </dev/null || true)"
  case "$state" in
    OPEN)
      printf 'RED\t%s\tgrid: stale PR #%s\t%s|grid-pr|%s|OPEN\tBoss OS grid task %s — %s Land it with ~/bin/land if it is still right; close it with a one-line reason if it is superseded. %s\n' \
        "$bare" "$num" "$bare" "$num" "$gtask" "$ghead" "$gevidence" ;;
    MERGED|CLOSED)
      printf 'GREEN\t%s\tgrid: stale PR #%s\t%s|grid-pr|%s|%s\tpull request %s\n' "$bare" "$num" "$bare" "$num" "$state" "$state" ;;
    *)
      printf 'QUIET\t%s\tgrid: stale PR #%s\t%s|grid-pr|%s|UNREADABLE\tcould not read %s — unproven, not red\n' "$bare" "$num" "$bare" "$num" "$gevidence" ;;
  esac
done < "$INBOX"
exit 0
