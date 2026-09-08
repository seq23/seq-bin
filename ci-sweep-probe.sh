#!/bin/bash
# Probe the ACTUAL state of main across every repo — the convergence criterion.
#
# WHY THIS EXISTS
# On 2026-09-08 the 10:07 sweep dispatched agents, they landed PRs #88/#89/#90 in
# local-guides-citation-velocity at 14:47/15:10/15:21, and `Velocity Content
# Release` failed AGAIN at 15:21. The sweep's own log would have read as a
# successful sweep. Nothing in the chain ever asked GitHub whether main was green;
# the only evidence was the agent's own claim, carried by a sentinel the agent
# writes itself.
#
# AN AGENT REPORTING "FIXED" IS A CLAIM. A GREEN RUN ON MAIN IS EVIDENCE. This
# script is the evidence. It is deliberately bash-and-gh rather than something the
# model produces, because the thing being checked is the model's own report.
#
# RULE 0 APPLIES HERE TOO: probing zero repos is not a green day. It exits with a
# named stop rather than printing nothing and letting the caller read silence as
# success — the exact defect class this portfolio names most often.
#
# OUTPUT (stdout, tab-separated, one line per lane):
#   STATE \t repo \t workflow \t signature \t detail
# STATE is one of:
#   GREEN   the newest run of an active workflow on the default branch succeeded
#           (or was legitimately skipped/neutral)
#   RED     it failed, was cancelled, timed out, or needs action
#   PENDING it has not reached a terminal state yet
#   SILENT  a finding: commits happened and CI did not run, or a push-triggered
#           workflow has never run on the default branch
#   QUIET   a workflow_dispatch/schedule-only lane that has not run — informational
#   NOCI    a repo with no workflows AND no commits — a standing condition
# ONLY RED AND SILENT BLOCK CONVERGENCE. QUIET and NOCI are printed on every run so
# they cannot become invisible, but a loop that treats them as failures can never
# reach green and would spend her whole budget every night on repos nobody touched.
# `signature` is stable across identical failures so the caller can tell a lane
# that changed from a lane that is stuck repeating itself.
#
# EXIT CODES
#   0  every lane GREEN                      — main is green, converged
#   1  at least one RED or SILENT lane       — not converged
#   2  no RED/SILENT, but lanes still PENDING — terminal state not yet reached
#   3  named stop (no gh, no repos, not authenticated)

set -uo pipefail

GITHUB_DIR="${CI_SWEEP_GITHUB_DIR:-$HOME/GitHub}"
OWNER="${CI_SWEEP_OWNER:-seq23}"
# The silence window. A repo with commits in this window and zero CI runs in it is
# a finding — see the west-peek-os incident in ci-sweep-prompt.md: nothing was red
# because nothing ran, for three weeks, on the fund's own operating system.
SILENCE_HOURS="${CI_SWEEP_SILENCE_HOURS:-14}"
# Restrict the probe to these repos (space separated bare names). Used by the
# convergence loop to re-probe only the lanes that were red, and by the tests.
ONLY_REPOS="${CI_SWEEP_ONLY_REPOS:-}"
# Fixture mode: read lane lines from a file instead of GitHub, so the caller's
# convergence logic can be exercised against green / red / stuck days without
# waiting for a real one. A loop whose only test is production is untestable.
FIXTURE="${CI_SWEEP_PROBE_FIXTURE:-}"

log() { echo "$*" >&2; }

if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { log "NAMED STOP [NO_FIXTURE] $FIXTURE"; exit 3; }
  cat "$FIXTURE"
  red=$(grep -cE '^(RED|SILENT)	' "$FIXTURE" || true)
  pend=$(grep -cE '^PENDING	' "$FIXTURE" || true)
  any=$(grep -cE '^(RED|SILENT|PENDING|GREEN)	' "$FIXTURE" || true)
  log "probe(fixture): $any lane(s), $red red/silent, $pend pending"
  [ "$any" -eq 0 ] && { log "NAMED STOP [PROBED_NOTHING] fixture has no lanes."; exit 3; }
  [ "$red" -gt 0 ] && exit 1
  [ "$pend" -gt 0 ] && exit 2
  exit 0
fi

command -v gh >/dev/null 2>&1 || { log "NAMED STOP [NO_GH_CLI]"; exit 3; }
gh auth status >/dev/null 2>&1 || { log "NAMED STOP [GH_NOT_AUTHENTICATED]"; exit 3; }

