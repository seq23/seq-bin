#!/bin/bash
# CI sweep — 07:00 CT, under launchd (launchd/com.seq.ci-sweep.plist in this
# repo), with one automatic retry at 08:00 if that run does not end green
# (launchd/com.seq.ci-sweep-retry.plist -> ci-sweep-retry-if-red.sh, which
# runs THIS script again unchanged). Goal: every repo's main green by about
# 10:30 (11:30 on a retry day).
#
# THE DESIGN (her approval, 23 Sep 2026; retry added on her instruction, 24 Sep 2026)
#   · One run at 07:00. This script itself never retries — it does not know
#     whether it is the 07:00 run or the 08:00 retry, and does not need to:
#     ci-sweep-retry-if-red.sh reads the ledger and runs it again exactly once
#     if today's only run so far did not end MAIN-GREEN. A second non-green
#     ending waits for tomorrow's 07:00 run, briefed with what both tries did
#     (state/carryover-next.md). If the Mac was asleep at 07:00, launchd fires
#     the missed run once at wake, and the 08:00 retry check still runs as usual.
#   · Round 1 probes main across the fleet and dispatches one fixing agent per red
#     repo, in parallel. Every `claude -p` is pinned to `--model opus`; the prompt
#     makes every fixing agent opus too. Nothing follows whatever /model last said.
#   · A repo only she can unblock (a credential, an account setting, a genuine
#     product decision) is PARKED — for that repo only. The run keeps going on
#     every other red repo.
#   · ROUNDS ARE PROGRESS-DRIVEN. Another round runs while the last one made
#     progress: a red lane went away, or a red lane's failure signature changed (a
#     new root cause surfaced). The run stops when the fleet is green, after
#     NO_PROGRESS_LIMIT consecutive rounds that moved nothing (STUCK), or at the
#     3h30 budget. Rounds share one claude session.
#   · THE SWEEP MERGES ITS OWN FIXES, after the audit, once `gh pr checks` — read
#     here, never an agent's report — says every check passed: `land <pr>` where
#     land knows the repo (it deploys too), otherwise `gh pr merge --merge
#     --delete-branch`, then main is watched to a terminal state. how-we-know
#     included; its live loop state is never touched.
#   · One morning summary per run — green / fixed (PR numbers) / parked (the
#     decision needed) / stuck — as the log's last line and a macOS banner, always.
#     A GitHub issue per parked or stuck repo; a green run files nothing.
#
# WHY ONCE A DAY. The 30-minute tick, window gate, 25-minute retry, 6-attempt
# escalation and 2-hour slow cadence existed to keep hammering a red main all day.
# They mostly re-ran the same blocked repo (one BLOCKED repo ended the whole run),
# cost a fresh session each time, and hid the day's outcome across many logs. One
# long, progress-driven run that parks what only she can clear and fixes the rest
# gives her a single answer each morning.
#
# WHY IT ITERATES AT ALL (2026-09-08). `local-guides-citation-velocity` landed PRs
# #88-#90 and the lane failed again at 15:21; the sweep had only the agent's own
# "fixed" to go on. So: AN AGENT REPORTING "FIXED" IS A CLAIM; A GREEN RUN ON MAIN
# IS EVIDENCE. ci-sweep-probe.sh asks GitHub after every round, watching runs to a
# TERMINAL state (success AND failure), and the verdict comes from it.
#
# RULE 0: this script may not exit 0 having done nothing. Either it swept and
# reported, or it exits non-zero with a named reason.

set -uo pipefail

# --- what the sweep is allowed to spend --------------------------------------
#   DEADLINE_MIN  = 210  the convergence budget (3h30): 07:00 start, done ~10:30.
#   HARD_KILL_MIN = 240  the kernel-enforced backstop, counted in AWAKE ticks by the
#                        sentry below. A fault detector, not a budget: 30 minutes
#                        of headroom so an ordinary red morning reports on its own
#                        terms instead of being cut off at the wall.
HARD_KILL_MIN="${CI_SWEEP_HARD_KILL_MIN:-240}"
DEADLINE_MIN="${CI_SWEEP_DEADLINE_MIN:-210}"

# Per-round caps on the claude invocation, each clamped to what is left. Round 1
# is larger because it does the discovery and the first dispatch.
ROUND1_CAP_MIN="${CI_SWEEP_ROUND1_CAP_MIN:-60}"
ROUNDN_CAP_MIN="${CI_SWEEP_ROUNDN_CAP_MIN:-40}"

# How long to wait, after a round, for in-flight runs on main to reach a terminal state.
VERIFY_CAP_MIN="${CI_SWEEP_VERIFY_CAP_MIN:-8}"
# Merge pass: how long to wait for a PR's pending checks, and for main after merging.
MERGE_CHECKS_CAP_MIN="${CI_SWEEP_MERGE_CHECKS_CAP_MIN:-15}"
MAIN_WATCH_CAP_MIN="${CI_SWEEP_MAIN_WATCH_CAP_MIN:-25}"
POLL_SECS="${CI_SWEEP_POLL_SECS:-30}"

# Consecutive rounds with no progress before the run is STUCK. Two rounds that
# moved nothing is evidence about the problem, not about effort.
NO_PROGRESS_LIMIT="${CI_SWEEP_NO_PROGRESS_LIMIT:-2}"

# SLEEP_GAP 180s: the sentry ticks every 20s; a gap of more than 9 ticks between two
# of its own stamps means the Mac was asleep, not that the sweep was slow.
SLEEP_GAP_SECS="${CI_SWEEP_SLEEP_GAP_SECS:-180}"
TICK_SECS="${CI_SWEEP_TICK_SECS:-20}"

# Overridable so the plumbing can be exercised against fakes (tests/test-sweep-daily.sh)
# without touching the live lock, the real log directory or real repos.
PROMPT_FILE="${CI_SWEEP_PROMPT:-$HOME/bin/ci-sweep-prompt.md}"
PROBE="${CI_SWEEP_PROBE_BIN:-$HOME/bin/ci-sweep-probe.sh}"
AUDIT="${CI_SWEEP_AUDIT_BIN:-$HOME/bin/ci-sweep-audit.sh}"
STREAM="${CI_SWEEP_STREAM_BIN:-$HOME/bin/ci-sweep-stream.py}"
LAND="${CI_SWEEP_LAND_BIN:-$HOME/bin/land}"
LOG_DIR="${CI_SWEEP_LOG_DIR:-$HOME/Library/Logs/ci-sweep}"
LOCK="$LOG_DIR/.lock"
STAMP="$(date +%Y-%m-%dT%H:%M:%S)"
STARTED_AT="${CI_SWEEP_STARTED_AT:-$(date +%s)}"
DEADLINE_AT=$((STARTED_AT + DEADLINE_MIN * 60))
KILL_AT=$((STARTED_AT + HARD_KILL_MIN * 60))
# Seconds AND pid: two runs in one minute once shared a log and the second passed
# Rule 0 on the first one's sentinel (2026-09-02). Inherited by the supervised body
# so supervisor and body write the same log and work directory.
RUN_ID="${CI_SWEEP_RUN_ID:-$(date +%Y-%m-%d-%H%M%S)-$$}"
RUN_LOG="$LOG_DIR/$RUN_ID.log"
WORK="$LOG_DIR/$RUN_ID.d"
NOTIFY="${CI_SWEEP_NOTIFY_BIN:-$HOME/bin/ci-sweep-notify.sh}"
GITHUB_DIR="${CI_SWEEP_GITHUB_DIR:-$HOME/GitHub}"
GH_OWNER="${CI_SWEEP_GH_OWNER:-seq23}"

# Cross-run state.
#   outcomes.tsv       end-epoch \t YYYY-MM-DD \t VERDICT \t run-id — one line per run
#   carryover-next.md  what a non-green run tried, rejected, parked — handed to the
#                      next day's round 1. Deleted by a green run. She (or a session
#                      acting for her) may append a dated "## OWNER DECISIONS" section.
STATE_DIR="$LOG_DIR/state"
LEDGER="$STATE_DIR/outcomes.tsv"
NEXT_CARRY="$STATE_DIR/carryover-next.md"

