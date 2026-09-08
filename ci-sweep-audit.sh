#!/bin/bash
# Audit what the sweep actually DID — the guard on the guard.
#
# WHY THIS EXISTS
# The sweep's prompt forbids temp fixes in plain terms: no re-running, pinning,
# skipping, xfail or continue-on-error to reach green, and a guard with a
# negative proof for every fix. Forbidding is not verifying. Nothing checked the
# diffs, so an agent that weakened an assertion and reported "fixed" would emit
# the same CI-SWEEP-COMPLETE: fixed sentinel as one that found a root cause, and
# the sentinel is all the wrapper reads.
#
# That gap is the whole reason red lanes were "fixed" by re-running them in the
# first place. This closes it by reading what landed rather than what was
# claimed.
#
# RULE 0: examining zero pull requests is NOT a pass. A validator that passes on
# an empty input set is the defect class this portfolio names most often, so an
# empty sweep window exits non-zero with a named reason rather than reporting a
# clean audit of nothing.

set -uo pipefail

HOURS="${CI_SWEEP_AUDIT_HOURS:-24}"
# An explicit ISO-8601 floor, which the convergence loop sets to the moment each
# ROUND started. Whole hours are too coarse for that: with a rounds-until-green
# loop, three rounds can land inside one hour, and an hours-based window would let
# round 1's clean diffs vouch for round 3's. Every round is audited against its own
# window instead — and the round under the most pressure to reach green cheaply is
# the LAST one, which an audit of only the first would never read.
SINCE_OVERRIDE="${CI_SWEEP_AUDIT_SINCE:-}"
GITHUB_DIR="${CI_SWEEP_GITHUB_DIR:-$HOME/GitHub}"
# Overridable so the detector can be exercised against a known-bad diff without
# waiting for a real sweep to produce one.
FIXTURE="${CI_SWEEP_AUDIT_FIXTURE:-}"

fail=0
examined=0

say() { echo "$*"; }