SINCE="$(date -u -v-"${SILENCE_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d "${SILENCE_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"

# One API call for the whole account rather than one per repo. Archived repos are
# excluded here: a red lane in an archive is not actionable and would keep the
# convergence loop running forever against something nobody intends to fix.
REPO_META="$(gh repo list "$OWNER" --limit 200 \
  --json name,isArchived,defaultBranchRef 2>/dev/null)"
if [ -z "$REPO_META" ]; then
  log "NAMED STOP [NO_REPO_LIST] gh returned no repositories for $OWNER."
  exit 3
fi

lanes=0; red=0; pending=0; noci=0

for dir in "$GITHUB_DIR"/*/; do
  [ -d "$dir/.git" ] || continue
  name="$(basename "$dir")"

  # boss-os has no git remote by design and must never be swept. Anything whose
  # origin is not this owner's GitHub is out of scope for the same reason.
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  case "$origin" in
    *github.com[:/]"$OWNER"/*) ;;
    *) continue ;;
  esac
  repo="$(basename "${origin%.git}")"

  if [ -n "$ONLY_REPOS" ]; then
    case " $ONLY_REPOS " in *" $repo "*) ;; *) continue ;; esac
  fi

  meta="$(printf '%s' "$REPO_META" | jq -c --arg n "$repo" '.[]|select(.name==$n)' 2>/dev/null)"
  [ -z "$meta" ] && continue
  [ "$(printf '%s' "$meta" | jq -r '.isArchived')" = "true" ] && continue
  branch="$(printf '%s' "$meta" | jq -r '.defaultBranchRef.name // "main"')"

  # --- no workflows at all: the strongest form of the silence defect ----------
  wf="$(gh workflow list --repo "$OWNER/$repo" --json name,state,path 2>/dev/null || echo '[]')"
  active="$(printf '%s' "$wf" | jq -r '[.[]|select(.state=="active")|.name]|.[]' 2>/dev/null)"
  if [ -z "$active" ]; then
    commits="$(gh api "repos/$OWNER/$repo/commits?since=$SINCE&sha=$branch" -q 'length' 2>/dev/null || echo 0)"
    if [ "$commits" -gt 0 ]; then
      # Somebody is pushing to a repo that has NO CI. This is the west-peek-os
      # shape exactly: deploy.yml deleted as collateral in a sync commit, three
      # weeks of commits, `gh workflow list` empty, nothing red because nothing
      # ran. A finding, and it converges like any other red lane.
      printf 'SILENT\t%s\t(none)\t%s|NO_WORKFLOWS\tno active workflows despite %s commit(s) since %s\n' \
        "$repo" "$repo" "$commits" "$SINCE"
      lanes=$((lanes+1)); red=$((red+1))
    else
      # No workflows AND nothing being pushed. Six of her repos are like this —
      # finished static client sites. The first version of this check called them
      # SILENT unconditionally, which would have made the fleet PERMANENTLY
      # un-green: every night the loop would spend all three rounds and the whole
      # budget on repos that have never had CI, nobody is touching, and nobody
      # wants CI for. "Do not stop until green" needs a reachable green.
      #
      # So it is reported on EVERY run as NOCI and never hidden — the prompt's
      # rule that an empty workflow list must never read as "nothing to do" still
      # holds — but a standing condition on a dormant repo is not a break that
      # appeared today, and it does not block convergence.
      printf 'NOCI\t%s\t(none)\t%s|NO_WORKFLOWS_DORMANT\tno workflows and no commits since %s — standing condition, not a new break\n' \
        "$repo" "$repo" "$SINCE"
      noci=$((noci+1))
    fi
    continue
  fi

  runs="$(gh run list --repo "$OWNER/$repo" --branch "$branch" --limit 80 \
        --json workflowName,conclusion,status,createdAt,databaseId 2>/dev/null || echo '[]')"

  # --- silence: commits in the window, zero runs in the window ----------------
  runs_in_window="$(printf '%s' "$runs" | jq --arg s "$SINCE" '[.[]|select(.createdAt>$s)]|length' 2>/dev/null || echo 0)"
  commits="$(gh api "repos/$OWNER/$repo/commits?since=$SINCE&sha=$branch" -q 'length' 2>/dev/null || echo 0)"
  if [ "$commits" -gt 0 ] && [ "$runs_in_window" -eq 0 ]; then
    printf 'SILENT\t%s\t(all)\t%s|NO_RUNS\t%s commit(s) since %s but zero CI runs\n' \
      "$repo" "$repo" "$commits" "$SINCE"
    lanes=$((lanes+1)); red=$((red+1)); continue
  fi

  # --- newest run per active workflow ----------------------------------------
  while IFS= read -r flow; do
    [ -z "$flow" ] && continue
    latest="$(printf '%s' "$runs" | jq -c --arg w "$flow" \
      '[.[]|select(.workflowName==$w)]|sort_by(.createdAt)|last // empty' 2>/dev/null)"

    if [ -z "$latest" ]; then
      # A workflow that has never run on the default branch is only a finding if
      # it was SUPPOSED to run there. The first version of this check flagged
      # `Velocity Full Rebuild`, `Query Class Occupancy Probe` and how-we-know's
      # `owner override` — all workflow_dispatch-only lanes that are correct to be
      # quiet. That would have made the convergence loop UNABLE TO EVER GO GREEN:
      # it would exhaust its rounds every single day chasing manual lanes, and
      # sent agents to "fix" workflows that are working exactly as designed.
      #
      # The silence defect this exists for (west-peek-os, deploy.yml deleted in a
      # sync commit) was a PUSH-triggered lane. So: no push trigger, no finding.
      # Quiet manual/scheduled lanes are still printed as QUIET so they stay
      # visible, but QUIET does not block convergence.
      wpath="$(printf '%s' "$wf" | jq -r --arg n "$flow" '.[]|select(.name==$n)|.path' 2>/dev/null | head -1)"
      trig="manual/scheduled"
      if [ -n "$wpath" ] && [ -f "$dir/$wpath" ] \
         && grep -qE '^[[:space:]]{0,4}push:' "$dir/$wpath" 2>/dev/null; then
        trig="push"
      fi
      if [ "$commits" -gt 0 ] && [ "$trig" = "push" ]; then
        printf 'SILENT\t%s\t%s\t%s|%s|NEVER_RAN\tpush-triggered workflow with no run on %s despite %s commit(s)\n' \
          "$repo" "$flow" "$repo" "$flow" "$branch" "$commits"
        lanes=$((lanes+1)); red=$((red+1))
      else
        printf 'QUIET\t%s\t%s\t%s|%s|QUIET\t%s-only workflow, no run on %s — not a finding\n' \
          "$repo" "$flow" "$repo" "$flow" "$trig" "$branch"
      fi
      continue
    fi

    status="$(printf '%s' "$latest" | jq -r '.status')"
    concl="$(printf '%s' "$latest" | jq -r '.conclusion // ""')"
    rid="$(printf '%s' "$latest" | jq -r '.databaseId')"
    lanes=$((lanes+1))

    if [ "$status" != "completed" ]; then
      printf 'PENDING\t%s\t%s\t%s|%s|PENDING\trun #%s is %s\n' "$repo" "$flow" "$repo" "$flow" "$rid" "$status"
      pending=$((pending+1)); continue
    fi

    case "$concl" in
      success|skipped|neutral)
        printf 'GREEN\t%s\t%s\t%s|%s|%s\trun #%s\n' "$repo" "$flow" "$repo" "$flow" "$concl" "$rid"
        ;;
      *)
        # The failing JOB names go into the signature. Two failures of the same
        # workflow in different jobs are different problems; two failures in the
        # same job after a round of fixes is a lane that did not move, which is
        # what the caller escalates on rather than burning its remaining rounds.
        jobs="$(gh run view "$rid" --repo "$OWNER/$repo" --json jobs \
              --jq '[.jobs[]|select(.conclusion!="success" and .conclusion!="skipped")|.name]|sort|join(",")' 2>/dev/null || true)"
        [ -z "$jobs" ] && jobs="(jobs-unreadable)"
        printf 'RED\t%s\t%s\t%s|%s|%s|%s\trun #%s concluded %s\n' \
          "$repo" "$flow" "$repo" "$flow" "$concl" "$jobs" "$rid" "$concl"
        red=$((red+1))
        ;;
    esac
  done <<< "$active"
done

# RULE 0. Probing nothing is not a clean bill of health.
if [ "$lanes" -eq 0 ]; then
  log "NAMED STOP [PROBED_NOTHING] no repository under $GITHUB_DIR resolved to a non-archived $OWNER repo."
  log "  Zero lanes examined is not a green day; it means the probe could not see the fleet."
  exit 3
fi

# NOCI is counted out loud on every run so a repo without CI can never become
# invisible just because it is not blocking the loop.
log "probe: $lanes lane(s) across the fleet — $red red/silent, $pending pending, $noci repo(s) with no CI at all (dormant)"
[ "$red" -gt 0 ] && exit 1
[ "$pending" -gt 0 ] && exit 2
exit 0