mkdir -p "$LOG_DIR" "$STATE_DIR"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
# Format an epoch: BSD date takes -r, GNU date takes -d @. The tests run on both.
at_time() { local e="$1"; shift; date -r "$e" "$@" 2>/dev/null || date -d "@$e" "$@"; }
at_time_utc() { local e="$1"; shift; date -u -r "$e" "$@" 2>/dev/null || date -u -d "@$e" "$@"; }

# --- the outcome ledger --------------------------------------------------------
# Replaces any earlier line for this run id: the body may record a verdict and the
# supervisor may then overrule it (a sleep gap, a hang), and a run counts once.
record_outcome() {
  local verdict="$1" id="${2:-$RUN_ID}" ts; ts="$(date +%s)"
  local tmp="$LEDGER.tmp.$$"
  { [ -f "$LEDGER" ] && awk -F'\t' -v id="$id" '$4!=id' "$LEDGER"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$(at_time "$ts" +%Y-%m-%d)" "$verdict" "$id"; } > "$tmp"
  mv "$tmp" "$LEDGER"
}

# --- which merge route a repo takes ------------------------------------------
# `land` refuses a repo it has no deploy route for, so the sweep asks land's own
# case list rather than keeping a second list that could disagree with it.
land_supports() {
  local repo="$1"
  [ -x "$LAND" ] || return 1
  sed -n '/^case "\$NAME" in/,/^esac/p' "$LAND" \
    | grep -E '^[[:space:]]+[A-Za-z0-9_.|-]+\)' | sed -E 's/^[[:space:]]+//; s/\).*//' \
    | tr '|' '\n' | grep -qxF "$repo"
}
merge_route() { # repo -> "land" or "gh"
  if land_supports "$1" && [ -e "$GITHUB_DIR/$1/.git" ]; then echo land; else echo gh; fi
}

# --- PRs this run opened -------------------------------------------------------
# Open PRs in the repos this run was dispatched to, created since it started. These
# are the sweep's own fixes: the only PRs it may merge, and the ones it parks when a
# run is cut off.
sweep_prs_opened_this_run() {
  local repo since
  since="$(at_time_utc "$STARTED_AT" +%Y-%m-%dT%H:%M:%SZ)"
  command -v gh >/dev/null 2>&1 || return 0
  for repo in $(cat "$WORK/scope-repos" 2>/dev/null); do
    gh pr list --repo "$GH_OWNER/$repo" --state open --limit 30 --json number,createdAt,title,headRefName,isDraft \
      --jq ".[] | select(.createdAt >= \"$since\" and (.isDraft|not)) | \"$repo\t\(.number)\t\(.headRefName)\t\(.title)\"" 2>/dev/null
  done
}
pr_note() {   # repo num marker body — one note per PR per marker
  local repo="$1" num="$2" marker="$3" body="$4"
  command -v gh >/dev/null 2>&1 || return 0
  if gh pr view "$num" --repo "$GH_OWNER/$repo" --json comments --jq '.comments[].body' 2>/dev/null | grep -qF "$marker"; then
    return 0
  fi
  gh pr comment "$num" --repo "$GH_OWNER/$repo" --body "$marker
$body" >/dev/null 2>&1 || say "  (could not comment on $repo#$num)"
}
# Every PR of this run still open when the run ends non-green is named on the PR and
# in tomorrow's carryover as PARKED: not landed work, never merged by a cut-off run.
park_open_prs() {
  local why="$1" repo num branch title n=0
  while IFS=$'\t' read -r repo num branch title; do
    [ -z "$num" ] && continue
    # A PR the audit rejected already carries its REJECTED note; parking it too would
    # blur "do not merge" into "not finished".
    grep -qE "^$repo#$num	" "$WORK/rejected" 2>/dev/null && continue
    n=$((n + 1))
    printf '%s#%s\t%s\t%s\n' "$repo" "$num" "$branch" "$title" >> "$WORK/parked-prs"
    say "  PARKED PR $repo#$num ($branch): $why"
    pr_note "$repo" "$num" "[ci-sweep] PARKED — not landed work" \
      "The sweep run that opened this pull request ended without merging it: $why. The sweep does not merge it later; the next sweep run (today's 08:00 retry if this run wasn't green, otherwise tomorrow's 07:00) is told about it and re-reads it. A person may close it or take it over. Run log: $RUN_LOG"
  done < <(sweep_prs_opened_this_run)
  [ "$n" -eq 0 ] && say "  (no open PR of this run's to park in [$(tr '\n' ' ' < "$WORK/scope-repos" 2>/dev/null)])"
  return 0
}
# A PR the audit found FATAL is rejected on the PR itself — never merged, never
# closed (a close is destructive where a note is not).
reject_audited_prs() {
  local audit_file="$1" round="$2" line ref repo num why n=0
  while IFS= read -r line; do
    ref="$(printf '%s' "$line" | grep -oE 'FATAL [A-Za-z0-9._-]+#[0-9]+' | head -1 | sed 's/^FATAL //')"
    [ -z "$ref" ] && continue
    repo="${ref%#*}"; num="${ref#*#}"
    grep -qxF "$repo" "$WORK/scope-repos" 2>/dev/null || { say "  (not rejecting $ref: outside this run's scope)"; continue; }
    why="$(printf '%s' "$line" | sed 's/.*— //')"
    n=$((n + 1))
    printf '%s\t%s\n' "$ref" "$why" >> "$WORK/rejected"
    say "  REJECTED $ref: $why"
    pr_note "$repo" "$num" "[ci-sweep] REJECTED by the audit — do not merge" \
      "ci-sweep-audit.sh found a weakening in this pull request during sweep round $round: **$why**. The sweep will not merge it and ends this run. The next sweep run (today's 08:00 retry if this run wasn't green, otherwise tomorrow's 07:00) is told what was rejected and why, and goes for the root cause instead. Either fix this PR so the weakening is gone, or close it. Run log: $RUN_LOG"
  done < <(grep -E '✗ FATAL ' "$audit_file" 2>/dev/null)
  [ "$n" -eq 0 ] && say "  (the audit reported FATAL but named no PR the sweep could act on)"
  return 0
}

# =============================================================================
# THE MERGE PASS — the sweep lands its own fixes, on evidence it reads itself
# =============================================================================
# Checks as GitHub reports them for the PR's head, bucket by bucket (land's rule: a
# cancelled or failing check is not green whatever the exit code says). Prints
# green | pending | red | none. "none" — no checks at all — cannot be verified and
# is never merged.
pr_checks_state() {
  local repo="$1" num="$2" buckets
  buckets="$(gh pr checks "$num" --repo "$GH_OWNER/$repo" --json bucket --jq '.[].bucket' 2>/dev/null)"
  if [ -z "$buckets" ]; then echo none; return; fi
  if printf '%s\n' "$buckets" | grep -qx pending; then echo pending; return; fi
  if printf '%s\n' "$buckets" | grep -qvxE 'pass|skipping'; then echo red; return; fi
  echo green
}
# Watch every commit this pass merged to a TERMINAL state, success AND failure, in
# one bounded loop. Appends "repo num sha route result" to merged.tsv.
watch_merged_main() {
  local pending_file="$1" cap until_ts line repo num sha route runs res left
  [ -s "$pending_file" ] || return 0
  cap="$(capped "$MAIN_WATCH_CAP_MIN")"; until_ts=$(( $(date +%s) + cap * 60 ))
  say "  watching main for $(grep -c . "$pending_file") merge(s) to a terminal state (cap ${cap} min)"
  sleep "$(( POLL_SECS < 12 ? POLL_SECS : 12 ))"   # let GitHub register the push run
  while :; do
    left="$pending_file.left"; : > "$left"
    while IFS=$'\t' read -r repo num sha route; do
      [ -z "$repo" ] && continue
      runs="$(gh run list --repo "$GH_OWNER/$repo" --commit "$sha" --limit 20 --json status,conclusion \
                --jq '.[] | "\(.status)\t\(.conclusion)"' 2>/dev/null)"
      if [ -z "$runs" ] || printf '%s\n' "$runs" | grep -qv '^completed'; then
        if [ "$(date +%s)" -ge "$until_ts" ]; then
          res="$([ -z "$runs" ] && echo "no-run" || echo "pending")"
          printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$num" "$sha" "$route" "main:$res" >> "$WORK/merged.tsv"
          say "  $repo#$num merged as ${sha:0:9}; main is $res at the watch cap — the probe decides"
        else
          printf '%s\t%s\t%s\t%s\n' "$repo" "$num" "$sha" "$route" >> "$left"
        fi
        continue
      fi
      if printf '%s\n' "$runs" | cut -f2 | grep -qvxE 'success|skipped|neutral'; then res=failure; else res=success; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$num" "$sha" "$route" "main:$res" >> "$WORK/merged.tsv"
      say "  $repo#$num merged as ${sha:0:9}; main after it: $res"
    done < "$pending_file"
    mv "$left" "$pending_file"
    [ -s "$pending_file" ] || return 0
    sleep "$POLL_SECS"
  done
}
merge_pass() {
  local round="$1" repo num branch title ref st head sha route rc until_ts cap
  local cands="$WORK/merge-candidates-$round.tsv" watch="$WORK/merge-watch-$round.tsv"
  sweep_prs_opened_this_run > "$cands"; : > "$watch"
  if [ ! -s "$cands" ]; then say "merge pass: no open PR of this run's to consider"; return 0; fi
  cap="$(capped "$MERGE_CHECKS_CAP_MIN")"; until_ts=$(( $(date +%s) + cap * 60 ))
  while IFS=$'\t' read -r repo num branch title; do
    [ -z "$num" ] && continue
    ref="$repo#$num"
    if grep -qE "^$ref	" "$WORK/rejected" 2>/dev/null; then say "  $ref: REJECTED by the audit — not merging"; continue; fi
    if grep -qF "? SUSPECT $ref " "$WORK"/audit-*.txt 2>/dev/null; then
      say "  $ref: the audit named it SUSPECT — left open for a person, not merged"; continue
    fi
    if awk -F'\t' -v r="$repo" '$1==r{f=1} END{exit !f}' "$WORK/parked-repos.tsv" 2>/dev/null; then
      say "  $ref: $repo is PARKED on her decision — left open, not merged"; continue
    fi
    # Checks still running are waited for, inside one shared cap for the pass.
    while :; do
      st="$(pr_checks_state "$repo" "$num")"
      [ "$st" = pending ] && [ "$(date +%s)" -lt "$until_ts" ] && { sleep "$POLL_SECS"; continue; }
      break
    done
    case "$st" in
      green) : ;;
      pending) say "  $ref: checks still running at the ${cap}-min cap — left open; the next round's merge pass re-reads it"; continue ;;
      none)    say "  $ref: GitHub reports no checks on it, so green cannot be verified — not merging"; continue ;;
      *)       say "  $ref: checks are $st (read with gh pr checks) — not merging"; continue ;;
    esac
    route="$(merge_route "$repo")"
    if [ "$route" = land ]; then
      say "  $ref: checks green (gh pr checks) — landing with \`land $num\` (merges, watches main, deploys)"
      ( cd "$GITHUB_DIR/$repo" && timeout --signal=TERM --kill-after=30 "$(capped "$MAIN_WATCH_CAP_MIN")m" "$LAND" "$num" ) \
        > "$WORK/land-$repo-$num.log" 2>&1; rc=$?
      sed 's/^/    [land] /' "$WORK/land-$repo-$num.log" >> "$RUN_LOG"
      sha="$(gh pr view "$num" --repo "$GH_OWNER/$repo" --json state,mergeCommit --jq 'select(.state=="MERGED") | .mergeCommit.oid' 2>/dev/null)"
      if [ -z "$sha" ]; then
        say "  $ref: land refused (rc=$rc) — not merged; see [land] lines above"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$num" "$sha" land "main:$([ "$rc" -eq 0 ] && echo success || echo "land-rc-$rc")" >> "$WORK/merged.tsv"
        say "  $ref: LANDED as ${sha:0:9} (land rc=$rc)"
      fi
    else
      head="$(gh pr view "$num" --repo "$GH_OWNER/$repo" --json headRefOid --jq .headRefOid 2>/dev/null)"
      say "  $ref: checks green (gh pr checks) — merging with gh pr merge --merge --delete-branch"
      if gh pr merge "$num" --repo "$GH_OWNER/$repo" --merge --delete-branch ${head:+--match-head-commit "$head"} >> "$RUN_LOG" 2>&1; then
        sha="$(gh pr view "$num" --repo "$GH_OWNER/$repo" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null)"
        printf '%s\t%s\t%s\t%s\n' "$repo" "$num" "${sha:-unknown}" gh >> "$watch"
      else
        say "  $ref: gh pr merge refused — not merged"
      fi
    fi
  done < "$cands"
  watch_merged_main "$watch"
  return 0
}

