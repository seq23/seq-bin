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
# The trigger model. A lane is SILENT only if this says the workflow's OWN
# configuration means a commit in the window should have started it. Before
# 2026-09-09 the question asked here was "does the file contain the string
# `push:`", which reported local-guides-generator's `Build Starter Pack` as
# NEVER_RAN on every single run — a healthy workflow with a six-entry `paths:`
# filter that the day's CHANGELOG-only commit correctly did not match.
#
# A FALSE SILENT IS UNCLEARABLE BY CONSTRUCTION: no work an agent can do makes a
# correctly-filtered workflow run, so the loop cannot converge and burns the
# whole budget on a healthy repo before ending in MAIN-RED-EXHAUSTED.
TRIGGERS="${CI_SWEEP_TRIGGERS_BIN:-$HOME/bin/ci-sweep-triggers.py}"
# A push made 30 seconds ago has not had time to start a run. Commits newer than
# this are excluded from the "should have triggered" question so the probe cannot
# manufacture a SILENT out of its own timing.
GRACE_MIN="${CI_SWEEP_GRACE_MIN:-5}"

log() { echo "$*" >&2; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-sweep-probe.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

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

# RULE 0 APPLIED TO THE PROBE'S OWN DEPENDENCY. Without the trigger model this
# script can only fall back to a string match, and the string match is the defect.
# It stops with a name rather than silently reverting to the broken behaviour.
#
# CHECKED BEFORE THE gh CHECKS ON PURPOSE: a missing dependency is a missing
# dependency whether or not anyone is logged in, and ordering it after `gh auth`
# meant the one machine most likely to be missing it — a CI runner, which has gh
# but no credentials — reported the wrong named stop and could never test this.
[ -x "$TRIGGERS" ] || { log "NAMED STOP [NO_TRIGGER_MODEL] $TRIGGERS is missing or not executable;"; \
  log "  without it a SILENT verdict would be a grep for 'push:' again, which is what it replaced."; exit 3; }
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

  # --- what actually changed on the default branch inside the window ----------
  # The trigger model needs FILENAMES, not a commit count. "1 commit happened"
  # cannot answer "should a workflow with a six-path filter have started", and
  # answering it anyway is precisely the bug being removed.
  CUTOFF="$(date -u -v-"${GRACE_MIN}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d "${GRACE_MIN} minutes ago" +%Y-%m-%dT%H:%M:%SZ)"
  commits_json="$(gh api "repos/$OWNER/$repo/commits?since=$SINCE&sha=$branch&per_page=100" 2>/dev/null || echo '[]')"
  commits="$(printf '%s' "$commits_json" | jq 'length' 2>/dev/null || echo 0)"
  CHANGED="$WORKDIR/changed.txt"
  : > "$CHANGED"
  # Only commits older than the grace period count. A push landed 30 seconds ago
  # has not had time to start a run, and calling that silence would be the probe
  # inventing a finding out of its own timing.
  #
  # AND ONLY COMMITS THAT CAN RAISE A `push` EVENT AT ALL. A push made by a
  # workflow using the default GITHUB_TOKEN does not raise one. That is a GitHub
  # rule, not a misconfiguration, and p-n-p's deploy-distribution.yml already
  # carries the confirmation for this fleet: `gh run list --commit <sha>` returns
  # an empty list for every bot commit on its main.
  #
  # Counting them here is not a detail. On 2026-09-09 local-guides-generator's
  # only commit in the window was `github-actions[bot]` recording citation probe
  # observations, and treating it as a trigger reported FOUR healthy lanes —
  # Validate, Integrity Build, Deploy Distribution, Complete Promoted Guides — as
  # SILENT. Four more unclearable findings, the same defect this file is being
  # repaired for, reintroduced one layer down.
  #
  # The test is deliberately narrow — committer type Bot/Organization, or one of
  # the two addresses GitHub's own runner commits under. A real person pushing
  # from a `12345+name@users.noreply.github.com` address must NOT be filtered out,
  # because that would hide genuine silences, so the whole noreply domain is not
  # matched. What is matched is what this fleet's automation actually commits as:
  #   github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>
  #   hicks-self-heal-bot <actions@github.com>
  #   approvalprep-indexing-bot <actions@users.noreply.github.com>
  #   how-we-know loop      <loop@users.noreply.github.com>   (name ends -bot/loop)
  settled_shas="$(printf '%s' "$commits_json" \
    | jq -r --arg c "$CUTOFF" '[.[]|select(.commit.committer.date <= $c)
        |select((.committer.type // "") as $t
                | ($t != "Bot" and $t != "Organization"))
        |select((.commit.committer.email // "")
                | (. != "actions@github.com" and . != "actions@users.noreply.github.com"))
        |select((.commit.committer.name // "")
                | (test("(\\[bot\\]|[-. ]bot|[-. ]loop)$") | not))
        ][0:40]|.[].sha' 2>/dev/null || true)"
  # `grep -c` exits 1 on no match, so a `|| echo 0` fallback would append a
  # SECOND zero and make the arithmetic below a syntax error. Counted with awk,
  # which always exits 0 and always prints exactly one number.
  botskipped=$(( commits - $(printf '%s\n' "$settled_shas" | awk 'NF{n++} END{print n+0}') ))
  settled=0
  for sha in $settled_shas; do
    [ -z "$sha" ] && continue
    settled=$((settled+1))
    gh api "repos/$OWNER/$repo/commits/$sha" -q '.files[]?.filename' >>"$CHANGED" 2>/dev/null || true
  done
  sort -u -o "$CHANGED" "$CHANGED" 2>/dev/null || true
  if [ "$settled" -eq 0 ] && [ "$botskipped" -gt 0 ]; then
    log "  $repo: $botskipped commit(s) in the window were all github-actions[bot] pushes," \
        "which raise no push event — push lanes are correctly quiet, not silent."
  fi

  # --- trigger verdict for every active workflow, computed once ---------------
  # ASK EACH WORKFLOW'S OWN CONFIGURATION, not a grep. YES / NO / UNKNOWN, and
  # UNKNOWN is never a finding — a trigger the model cannot evaluate must not
  # become an unclearable red lane, which was the whole failure mode here.
  VERDICTS="$WORKDIR/verdicts.txt"
  : > "$VERDICTS"
  while IFS= read -r flow; do
    [ -z "$flow" ] && continue
    wpath="$(printf '%s' "$wf" | jq -r --arg n "$flow" '.[]|select(.name==$n)|.path' 2>/dev/null | head -1)"
    should="UNKNOWN"; why="workflow file not present in the local checkout"
    if [ -n "$wpath" ] && [ -f "$dir/$wpath" ]; then
      vline="$("$TRIGGERS" should-run --workflow "$dir/$wpath" --branch "$branch" \
               --changed-files "$CHANGED" --since "$SINCE" --until "$CUTOFF" 2>/dev/null || true)"
      if [ -n "$vline" ]; then
        should="$(printf '%s' "$vline" | cut -f1)"
        why="$(printf '%s' "$vline" | cut -f2-)"
      fi
    fi
    printf '%s\t%s\t%s\n' "$flow" "$should" "$why" >> "$VERDICTS"
  done <<< "$active"

  # --- silence, repo-wide: something should have run and NOTHING ran ----------
  # This is the west-peek-os shape — deploy.yml deleted as collateral in a sync
  # commit, three weeks of commits, nothing red because nothing ran. It is kept
  # at REPO scope rather than per workflow because that is where the evidence
  # supports it: requiring the entire repo to have produced zero runs makes it
  # nearly impossible to fire on a repo whose automation is alive, while still
  # catching a repo whose CI has stopped altogether.
  runs_in_window="$(printf '%s' "$runs" | jq --arg s "$SINCE" '[.[]|select(.createdAt>$s)]|length' 2>/dev/null || echo 0)"
  if [ "$runs_in_window" -eq 0 ] && [ "$settled" -gt 0 ] && grep -q "	YES	" "$VERDICTS"; then
    printf 'SILENT\t%s\t(all)\t%s|NO_RUNS\t%s commit(s) since %s should have started %s but zero CI runs exist\n' \
      "$repo" "$repo" "$settled" "$SINCE" "$(grep -c "	YES	" "$VERDICTS") lane(s)"
    lanes=$((lanes+1)); red=$((red+1)); continue
  fi

  # --- newest run per active workflow ----------------------------------------
  while IFS=$'\t' read -r flow should why; do
    [ -z "$flow" ] && continue

    latest="$(printf '%s' "$runs" | jq -c --arg w "$flow" \
      '[.[]|select(.workflowName==$w)]|sort_by(.createdAt)|last // empty' 2>/dev/null)"

    # A LANE THAT SHOULD HAVE RUN IN THE WINDOW AND HAS NEVER RUN AT ALL is the
    # silence defect. The SCOPE OF THIS TEST IS DELIBERATE AND WAS NARROWED BACK
    # ON PURPOSE. The first version of this rewrite also fired when a workflow
    # merely held a run older than the window, on the theory that a stale GREEN
    # hides a lane that stopped firing. Measured against the fleet, that produced
    # EIGHT new findings — approvalprep/Validate, four in hicks-consulting-canonical,
    # horse-legal-guide-velocity/Validate Repo, dianne-place-recovery-services/CI,
    # how-we-know/loop · tests — and every one of them was checked and was FALSE:
    # each repo's only commits in the window were its own scheduled workflows
    # committing with GITHUB_TOKEN, which raises no push event.
    #
    # Eight unclearable red lanes across six healthy repos is a strictly worse
    # version of the single false positive this rewrite exists to remove. A
    # broader net that cannot tell true from false is not an improvement, so the
    # test stays where evidence supports it.
    if [ -z "$latest" ] && [ "$should" = "YES" ] && [ "$settled" -gt 0 ]; then
      # BUT ONLY IF THE WORKFLOW EXISTED WHEN THE TRIGGER CAME ROUND. A lane that
      # has never run is very often a lane that is NEW, and a new file cannot have
      # been fired by a cron tick or a commit that predates it. 2026-09-20:
      # creator-network's `Daily Creator Network` (cron 0 12 * * *) reached main
      # at 20:22Z inside a window that opened at 09:53Z; the 12:00 tick was in the
      # window, the file was not, and the probe reported NEVER_RAN — the
      # unclearable SILENT this file exists to never produce, reintroduced on the
      # one path where the lane has no history to contradict it.
      #
      # So the model is asked again from the branch's OLDEST commit touching the
      # workflow path, with a changed-file list rebuilt from only the settled
      # commits at or after that moment (the commit that adds a workflow does
      # fire it). Asked here and not for every lane because this is the one
      # verdict with no run to check against, and it costs one API page per lane
      # that reaches it. If the first appearance cannot be read, nothing is
      # clamped and the finding stands, exactly as before.
      wpath="$(printf '%s' "$wf" | jq -r --arg n "$flow" '.[]|select(.name==$n)|.path' 2>/dev/null | head -1)"
      first_seen=""
      [ -n "$wpath" ] && [ -f "$dir/$wpath" ] && \
      first_seen="$(gh api --paginate "repos/$OWNER/$repo/commits?path=$wpath&sha=$branch&per_page=100" 2>/dev/null \
        | jq -rs 'map(.[]?)|map(.commit.committer.date)|sort|first // empty' 2>/dev/null || true)"
      if [ -n "$first_seen" ]; then
        CHANGED_SINCE="$WORKDIR/changed-since-first-seen.txt"
        : > "$CHANGED_SINCE"
        for sha in $(printf '%s' "$commits_json" \
            | jq -r --arg f "$first_seen" '[.[]|select(.commit.committer.date >= $f)|.sha]|.[]' 2>/dev/null); do
          case " $settled_shas " in *" $sha "*) ;; *) continue ;; esac
          gh api "repos/$OWNER/$repo/commits/$sha" -q '.files[]?.filename' >>"$CHANGED_SINCE" 2>/dev/null || true
        done
        sort -u -o "$CHANGED_SINCE" "$CHANGED_SINCE" 2>/dev/null || true
        vline="$("$TRIGGERS" should-run --workflow "$dir/$wpath" --branch "$branch" \
                 --changed-files "$CHANGED_SINCE" --since "$SINCE" --until "$CUTOFF" \
                 --exists-since "$first_seen" 2>/dev/null || true)"
        if [ -n "$vline" ]; then
          should="$(printf '%s' "$vline" | cut -f1)"
          why="$(printf '%s' "$vline" | cut -f2-)"
        fi
      fi
    fi
    if [ -z "$latest" ] && [ "$should" = "YES" ] && [ "$settled" -gt 0 ]; then
      printf 'SILENT\t%s\t%s\t%s|%s|NEVER_RAN\tno run on %s at all, though a commit in the window should have started it: %s\n' \
        "$repo" "$flow" "$repo" "$flow" "$branch" "$why"
      lanes=$((lanes+1)); red=$((red+1)); continue
    fi

    if [ -z "$latest" ]; then
      # A workflow that has never run on the default branch is only a finding if
      # it was SUPPOSED to run there. The first version of this check flagged
      # `Velocity Full Rebuild`, `Query Class Occupancy Probe` and how-we-know's
      # `owner override` — all workflow_dispatch-only lanes that are correct to be
      # quiet. That would have made the convergence loop UNABLE TO EVER GO GREEN:
      # it would exhaust its rounds every single day chasing manual lanes, and
      # sent agents to "fix" workflows that are working exactly as designed.
      #
      # The SILENT case is handled above, by the trigger model. Reaching here
      # means the model said NO or UNKNOWN, so the lane is quiet on purpose or
      # unproven — either way, printed and not blocking.
      printf 'QUIET\t%s\t%s\t%s|%s|QUIET\tno run on %s — %s\n' \
        "$repo" "$flow" "$repo" "$flow" "$branch" "$why"
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
  done < "$VERDICTS"
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