# --- what a temp fix looks like in a diff ------------------------------------
# Only ADDED lines are inspected. A diff that DELETES `continue-on-error` is the
# opposite of a temp fix, and matching on the raw file would have flagged it as
# one — punishing exactly the change we want.
#
# Each pattern is paired with what it does, because "matched a regex" is not a
# finding a person can act on.
check_diff() {
  local label="$1" diff="$2" found=0
  local added
  # BRACKET EXPRESSIONS, NOT BACKSLASHES. `grep -v '^\+\+\+'` is a BASIC regex, where `\+` is a
  # GNU extension that BSD grep rejects outright — "repetition-operator operand invalid". The
  # extraction then errored, `added` came back empty, and every diff read as clean. The detector
  # reported nothing wrong with a diff that was nothing but temp fixes, which is the precise
  # failure it exists to prevent, in itself.
  added="$(printf '%s\n' "$diff" | grep -E '^[+]' | grep -Ev '^[+][+][+]' || true)"
  [ -z "$added" ] && return 0

  while IFS='~' read -r pattern why; do
    [ -z "$pattern" ] && continue
    local hits err
    err="$(printf '%s\n' "$added" | grep -nE "$pattern" 2>&1 >/dev/null || true)"
    if [ -n "$err" ]; then
      say "  ✗ $label — DETECTOR BROKEN: pattern did not compile: $pattern"
      say "      $err"
      found=1
      continue
    fi
    hits="$(printf '%s\n' "$added" | grep -nE "$pattern" || true)"
    if [ -n "$hits" ]; then
      found=1
      say "  ✗ $label — $why"
      printf '%s\n' "$hits" | head -3 | sed 's/^/      /'
    fi
  done <<'PATTERNS'
continue-on-error[[:space:]]*:[[:space:]]*true~a failing step is being reported as success
pytest[.]mark[.](skip|xfail)~a test is being switched off rather than fixed
@unittest[.]skip~a test is being switched off rather than fixed
[-][-]no-verify~a commit is bypassing its own hooks
[|][|][[:space:]]*true[[:space:]]*$~a command's failure is being swallowed
set[[:space:]][+]e~error checking is being turned off for the rest of the script
if:[[:space:]]*always[(][)]~a step is being made to run even when the job failed
continue-on-error:[[:space:]]*[$][{][{]~a failing step is being excused by an expression
allow_failure:[[:space:]]*true~a failing job is being declared acceptable
[.](skip|todo|failing)[(]~a test is being switched off rather than fixed
[.]only[(]~a test file is being narrowed to one case, silencing the rest
[-][-]deselect[[:space:]]~tests are being excluded from the run rather than fixed
gh[[:space:]]+run[[:space:]]+rerun~a red run is being re-run, which is the original defect
[|][|][[:space:]]*exit[[:space:]]*0[[:space:]]*$~a failure is being converted into success
[|][|][[:space:]]*:[[:space:]]*$~a command's failure is being swallowed by a no-op
[#][[:space:]]*(nosec|noqa|type:[[:space:]]*ignore)~a checker is being silenced inline
PATTERNS

  [ "$found" -eq 1 ] && return 1
  return 0
}

# --- fixture mode: prove the detector detects --------------------------------
if [ -n "$FIXTURE" ]; then
  # CI_SWEEP_AUDIT_EXPECT=catch (default) — the fixture is a temp fix and must be caught.
  # CI_SWEEP_AUDIT_EXPECT=pass          — the fixture is a REAL fix and must not be flagged.
  # Both directions are needed: a detector whose regexes never compile catches nothing and
  # would sail through a one-sided self-test that only ever fed it a bad diff.
  expect="${CI_SWEEP_AUDIT_EXPECT:-catch}"
  say "audit self-test ($expect): $FIXTURE"
  if check_diff "fixture" "$(cat "$FIXTURE")"; then
    caught=0
  else
    caught=1
  fi
  if [ "$expect" = "catch" ] && [ "$caught" -eq 1 ]; then
    say "SELF-TEST PASSED: the known-bad diff was caught."; exit 0
  fi
  if [ "$expect" = "pass" ] && [ "$caught" -eq 0 ]; then
    say "SELF-TEST PASSED: the good diff was left alone."; exit 0
  fi
  say "SELF-TEST FAILED: expected to $expect, did not."
  exit 1
fi

command -v gh >/dev/null 2>&1 || { say "NAMED STOP [NO_GH_CLI] cannot audit without gh."; exit 6; }

if [ -n "$SINCE_OVERRIDE" ]; then
  since="$SINCE_OVERRIDE"
else
  since="$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
fi
say "=== auditing pull requests updated since $since ==="

for repo in "$GITHUB_DIR"/*/; do
  [ -d "$repo/.git" ] || continue
  name="$(basename "$repo")"

  # --state all, NOT --state open. This read `--state open` until 2026-09-08, and
  # that hole is the size of the whole auditor: a weakening only matters once it is
  # ON MAIN, and a PR that has been merged is no longer open. On 09-08 the sweep's
  # agents merged #88, #89 and #90 into local-guides-citation-velocity and the audit
  # examined NONE of them — it reported a clean bill of health for three diffs it
  # had never read. The guard on the guard was blind to exactly the PRs that landed.
  prs="$(cd "$repo" && gh pr list --state all --limit 60 --json number,title,updatedAt,headRefName \
        --jq ".[] | select(.updatedAt > \"$since\") | \"\(.number)\t\(.title)\"" 2>/dev/null || true)"
  [ -z "$prs" ] && continue

  while IFS=$'\t' read -r num title; do
    [ -z "$num" ] && continue
    examined=$((examined + 1))
    diff="$(cd "$repo" && gh pr diff "$num" 2>/dev/null || true)"
    if [ -z "$diff" ]; then
      say "  ? $name#$num — diff unreadable; not audited"
      continue
    fi

    if ! check_diff "$name#$num ($title)" "$diff"; then
      fail=1
    else
      # A fix that changes code and adds no test is not necessarily wrong, but it
      # is the shape a temp fix takes, so it is reported rather than passed over.
      if printf '%s\n' "$diff" | grep -qE '^[+][+][+] b/.*[.](py|ts|tsx|mjs|js)$' \
         && ! printf '%s\n' "$diff" | grep -qiE '^[+][+][+] b/.*(test|spec|validate)'; then
        say "  ! $name#$num — code changed, no test or validator touched: $title"
      else
        say "  ✓ $name#$num — no weakening pattern: $title"
      fi
    fi
  done <<< "$prs"
done

if [ "$examined" -eq 0 ]; then
  say "NAMED STOP [AUDITED_NOTHING] no pull request was updated in the last ${HOURS}h, so this audit"
  say "  examined zero items. That is not a clean bill of health — a validator that passes on an"
  say "  empty input set is the defect this repository names most often."
  exit 2
fi

say "=== audited $examined pull request(s) ==="
if [ "$fail" -eq 1 ]; then
  say "TEMP FIXES DETECTED — the sweep reached green by weakening something. Do not merge."
  exit 1
fi
say "No weakening patterns found."
exit 0