# =============================================================================
# THE SUMMARY — one per run, green or not
# =============================================================================
# Classifies every repo the last probe saw: green (never red this run), fixed (red
# at the start, green now; with the PRs the sweep merged), parked (red, waiting on
# her decision), stuck (red, not parked), pending (in flight). Writes summary.txt,
# issues.tsv (PARKED and STUCK lines for the notifier) and sets SUMMARY_LINE.
SUMMARY_LINE=""
build_summary() {
  local first="$WORK/probe-0.tsv" last cls
  last="$(ls -1 "$WORK"/probe-*.tsv 2>/dev/null | sort -V | tail -1)"
  : > "$WORK/issues.tsv"
  if [ -z "$last" ]; then
    SUMMARY_LINE="fleet state was not read this run"
    echo "$SUMMARY_LINE" > "$WORK/summary.txt"
    return 0
  fi
  cls="$WORK/classified.tsv"
  awk -F'\t' -v first="$first" -v parked="$WORK/parked-repos.tsv" -v merged="$WORK/merged.tsv" '
    BEGIN {
      while ((getline l < first) > 0)  { split(l, a, "\t"); if (a[1]=="RED" || a[1]=="SILENT") startred[a[2]]=1 }
      while ((getline l < parked) > 0) { split(l, a, "\t"); if (!(a[1] in pk)) pk[a[1]]=a[2] }
      while ((getline l < merged) > 0) { split(l, a, "\t"); prs[a[1]] = prs[a[1]] (prs[a[1]] ? ", " : "") "#" a[2] }
    }
    NF >= 2 && $1 ~ /^(GREEN|RED|SILENT|PENDING|QUIET|NOCI)$/ {
      seen[$2]=1
      if ($1=="RED" || $1=="SILENT") { red[$2]=1; lanes[$2] = lanes[$2] (lanes[$2] ? "; " : "") $3 " " $1 }
      if ($1=="PENDING") pend[$2]=1
    }
    END {
      for (r in seen) {
        if (r in red) {
          if (r in pk) print "parked\t" r "\t" pk[r]
          else         print "stuck\t" r "\t" lanes[r] ((r in prs) ? " (merged " prs[r] ", still red)" : "")
        } else if (r in pend) print "pending\t" r "\t" ((r in prs) ? prs[r] : "")
        else if (r in startred) print "fixed\t" r "\t" ((r in prs) ? prs[r] : "no PR merged by the sweep")
        else print "green\t" r "\t"
      }
    }' "$last" | sort > "$cls"
  local g f p s pe
  g="$(awk -F'\t' '$1=="green"{printf "%s%s", (n++?", ":""), $2}' "$cls")"
  f="$(awk -F'\t' '$1=="fixed"{printf "%s%s (%s)", (n++?", ":""), $2, $3}' "$cls")"
  p="$(awk -F'\t' '$1=="parked"{printf "%s%s — %s", (n++?"; ":""), $2, $3}' "$cls")"
  s="$(awk -F'\t' '$1=="stuck"{printf "%s%s — %s", (n++?"; ":""), $2, $3}' "$cls")"
  pe="$(awk -F'\t' '$1=="pending"{printf "%s%s", (n++?", ":""), $2}' "$cls")"
  {
    echo "green ($(awk -F'\t' '$1=="green"' "$cls" | grep -c .)): ${g:-none}"
    echo "fixed this run: ${f:-none}"
    echo "parked on her decision: ${p:-none}"
    echo "stuck: ${s:-none}"
    [ -n "$pe" ] && echo "in flight (unproven, not red): $pe"
  } > "$WORK/summary.txt"
  SUMMARY_LINE="$(tr '\n' '|' < "$WORK/summary.txt" | sed 's/|$//; s/|/ | /g')"
  awk -F'\t' -v OFS='\t' '$1=="parked"{print "PARKED", $2, $3} $1=="stuck"{print "STUCK", $2, $3}' "$cls" > "$WORK/issues.tsv"
}

# What tomorrow's round 1 is told. Written by every non-green outcome.
write_next_carryover() {
  local verdict="$1" detail="$2" last_probe last_audit last_round
  last_probe="$(ls -1 "$WORK"/probe-*.tsv 2>/dev/null | sort -V | tail -1)"
  last_audit="$(ls -1 "$WORK"/audit-*.txt 2>/dev/null | sort -V | tail -1)"
  last_round="$(ls -1 "$WORK"/round-*.log 2>/dev/null | sort -V | tail -1)"
  {
    echo "# THE PREVIOUS DAILY RUN DID NOT REACH GREEN — read this before anything else"
    echo
    echo "Verdict of the last run ($RUN_ID): **$verdict** — $detail"
    echo
    echo "## Where the fleet stood when it ended"
    sed 's/^/- /' "$WORK/summary.txt" 2>/dev/null
    echo
    if [ -s "$WORK/rejected" ]; then
      echo "## REJECTED by the audit — these PRs contain a weakening. DO NOT MERGE THEM."
      echo "Go for the ROOT CAUSE. Fix the named PR so the weakening is gone, or close it and"
      echo "open a proper one; merging it as-is is the one thing you may not do."
      awk -F'\t' '{print "  - " $1 ": " $2}' "$WORK/rejected"
      echo
    fi
    if [ -s "$WORK/parked-repos.tsv" ]; then
      echo "## PARKED repos — waiting on her. Re-check whether the decision has been made"
      echo "(look for an OWNER DECISIONS section below, or the issue filed on the repo);"
      echo "if not, park them again in one line and move on."
      awk -F'\t' '{print "  - " $1 ": " $2}' "$WORK/parked-repos.tsv"
      echo
    fi
    if [ -s "$WORK/parked-prs" ]; then
      echo "## PARKED PRs — opened by the last run and NOT merged, NOT verified"
      echo "Read them before doing anything else in that repo: reuse what is sound, close"
      echo "what is not. The sweep only merges PRs its own run opened, so reuse means a new PR."
      awk -F'\t' '{print "  - " $1 " (" $2 "): " $3}' "$WORK/parked-prs"
      echo
    fi
    if [ -n "$last_probe" ]; then
      echo "## What was not green when the last run looked (straight from GitHub)"
      echo '```'; grep -E '^(RED|SILENT)	' "$last_probe" || echo "(no red lanes)"; echo '```'
      echo
    fi
    if [ -n "$last_audit" ]; then
      echo "## What the last run's audit said"
      echo '```'; tail -c 3000 "$last_audit"; echo '```'
      echo
    fi
    if [ -n "$last_round" ]; then
      echo "## The last run's own account of what it tried (tail)"
      echo '```'; tail -c 6000 "$last_round"; echo '```'
      echo
    fi
    echo "## The rails have not loosened"
    echo "No re-running, pinning, skipping, xfail, continue-on-error, \`|| true\` or deleted"
    echo "assertions. The audit reads every round's diff. A named stop beats a false green."
  } > "$NEXT_CARRY"
}

# Everything a completed run does with its verdict, from whichever process reached
# it. The body calls it through finish(); the supervisor for the outcomes only it
# can see (interrupted, hung, could-not-run).
conclude() {
  local verdict="$1" detail="$2"
  ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
  echo "$verdict" > "$WORK/verdict" 2>/dev/null
  build_summary
  # Per-repo STUCK issues only when the fleet state was actually read at the end.
  # A hung, interrupted or could-not-run run files one run-level issue instead.
  case "$verdict" in
    MAIN-RED-STUCK|MAIN-RED-TIMEOUT|MAIN-RED-BLOCKED) : ;;
    *) grep -v '^STUCK	' "$WORK/issues.tsv" > "$WORK/issues.tsv.tmp" 2>/dev/null; mv "$WORK/issues.tsv.tmp" "$WORK/issues.tsv" ;;
  esac
  say "=== morning summary ==="
  sed 's/^/    /' "$WORK/summary.txt" | tee -a "$RUN_LOG"
  say "    verdict: $verdict — $detail"
  record_outcome "$verdict"
  if [ "$verdict" = "MAIN-GREEN" ]; then
    rm -f "$NEXT_CARRY"
  else
    write_next_carryover "$verdict" "$detail"
  fi
  # ALWAYS NOTIFY. One banner every morning, green or not; issues only for parked
  # or stuck repos and run-level faults. A green run files nothing.
  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" "$verdict" "$SUMMARY_LINE" "$RUN_LOG" "$WORK/issues.tsv" "$detail" >>"$RUN_LOG" 2>&1 || \
      echo "[notify] at least one channel failed; see above" >> "$RUN_LOG"
  else
    echo "[notify] NAMED STOP [NO_NOTIFIER] $NOTIFY is missing — she was not told." >> "$RUN_LOG"
  fi
  # Tell her (and tomorrow's reader) exactly what fires next: the 08:00 retry
  # only exists for a repo's FIRST non-green run of the day, so read the
  # ledger — the same source ci-sweep-retry-if-red.sh reads — rather than
  # assuming.
  today_rows=0
  [ -f "$LEDGER" ] && today_rows="$(awk -F'\t' -v d="$(at_time "$(date +%s)" +%Y-%m-%d)" '$2==d' "$LEDGER" | grep -c .)"
  if [ "$verdict" = "MAIN-GREEN" ]; then
    next_note="07:00 tomorrow (launchd com.seq.ci-sweep). Nothing else runs today."
  elif [ "$today_rows" -ge 2 ]; then
    next_note="07:00 tomorrow (launchd com.seq.ci-sweep). Today's one retry already ran and was not green; nothing more today."
  else
    next_note="08:00 today, once (launchd com.seq.ci-sweep-retry -> ci-sweep-retry-if-red.sh) — this run did not end green."
  fi
  echo "[$(date +%H:%M:%S)] next run: $next_note" >> "$RUN_LOG"
  # THE LAST LINE: the verdict and the morning summary, written by bash from what
  # GitHub said, never by the model.
  echo "CI-SWEEP-COMPLETE: $verdict — $SUMMARY_LINE" | tee -a "$RUN_LOG"
}

# Minutes left in the budget, floored at 0.
remaining_min() {
  local left=$(( (DEADLINE_AT - $(date +%s)) / 60 ))
  [ "$left" -lt 0 ] && left=0
  echo "$left"
}
capped() {
  local want="$1" left; left="$(remaining_min)"
  [ "$want" -gt "$left" ] && want="$left"
  echo "$want"
}

finish() {
  conclude "$1" "$2"
  case "$1" in
    MAIN-GREEN) exit 0 ;;
    MAIN-PENDING) exit 2 ;;   # unproven, not red: the probe's own "still pending" code
    *) exit 20 ;;
  esac
}

# --- probe main, waiting for in-flight runs to reach a TERMINAL state ---------
# Writes lanes to $1. Returns 0 green, 1 red/silent, 2 still pending at the cap,
# 3 named stop. Breaks on EITHER outcome: a loop watching only for success hangs
# silently through a crash.
probe_main() {
  local out="$1" cap_min; cap_min="$(capped "$VERIFY_CAP_MIN")"
  local until_ts=$(( $(date +%s) + cap_min * 60 )) rc=0
  while :; do
    "$PROBE" > "$out" 2>>"$RUN_LOG"; rc=$?
    [ "$rc" -eq 3 ] && return 3
    [ "$rc" -ne 2 ] && return "$rc"
    if [ "$(date +%s)" -ge "$until_ts" ]; then
      # IN FLIGHT IS NOT RED (west-peek-os#157, 21 Sep 2026).
      say "  runs still in flight after ${cap_min} min; those lanes are UNPROVEN, not red."
      return 2
    fi
    say "  runs in flight; re-checking in 60s (until $(at_time "$until_ts" +%H:%M))"
    sleep 60
  done
}

# =============================================================================
# DRY RUN — what the run would do, without dispatching anything
# =============================================================================
# CI_SWEEP_DRY_RUN=1 ~/bin/ci-sweep.sh : reads the fleet through the real probe
# (read-only), then prints the budget, the model, which repos round 1 would
# dispatch to, which are parked from yesterday, and the merge route per repo. No
# lock, no claude, no PR, no merge, no notification.
if [ -n "${CI_SWEEP_DRY_RUN:-}" ]; then
  echo "[dry-run] schedule: 07:00 CT (launchd com.seq.ci-sweep), one retry at 08:00 if not green (launchd com.seq.ci-sweep-retry); at most one retry, then nothing retries before the next day"
  echo "[dry-run] model: every claude -p runs --model opus; every fixing agent is spawned with model opus"
  echo "[dry-run] budget: ${DEADLINE_MIN} min convergence, hard kill at ${HARD_KILL_MIN} awake min; round 1 cap ${ROUND1_CAP_MIN} min, later rounds ${ROUNDN_CAP_MIN} min"
  echo "[dry-run] rounds continue while a round makes progress; STUCK after ${NO_PROGRESS_LIMIT} consecutive rounds without"
  [ -x "$PROBE" ] || { echo "[dry-run] NAMED STOP [NO_PROBE] $PROBE"; exit 13; }
  DRY_OUT="$(mktemp)"; trap 'rm -f "$DRY_OUT"' EXIT
  "$PROBE" > "$DRY_OUT" 2>/dev/null; DRC=$?
  [ "$DRC" -eq 3 ] && { echo "[dry-run] NAMED STOP [PROBE_STOPPED] the probe could not read the fleet"; exit 3; }
  echo "[dry-run] probe: $(grep -cE '^GREEN	' "$DRY_OUT") green lane(s), $(grep -cE '^(RED|SILENT)	' "$DRY_OUT") red/silent, $(grep -cE '^PENDING	' "$DRY_OUT") in flight"
  DRY_RED="$(grep -E '^(RED|SILENT)	' "$DRY_OUT" | cut -f2 | sort -u)"
  if [ -z "$DRY_RED" ]; then
    echo "[dry-run] decision: nothing red — the run would report MAIN-GREEN$( [ "$DRC" -eq 2 ] && echo ' after waiting for in-flight lanes (or MAIN-PENDING)') and dispatch nothing"
  else
    echo "[dry-run] decision: round 1 would dispatch one opus agent per red repo:"
    for r in $DRY_RED; do
      echo "[dry-run]   $r — $(grep -E "^(RED|SILENT)	$r	" "$DRY_OUT" | cut -f3 | tr '\n' ';' | sed 's/;$//') — merge route: $(merge_route "$r")"
    done
  fi
  if [ -f "$NEXT_CARRY" ]; then
    echo "[dry-run] round 1 would be briefed with yesterday's carryover ($NEXT_CARRY, $(wc -c < "$NEXT_CARRY" | tr -d ' ') bytes)"
  fi
  exit 0
fi

# =============================================================================
# SUPERVISOR — the ceiling is enforced from OUTSIDE the work, by the kernel
# =============================================================================
# 2026-09-08: a deadline checked by the process doing the work only bounds a
# process that is still working; the run sat six hours inside a `claude` that never
# returned. So a supervisor that is NOT doing the work runs the body in its own
# process group (python setsid; macOS ships no setsid binary), owns the lock, and
# kills the whole group at the ceiling. A hang is a named outcome (MAIN-RED-HUNG).
if [ -z "${CI_SWEEP_SUPERVISED:-}" ]; then
  mkdir -p "$WORK"

  # --- single-flight, heartbeat-based reclaim ----------------------------------
  # A wedged holder is alive but not working; the supervisor ticks $LOCK/heartbeat
  # every 20s, so a stale heartbeat means dead, wedged or pre-supervisor.
  LOCK_STALE_AFTER="${CI_SWEEP_LOCK_STALE_AFTER:-180}"   # 9x the 20s tick
  LOCK_MAX_AGE=$(( HARD_KILL_MIN * 60 + 300 ))
  if ! mkdir "$LOCK" 2>/dev/null; then
    holder="$(cat "$LOCK/pid" 2>/dev/null || echo "")"
    beat="$(cat "$LOCK/heartbeat" 2>/dev/null || echo 0)"
    started="$(cat "$LOCK/started" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    reclaim=""
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
      reclaim="its process is gone"
    elif [ "$beat" -eq 0 ]; then
      reclaim="its lock has no heartbeat, so it predates the supervisor and cannot be shown to be alive rather than merely running"
    elif [ $(( now - beat )) -gt "$LOCK_STALE_AFTER" ]; then
      # A stale heartbeat at wake is the holder's sentry about to end that run as
      # INTERRUPTED. Give it two ticks before calling it wedged.
      sleep $(( LOCK_STALE_AFTER / 3 ))
      beat="$(cat "$LOCK/heartbeat" 2>/dev/null || echo 0)"; now="$(date +%s)"
      if ! kill -0 "$holder" 2>/dev/null; then
        reclaim="its process ended while this run waited (it recorded its own outcome)"
      elif [ $(( now - beat )) -le "$LOCK_STALE_AFTER" ]; then
        reclaim=""
      else
        reclaim="its heartbeat is $(( now - beat ))s stale (>${LOCK_STALE_AFTER}s) — the holder is wedged, not working"
      fi
    elif [ "$started" -gt 0 ] && [ $(( now - started )) -gt "$LOCK_MAX_AGE" ]; then
      reclaim="it has run $(( now - started ))s, past the ${LOCK_MAX_AGE}s ceiling"
    fi
    if [ -z "$reclaim" ]; then
      say "NAMED STOP [SWEEP_ALREADY_RUNNING] pid $holder, heartbeat $(( now - beat ))s ago — a healthy sweep is running; not starting a second."
      exit 0
    fi
    say "reclaiming the lock from pid ${holder:-none}: $reclaim."
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      kill -TERM "-$holder" 2>/dev/null || kill -TERM "$holder" 2>/dev/null
      sleep 5
      kill -KILL "-$holder" 2>/dev/null || kill -KILL "$holder" 2>/dev/null
      old_id="$(cat "$LOCK/run-id" 2>/dev/null || echo "")"
      if [ -n "$old_id" ]; then
        record_outcome "MAIN-RED-RECLAIMED" "$old_id"
        say "recorded $old_id as MAIN-RED-RECLAIMED (it was killed here without a verdict)."
      fi
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { say "FAILED to take lock"; exit 3; }
  fi
  echo $$ > "$LOCK/pid"
  echo "$RUN_ID" > "$LOCK/run-id"
  echo "$STARTED_AT" > "$LOCK/started"
  date +%s > "$LOCK/heartbeat"
  release_lock() { [ "$(cat "$LOCK/pid" 2>/dev/null || echo)" = "$$" ] && rm -rf "$LOCK"; }

  say "=== CI sweep supervisor: convergence budget ${DEADLINE_MIN} min, hard kill at ${HARD_KILL_MIN} awake min ($(at_time "$KILL_AT" +%H:%M)) ==="

  export CI_SWEEP_SUPERVISED=1 CI_SWEEP_RUN_ID="$RUN_ID" CI_SWEEP_STARTED_AT="$STARTED_AT"

  /usr/bin/python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      /bin/bash "$0" "$@" &
  BODY=$!

  # THE SENTRY: heartbeat, watchdog and sleep detector in one loop. The ceiling is
  # counted in TICKS (awake time), never read from the wall clock (2026-09-21: a
  # 10:40-12:25 sleep made a wall-clock watchdog call an awake-35-minute run HUNG).
  # A gap > SLEEP_GAP_SECS between two of its own stamps is the Mac having slept:
  # the round in flight is a half round, so the run ends as INTERRUPTED and its
  # open PRs are parked, never merged.
  : > "$WORK/heartbeats"
  ( prev="$(date +%s)"; ticks=0; limit=$(( HARD_KILL_MIN * 60 / TICK_SECS ))
    sh -c 'echo $PPID' > "$WORK/sentry-pid"
    while :; do
      sleep "$TICK_SECS"
      now="$(date +%s)"; ticks=$(( ticks + 1 ))
      date +%s > "$LOCK/heartbeat" 2>/dev/null || exit 0
      echo "$now" >> "$WORK/heartbeats"
      if [ $(( now - prev )) -gt "$SLEEP_GAP_SECS" ]; then
        echo "no heartbeat for $(( now - prev ))s, from $(at_time "$prev" +%H:%M:%S) to $(at_time "$now" +%H:%M:%S) — the Mac was asleep" > "$WORK/interrupted"
        kill -TERM "-$BODY" 2>/dev/null; sleep 20; kill -KILL "-$BODY" 2>/dev/null; exit 0
      fi
      prev="$now"
      if [ "$ticks" -ge "$limit" ]; then
        echo "$ticks ticks of ${TICK_SECS}s awake" > "$WORK/hung"
        kill -TERM "-$BODY" 2>/dev/null; sleep 20; kill -KILL "-$BODY" 2>/dev/null; exit 0
      fi
    done ) >/dev/null 2>&1 & SENTRY=$!

  wait "$BODY"; RC=$?
  disown "$SENTRY" 2>/dev/null
  kill "$SENTRY" 2>/dev/null
  ELAPSED=$(( $(date +%s) - STARTED_AT ))
  ASLEEP="$(awk -v gap="$SLEEP_GAP_SECS" -v tick="$TICK_SECS" 'NR>1 && $1-p>gap {s+=$1-p-tick} {p=$1} END{print s+0}' "$WORK/heartbeats")"
  AWAKE=$(( ELAPSED - ASLEEP ))
  BODY_VERDICT="$(cat "$WORK/verdict" 2>/dev/null || echo "")"

  if [ -f "$WORK/interrupted" ] && [ "$BODY_VERDICT" != "MAIN-GREEN" ]; then
    kill -KILL "-$BODY" 2>/dev/null
    say "=== INTERRUPTED: $(cat "$WORK/interrupted") (rc=$RC, ${ELAPSED}s wall, ${AWAKE}s awake) ==="
    say "--- parking anything the cut-off round left open ---"
    park_open_prs "the Mac slept mid-round ($(cat "$WORK/interrupted"))"
    conclude "MAIN-RED-INTERRUPTED" "the Mac slept during the sweep ($(cat "$WORK/interrupted")), so the round in flight was ended, not finished. Nothing it half-did counts as landed; its open PRs are parked and never merged. Main's state is UNVERIFIED — treat it as red. Not a hang: the run was awake ${AWAKE}s of ${ELAPSED}s."
    release_lock
    exit 22
  fi

  if [ -f "$WORK/hung" ] || [ "$AWAKE" -ge $(( HARD_KILL_MIN * 60 )) ] || [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ]; then
    kill -KILL "-$BODY" 2>/dev/null
    say "=== HUNG: the sweep did not finish within ${HARD_KILL_MIN} awake minutes and was killed from outside (rc=$RC, ${AWAKE}s awake of ${ELAPSED}s) ==="
    say "--- parking anything the killed round left open ---"
    park_open_prs "the sweep hung and was killed at its ${HARD_KILL_MIN}-minute ceiling"
    conclude "MAIN-RED-HUNG" "the sweep was still running after ${HARD_KILL_MIN} awake minutes and was killed by its sentry. Main's state is UNVERIFIED — treat it as red. Its open PRs are parked. The last thing it logged is at the bottom of $RUN_LOG."
    release_lock
    exit 21
  fi

  # A precondition stop (no claude, no gh, not authenticated, keychain locked) exits
  # non-zero without reaching finish(); it is the case where nothing is watching CI.
  # Exit 2 is the body's own MAIN-PENDING, already concluded.
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 20 ] && [ "$RC" -ne 2 ]; then
    conclude "MAIN-UNKNOWN" "the sweep could not run at all (exit $RC) — see the NAMED STOP line in $RUN_LOG. Until it is cleared, nothing is watching CI."
  fi

  release_lock
  exit "$RC"
fi
# =============================================================================
# BODY — everything below runs supervised, inside the process group above
# =============================================================================

# --- preconditions, each a named stop rather than a crash --------------------
CLAUDE="${CI_SWEEP_CLAUDE_BIN:-$(command -v claude || echo /opt/homebrew/bin/claude)}"
[ -x "$CLAUDE" ] || { say "NAMED STOP [NO_CLAUDE_CLI] not executable: $CLAUDE"; exit 4; }
[ -f "$PROMPT_FILE" ] || { say "NAMED STOP [NO_PROMPT_FILE] missing: $PROMPT_FILE"; exit 5; }
if ! command -v gh >/dev/null 2>&1; then
  say "NAMED STOP [NO_GH_CLI] the sweep cannot read GitHub without gh."; exit 6
fi
if ! gh auth status >/dev/null 2>&1; then
  say "NAMED STOP [GH_NOT_AUTHENTICATED] run: gh auth login"; exit 7
fi
# Claude's credentials live in the login keychain, which is locked at the login window.
if ! security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  say "NAMED STOP [CLAUDE_NOT_AUTHENTICATED] cannot read Claude credentials from the login keychain."
  say "  Either the Mac is at the login window with the keychain locked, or the session was signed out."
  say "  Fix: log in to macOS, then run 'claude' once and confirm it starts."
  exit 10
fi
[ -x "$PROBE" ] || { say "NAMED STOP [NO_PROBE] $PROBE missing — nothing could verify main is green."; exit 13; }
[ -x "$AUDIT" ] || { say "NAMED STOP [NO_AUDITOR] $AUDIT is missing, so nothing would verify that the fixes were real."; exit 12; }
cd "$GITHUB_DIR" || { say "NAMED STOP [NO_GITHUB_DIR] $GITHUB_DIR"; exit 8; }

say "=== CI sweep starting ($STAMP) ==="
say "claude: $CLAUDE (--model opus)"
say "budget: ${DEADLINE_MIN} min (stop by $(at_time "$DEADLINE_AT" +%H:%M)); rounds while progress, STUCK after ${NO_PROGRESS_LIMIT} without"
say "work dir: $WORK"

# --- the convergence loop ----------------------------------------------------
round=0
no_progress=0
prev_keys=""          # unparked red lanes (repo|workflow) at the previous probe
prev_sigs=""          # their failure signatures
: > "$WORK/parked-repos.tsv"; : > "$WORK/scope-repos"; : > "$WORK/merged.tsv"
PROGRESS_LOG="$WORK/progress.tsv"; : > "$PROGRESS_LOG"

while :; do
  say "--- probing main (after round $round) ---"
  PROBE_OUT="$WORK/probe-$round.tsv"
  probe_main "$PROBE_OUT"; PRC=$?
  if [ "$PRC" -eq 3 ]; then
    finish "MAIN-UNKNOWN" "the probe could not read the fleet (named stop above); main's state is UNVERIFIED — treat as red."
  fi

  ALL_RED="$(grep -E '^(RED|SILENT)	' "$PROBE_OUT" || true)"
  # Lanes in a PARKED repo wait on her; they are reported, never worked again this run.
  RED_LINES="$(printf '%s\n' "$ALL_RED" | awk -F'\t' -v pf="$WORK/parked-repos.tsv" '
    BEGIN { while ((getline l < pf) > 0) { split(l, a, "\t"); pk[a[1]]=1 } }
    NF && !($2 in pk)')"

  if [ -z "$ALL_RED" ]; then
    if [ "$PRC" -eq 2 ]; then
      PENDING_LINES="$(grep -E '^PENDING	' "$PROBE_OUT" || true)"
      finish "MAIN-PENDING" "nothing is red, but $(printf '%s\n' "$PENDING_LINES" | grep -c .) lane(s) had not reached a terminal state at the ${VERIFY_CAP_MIN}-minute cap: $(printf '%s\n' "$PENDING_LINES" | cut -f2,3 | tr '\t' '/' | tr '\n' ';'). Unproven, not red."
    fi
    finish "MAIN-GREEN" "all $(grep -cE '^GREEN	' "$PROBE_OUT") lane(s) green on main after $round fixing round(s)."
  fi
  if [ -z "$RED_LINES" ]; then
    park_open_prs "its repo is parked on her decision, so the sweep did not merge it"
    finish "MAIN-RED-BLOCKED" "every repo still red is parked on her decision, after $round round(s): $(awk -F'\t' '{printf "[%s] %s; ", $1, $2}' "$WORK/parked-repos.tsv")"
  fi

  RED_COUNT="$(printf '%s\n' "$RED_LINES" | grep -c . )"
  RED_REPOS="$(printf '%s\n' "$RED_LINES" | cut -f2 | sort -u | tr '\n' ' ')"
  # Scope: every repo this run dispatched to, across rounds — what the audit reads,
  # what the merge pass may merge in, and what is parked if the run is cut off.
  { cat "$WORK/scope-repos"; printf '%s\n' "$RED_LINES" | cut -f2; } | grep . | sort -u > "$WORK/scope-repos.tmp"
  mv "$WORK/scope-repos.tmp" "$WORK/scope-repos"
  say "$RED_COUNT lane(s) NOT green, in: $RED_REPOS$( [ -s "$WORK/parked-repos.tsv" ] && printf '(parked, not worked: %s)' "$(cut -f1 "$WORK/parked-repos.tsv" | tr '\n' ' ')")"
  printf '%s\n' "$RED_LINES" | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null

  # --- did the last round make progress? ----------------------------------------
  # PROGRESS = a lane that was red (and unparked) is no longer in the working set,
  # OR a red lane shows a failure signature not seen at the previous probe (a new
  # root cause surfaced). Parking a repo removes its lanes, which counts.
  cur_keys="$(printf '%s\n' "$RED_LINES" | awk -F'\t' 'NF{print $2 "|" $3}' | sort -u)"
  cur_sigs="$(printf '%s\n' "$RED_LINES" | cut -f4 | grep . | sort -u)"
  if [ "$round" -gt 0 ]; then
    gone="$(comm -23 <(printf '%s\n' "$prev_keys" | grep .) <(printf '%s\n' "$cur_keys" | grep .) | tr '\n' ' ')"
    newsig="$(comm -13 <(printf '%s\n' "$prev_sigs" | grep .) <(printf '%s\n' "$cur_sigs" | grep .) | tr '\n' ' ')"
    if [ -n "${gone// /}" ] || [ -n "${newsig// /}" ]; then
      no_progress=0
      say "round $round made PROGRESS — cleared: [${gone% }] new signature(s): [${newsig% }]"
      printf '%s\tprogress\tcleared=%s\tnew=%s\n' "$round" "${gone% }" "${newsig% }" >> "$PROGRESS_LOG"
    else
      no_progress=$((no_progress + 1))
      say "round $round made NO progress ($no_progress consecutive): the same lanes failed with the same signatures"
      printf '%s\tnone\t%s\n' "$round" "$no_progress" >> "$PROGRESS_LOG"
    fi
  fi
  prev_keys="$cur_keys"; prev_sigs="$cur_sigs"

  # --- stops ----------------------------------------------------------------------
  if [ "$no_progress" -ge "$NO_PROGRESS_LIMIT" ]; then
    park_open_prs "the run ended STUCK before this PR's fix was verified"
    finish "MAIN-RED-STUCK" "$RED_COUNT lane(s) red in [$RED_REPOS] did not change across $NO_PROGRESS_LIMIT consecutive rounds, so this needs a decision, not another round. Signatures: $(printf '%s' "$cur_sigs" | tr '\n' ';')"
  fi
  LEFT="$(remaining_min)"
  if [ "$LEFT" -lt 10 ]; then
    park_open_prs "the run reached its ${DEADLINE_MIN}-minute budget before this PR's fix was verified"
    finish "MAIN-RED-TIMEOUT" "$RED_COUNT lane(s) still red in [$RED_REPOS]; the ${DEADLINE_MIN}-minute budget was reached after $round round(s)."
  fi

  # --- brief the next round ------------------------------------------------------
  round=$((round + 1))
  CARRY="$WORK/carryover-$round.md"
  if [ "$round" -eq 1 ]; then
    CAP="$(capped "$ROUND1_CAP_MIN")"; BG=$((50 * 60000))
    : > "$CARRY"
    # Yesterday's carryover (and any OWNER DECISIONS appended to it) is round 1's
    # opening brief. Consumed here so it cannot be fed twice.
    if [ -f "$NEXT_CARRY" ]; then
      mv "$NEXT_CARRY" "$WORK/carryover-from-previous-run.md"
      cat "$WORK/carryover-from-previous-run.md" > "$CARRY"
      say "round 1 briefed with the previous run's carryover ($(wc -c < "$CARRY" | tr -d ' ') bytes)."
    fi
  else
    CAP="$(capped "$ROUNDN_CAP_MIN")"; BG=$((32 * 60000))
    {
      echo "# ROUND $round — THE PREVIOUS ROUND DID NOT REACH GREEN"
      echo
      echo "You already worked these repos in round $((round-1)). **Main is still red.** Do not"
      echo "repeat what you already tried; the point of this round is a DIFFERENT hypothesis."
      echo "Rounds continue while they make progress; ${NO_PROGRESS_LIMIT} rounds in a row that change"
      echo "nothing end the run as STUCK. About $(remaining_min) minutes of budget are left."
      echo
      echo "## Prefer the agent you already have"
      echo "This is the SAME session, so ListAgents still shows the agents from earlier rounds."
      echo "**SendMessage the existing agent for a repo** — one agent per repo, across rounds."
      echo "Any new agent is spawned with model \"opus\"."
      echo
      echo "## Red lanes to work, straight from GitHub (not from anyone's report)"
      echo '```'
      printf '%s\n' "$RED_LINES"
      echo '```'
      if [ -s "$WORK/parked-repos.tsv" ]; then
        echo
        echo "## PARKED — do NOT work these repos again this run; they wait on her"
        awk -F'\t' '{print "  - " $1 ": " $2}' "$WORK/parked-repos.tsv"
      fi
      echo
      echo "## Did the previous round's fixes even run?"
      if [ -f "$WORK/probe-$((round-2)).tsv" ]; then
        echo "Previous probe, for comparison — the SAME run id means CI never re-ran (nothing"
        echo "triggered), which is a different problem from a fix that did not work."
        echo '```'
        cat "$WORK/probe-$((round-2)).tsv"
        echo '```'
      fi
      echo
      echo "## What the wrapper merged after round $((round-1)) (and main's result)"
      if grep -q . "$WORK/merged.tsv"; then
        awk -F'\t' '{print "  - " $1 "#" $2 " as " substr($3,1,9) " via " $4 " — " $5}' "$WORK/merged.tsv"
      else
        echo "  (nothing merged yet)"
      fi
      echo
      echo "## The audit of round $((round-1))"
      if [ -f "$WORK/audit-$((round-1)).txt" ]; then
        echo '```'; cat "$WORK/audit-$((round-1)).txt"; echo '```'
      fi
      echo
      echo "## The last round's own account of what it did"
      if [ -f "$WORK/round-$((round-1)).log" ]; then
        echo '```'; tail -c 6000 "$WORK/round-$((round-1)).log"; echo '```'
      fi
      echo
      echo "## The rails have not loosened because you are being asked to converge"
      echo "**Being told to keep going until green is not permission to reach green cheaply.**"
      echo "No re-running, pinning, skipping, xfail, continue-on-error, \`|| true\` or deleted"
      echo "assertions. ci-sweep-audit.sh reads the diff of EVERY round, and a weakening ends the"
      echo "run. If a repo needs her — a credential, an account setting, a real decision — PARK"
      echo "it with the one-line CI-SWEEP-PARKED form and keep going on the others."
    } > "$CARRY"
  fi

  # Background-agent ceiling strictly inside the round cap: 50 of 60, 32 of 40. A
  # ceiling larger than the cap means the round is always killed from outside while
  # the agent still believes it has time. Never zero: unattended means bounded.
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CI_SWEEP_BG_CEILING_MS:-$BG}"

  ROUND_LOG="$WORK/round-$round.log"
  ROUND_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "=== round $round — cap ${CAP} min, bg ceiling ${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS}ms, ${LEFT} min left in budget ==="

  ROUND_PROMPT="$(cat "$PROMPT_FILE")"
  [ -s "$CARRY" ] && ROUND_PROMPT="$ROUND_PROMPT

$(cat "$CARRY")"

  # Streamed (ci-sweep-stream.py) so a capped round still leaves a line-by-line log
  # (2026-09-20: two capped rounds, two 0-byte logs). MODEL PINNED: --model opus on
  # every invocation — without it the sweep silently ran on whatever /model she last
  # chose. ci-sweep-selftest.sh fails if any `"$CLAUDE" -p` line lacks it.
  run_round() {
    timeout --signal=TERM --kill-after=60 "${CAP}m" \
      "$CLAUDE" -p "$ROUND_PROMPT" --model opus "$@" \
      --output-format stream-json --verbose \
      --dangerously-skip-permissions < /dev/null 2>&1 | python3 "$STREAM" > "$ROUND_LOG"
  }
  if [ "$round" -eq 1 ]; then
    SESSION_ID="$( (uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())') | tr 'A-Z' 'a-z')"
    echo "$SESSION_ID" > "$WORK/session-id"
    run_round --session-id "$SESSION_ID"
    RC=$?
  else
    SESSION_ID="$(cat "$WORK/session-id" 2>/dev/null || true)"
    ROUND_T0=$(date +%s)
    run_round --resume "$SESSION_ID"
    RC=$?
    # A resume that dies IMMEDIATELY (no tool call, within RESUME_DEAD_SECS) is a
    # broken handle: fall back to a fresh session, briefed by the carryover. A capped
    # round (124/137) is never a broken handle (2026-09-20).
    RESUME_DEAD_SECS="${CI_SWEEP_RESUME_DEAD_SECS:-90}"
    ELAPSED=$(( $(date +%s) - ROUND_T0 ))
    if [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ] && [ "$RC" -ne 137 ] && [ "$ELAPSED" -le "$RESUME_DEAD_SECS" ] && ! grep -q '^\[tool\]\|^\[result' "$ROUND_LOG"; then
      say "resume of session $SESSION_ID died after ${ELAPSED}s with no tool call (rc=$RC); retrying this round as a fresh session."
      run_round
      RC=$?
    fi
  fi
  cat "$ROUND_LOG" >> "$RUN_LOG"
  say "=== round $round: claude exited rc=$RC ==="

  # --- Rule 0, per round: prove this round reached its end ------------------------
  [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ] && say "round $round hit its ${CAP}-minute cap and was terminated."
  if ! grep -q "CI-SWEEP-COMPLETE:" "$ROUND_LOG"; then
    say "NAMED STOP [SWEEP_ROUND_DID_NOT_COMPLETE] round $round emitted no sentinel — its silence is not evidence of anything."
    echo "round $round: NO SENTINEL" >> "$WORK/incomplete-rounds"
  else
    say "round $round sentinel: $(grep -o 'CI-SWEEP-COMPLETE:.*' "$ROUND_LOG" | tail -1)"
  fi

  # --- parked repos: named per repo, the run continues ---------------------------
  # `CI-SWEEP-PARKED: <repo> — <the one decision or credential needed>`, own line.
  # Only a repo this round was actually working can be parked, and only with a reason.
  while IFS= read -r pline; do
    prepo="$(printf '%s' "$pline" | sed -E 's/^[[:space:]]*CI-SWEEP-PARKED:[[:space:]]*//; s/[[:space:]].*//')"
    preason="$(printf '%s' "$pline" | sed -E 's/^[[:space:]]*CI-SWEEP-PARKED:[[:space:]]*[^[:space:]]+[[:space:]]*(—|--|-|:)?[[:space:]]*//')"
    [ -z "$prepo" ] && continue
    if ! printf '%s\n' "$RED_LINES" | cut -f2 | grep -qxF "$prepo"; then
      say "  (ignoring CI-SWEEP-PARKED for $prepo: not a red repo this round was working)"; continue
    fi
    if [ -z "$preason" ]; then
      say "  (ignoring CI-SWEEP-PARKED for $prepo: no decision or credential named — a park must say what she has to do)"; continue
    fi
    awk -F'\t' -v r="$prepo" '$1==r{f=1} END{exit !f}' "$WORK/parked-repos.tsv" && continue
    printf '%s\t%s\n' "$prepo" "$preason" >> "$WORK/parked-repos.tsv"
    say "PARKED $prepo on her decision: $preason — the run continues on every other red repo"
  done < <(grep -E '^[[:space:]]*CI-SWEEP-PARKED:' "$ROUND_LOG" 2>/dev/null)

  # --- the guard on the guard, every round ---------------------------------------
  # Scoped to this round's window and the repos it was dispatched to (2026-09-21:
  # someone else's PR touched during a sleep was read as this round's weakening).
  say "--- auditing what round $round touched ---"
  CI_SWEEP_AUDIT_SINCE="$ROUND_START_UTC" CI_SWEEP_AUDIT_REPOS="$RED_REPOS" "$AUDIT" > "$WORK/audit-$round.txt" 2>&1
  AUDIT_RC=$?
  cat "$WORK/audit-$round.txt" >> "$RUN_LOG"
  case "$AUDIT_RC" in
    0) say "round $round audit: no weakening patterns in anything it touched" ;;
    2) say "round $round audit: no pull request was touched in this round's window — not a clean bill of health"
       grep -q "CI-SWEEP-COMPLETE: fixed" "$ROUND_LOG" && say "  ^ AND the round reported 'fixed'. It claims work that left no pull request behind." ;;
    3) # SUSPECT, not FATAL (2026-09-09: an `if: always()` on a reporting step aborted
       # a whole morning). An unproven finding costs the PR it names — which the
       # merge pass leaves open for a person — not the run.
       say "round $round audit: SUSPECT change(s) named above — NOT aborting; those PRs are not merged." ;;
    *) # FATAL. Reaching green by weakening a check ends the run: the offending PR is
       # rejected on the PR itself, never merged or closed, and tomorrow is briefed.
       say "TEMP FIXES DETECTED IN ROUND $round — the sweep was reaching green by weakening something. Ending the run."
       reject_audited_prs "$WORK/audit-$round.txt" "$round"
       park_open_prs "the run ended on a weakening found by the audit"
       finish "MAIN-RED-TEMPFIX" "round $round weakened a test or a check in [$RED_REPOS] (see the audit section of $RUN_LOG). The PR is marked REJECTED and must not be merged; tomorrow's run is briefed with the rejection. Rejected: $(awk -F'\t' '{printf "%s (%s); ", $1, $2}' "$WORK/rejected" 2>/dev/null)" ;;
  esac

  # --- the merge pass: land what is green, on evidence read here -----------------
  say "--- merge pass after round $round ---"
  merge_pass "$round"
done
