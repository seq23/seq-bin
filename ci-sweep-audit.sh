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
# WHY IT WAS REWRITTEN ON 2026-09-09
# It was a grep, and a grep cannot tell a weakening from a fix. On 2026-09-09 the
# 10:07 sweep aborted at 10:57 with MAIN-RED-TEMPFIX and filed west-peek-os#21,
# discarding a whole sweep's work, because authority-backlink-network#99 added
# `if: always()` to a REPORTING step.
#
# THAT VERDICT WAS FALSE AND IT WAS PROVEN FALSE. Run 34371631703 ran on b2e1790
# — the merge commit carrying that exact `if: always()` — and still concluded
# FAILURE. The guard masks nothing. What it does is make the honest report print
# ON failure, which is the only reason that day's outage was visible at all. The
# auditor aborted the sweep for making a failure MORE visible.
#
# So the test is no longer WHETHER A STRING APPEARS but WHETHER THE JOB'S OUTCOME
# CHANGED:
#   · `if: always()` on a step cannot turn a failing job green — GitHub fails the
#     job if any step fails regardless. It is only suspicious paired with
#     something that DOES excuse a failure, and it is cleared outright by evidence
#     that the workflow still concludes `failure` after the change landed.
#   · A suppression comment is legitimate when it is SCOPED and JUSTIFIED
#     (`# noqa: BLE001 - a failed logout is not a run failure`) and a weakening
#     when it is bare (`# noqa`), which silences every check on the line.
#   · An exception handler is only cheating when it swallows the condition under
#     test. A scoped, commented, non-fatal path is not cheating; `except: pass` is.
#
# AND A FALSE POSITIVE MUST NOT BE ABLE TO ABORT A SWEEP THAT IS DOING REAL WORK.
# Findings now carry a severity. Only an unambiguous weakening is fatal. Anything
# the auditor cannot prove either way names the specific pull request and exits 3,
# which the wrapper reports and continues past — failing one PR rather than
# discarding everyone's work over a text match.
#
# RULE 0: examining zero pull requests is NOT a pass. A validator that passes on
# an empty input set is the defect class this portfolio names most often, so an
# empty sweep window exits non-zero with a named reason rather than reporting a
# clean audit of nothing.
#
# EXIT CODES
#   0  audited at least one PR, nothing worse than a NOTE
#   1  FATAL — an unambiguous weakening is on a branch. Abort the sweep.
#   2  named stop: zero pull requests in the window
#   3  SUSPECT — something needs a human look, named per PR. NOT fatal.
#   6  named stop: no gh CLI

set -uo pipefail

HOURS="${CI_SWEEP_AUDIT_HOURS:-24}"
# An explicit ISO-8601 floor, which the convergence loop sets to the moment each
# ROUND started. Whole hours are too coarse for that: with a rounds-until-green
# loop, three rounds can land inside one hour, and an hours-based window would let
# round 1's clean diffs vouch for round 3's. Every round is audited against its own
# window instead — and the round under the most pressure to reach green cheaply is
# the LAST one, which an audit of only the first would never read.
SINCE_OVERRIDE="${CI_SWEEP_AUDIT_SINCE:-}"
# The repos the round under audit was dispatched to, space-separated. Empty means
# unscoped (every finding is judged on its own). When set, a FATAL finding in a
# repo OUTSIDE the list is downgraded to SUSPECT with the reason on the line:
# the sweep's agents were not in that repo, so the PR is someone else's work
# that happened to be updated in the window. On 2026-09-21 the sweep was
# dispatched to local-guides-citation-velocity only, a person's session pushed
# boss-os#33 while the round sat frozen in a Mac sleep, and the audit ended the
# whole sweep as MAIN-RED-TEMPFIX over a PR it had no part in. A weakening in
# someone else's PR still deserves a person's eye — it is named — but it is not
# this round cheating, and it must not end the attempt.
SCOPE_REPOS="${CI_SWEEP_AUDIT_REPOS:-}"
in_scope() {
  [ -z "$SCOPE_REPOS" ] && return 0
  local r
  for r in $SCOPE_REPOS; do [ "$r" = "$1" ] && return 0; done
  return 1
}
GITHUB_DIR="${CI_SWEEP_GITHUB_DIR:-$HOME/GitHub}"
# Overridable so the detector can be exercised against a known-bad diff without
# waiting for a real sweep to produce one.
FIXTURE="${CI_SWEEP_AUDIT_FIXTURE:-}"

fatal=0
suspect=0
examined=0

say() { echo "$*"; }

# Per-diff findings, reset by check_diff.
D_FATAL=0
D_SUSPECT=0
D_ALWAYS=0

# --- what a temp fix looks like in a diff ------------------------------------
# Only ADDED lines are inspected. A diff that DELETES `continue-on-error` is the
# opposite of a temp fix, and matching on the raw file would have flagged it as
# one — punishing exactly the change we want.
#
# Each pattern is paired with what it does, because "matched a regex" is not a
# finding a person can act on.
#
# EVERY PATTERN HERE IS UNAMBIGUOUS. A construct that has a legitimate use — an
# `if: always()`, a scoped `# noqa`, a caught exception — is NOT in this list; it
# is judged by the contextual checks below, which read what it is doing rather
# than that it exists. Adding a dual-use construct here is how a whole sweep gets
# thrown away over a reporting step.
check_fatal_patterns() {
  local label="$1" added="$2" found=0
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
      say "  ✗ FATAL $label — $why"
      printf '%s\n' "$hits" | head -3 | sed 's/^/      /'
    fi
  done <<'PATTERNS'
pytest[.]mark[.](skip|xfail)~a test is being switched off rather than fixed
@unittest[.]skip~a test is being switched off rather than fixed
[-][-]no-verify~a commit is bypassing its own hooks
[|][|][[:space:]]*true[[:space:]]*$~a command's failure is being swallowed
set[[:space:]][+]e~error checking is being turned off for the rest of the script
[.](skip|todo|failing)[(]~a test is being switched off rather than fixed
[.]only[(]~a test file is being narrowed to one case, silencing the rest
[-][-]deselect[[:space:]]~tests are being excluded from the run rather than fixed
gh[[:space:]]+run[[:space:]]+rerun~a red run is being re-run, which is the original defect
[|][|][[:space:]]*exit[[:space:]]*0[[:space:]]*$~a failure is being converted into success
[|][|][[:space:]]*:[[:space:]]*$~a command's failure is being swallowed by a no-op
[#][[:space:]]*noqa[[:space:]]*$~a BARE noqa silences every linter rule on the line, not a named one
[#][[:space:]]*nosec[[:space:]]*$~a BARE nosec silences every security rule on the line, not a named one
[#][[:space:]]*type:[[:space:]]*ignore[[:space:]]*$~a BARE type: ignore silences every type error on the line, not a named one
PATTERNS
  [ "$found" -eq 1 ] && D_FATAL=$((D_FATAL + 1))
  return 0
}

# --- contextual: an exception handler that swallows what it was testing -------
# `except ...:` whose entire body is `pass` discards the condition. That IS
# cheating and is fatal. Everything else about a handler is judged by whether it
# says why: a handler carrying a scoped justification is a deliberate,
# reviewed non-fatal path — `except Exception: # noqa: BLE001 - a failed logout
# is not a run failure` — and a handler with no explanation at all is a SUSPECT
# for a person to look at, never an abort.
check_exception_handling() {
  local label="$1" added="$2"
  local prev="" line body
  local bare_pass=0 unexplained=0
  while IFS= read -r line; do
    body="${line#+}"
    if printf '%s' "$prev" | grep -qE '^[[:space:]]*except\b.*:[[:space:]]*(#.*)?$' \
       && printf '%s' "$body" | grep -qE '^[[:space:]]*pass[[:space:]]*$'; then
      # ...unless the handler line itself carries a justification, which makes it
      # a declared no-op rather than a silent one.
      if ! printf '%s' "$prev" | grep -qE '#.*[A-Za-z]{3}'; then
        bare_pass=1
        say "  ✗ FATAL $label — an exception handler's entire body is \`pass\`, discarding the condition"
        say "      ${prev}"
        say "      ${body}"
      fi
    fi
    if printf '%s' "$body" | grep -qE '^[[:space:]]*except[[:space:]]+(BaseException|Exception)\b'; then
      if ! printf '%s' "$body" | grep -qE '#[[:space:]]*(noqa|nosec)?:?[[:space:]]*[A-Za-z0-9]+.*[-–—][[:space:]]*[A-Za-z]' \
         && ! printf '%s' "$body" | grep -qE '#.*[A-Za-z]{4}'; then
        unexplained=1
      fi
    fi
    prev="$body"
  done <<< "$added"
  [ "$bare_pass" -eq 1 ] && D_FATAL=$((D_FATAL + 1))
  if [ "$unexplained" -eq 1 ]; then
    D_SUSPECT=$((D_SUSPECT + 1))
    say "  ? SUSPECT $label — a broad \`except\` was added with no comment saying why it is not fatal."
    say "      Scoped and justified handlers are fine; this one states nothing, so a person should read it."
  fi
  return 0
}

# --- contextual: suppression comments ----------------------------------------
# A suppression is legitimate when it names the rule it is silencing AND says why:
#     except Exception as exc:  # noqa: BLE001 - an API outage must not take the lane down
# It is a weakening when it is bare (fatal, above) and unproven when it names a
# rule but explains nothing.
#
# A CODED-BUT-UNJUSTIFIED SUPPRESSION IS A NOTE, NOT A SUSPECT. `# noqa: E402`
# on a deliberate late import — which is what authority-backlink-network#99
# actually contains — silences an import-ordering style rule. It cannot hide a
# failing test or a red job, so treating it as something that needs adjudication
# would flood every sweep with findings nobody can action, and the point of the
# severity split is that a SUSPECT must be worth a person's attention.
check_suppressions() {
  local label="$1" added="$2"
  local coded
  coded="$(printf '%s\n' "$added" \
    | grep -nE '#[[:space:]]*(noqa|nosec)[[:space:]]*:[[:space:]]*[A-Za-z]+[0-9]*|#[[:space:]]*type:[[:space:]]*ignore\[' || true)"
  [ -z "$coded" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # A justification is a separator after the rule code followed by prose:
    #     # noqa: BLE001 - a failed logout is not a run failure
    # Requiring only "some letters" is not enough, because a comma-separated code
    # list would satisfy it; requiring an explicit `-`, `:` or `#` separator is
    # what distinguishes a reason from another code.
    if ! printf '%s' "$line" | grep -qE '(noqa|nosec)[[:space:]]*:[[:space:]]*[A-Za-z]+[0-9]*([[:space:]]*,[[:space:]]*[A-Za-z]+[0-9]*)*[[:space:]]*[-–—:#][[:space:]]*[A-Za-z]' \
       && ! printf '%s' "$line" | grep -qE 'type:[[:space:]]*ignore\[[^]]+\][[:space:]]*[-–—:#][[:space:]]*[A-Za-z]'; then
      say "  ! NOTE $label — a suppression names a rule but gives no reason (not blocking):"
      say "      ${line}"
    fi
  done <<< "$coded"
  return 0
}

# --- contextual: if: always() ------------------------------------------------
# NOT A WEAKENING ON ITS OWN. A step guarded by `if: always()` still fails its
# job when it fails; GitHub concludes a job `failure` if any step failed,
# whatever its `if:` was. The only way it participates in masking is alongside
# something that actually excuses a failure — `continue-on-error` — and that is
# already fatal by itself.
#
# So it is recorded here and cleared by EVIDENCE in check_pr: if the workflow it
# was added to has concluded `failure` since the change landed, the guard
# demonstrably masks nothing, and this is a NOTE. Absent that evidence it is a
# SUSPECT naming the one PR, never an abort of the sweep.
check_always() {
  local label="$1" added="$2"
  local hits
  hits="$(printf '%s\n' "$added" | grep -nE 'if:[[:space:]]*(\$\{\{[[:space:]]*)?always\(\)' || true)"
  [ -z "$hits" ] && return 0
  D_ALWAYS=1
  if printf '%s\n' "$added" | grep -qE 'continue-on-error'; then
    D_FATAL=$((D_FATAL + 1))
    say "  ✗ FATAL $label — \`if: always()\` added ALONGSIDE continue-on-error; together those do excuse a failure"
  fi
  return 0
}

# --- the keys that only mean something in a workflow file ---------------------
# `continue-on-error`, `allow_failure`, `if: always()` are YAML keys. Read as a
# regex over EVERY added line they also match a validator's self-test fixture —
# the string a checker feeds itself to prove it still catches `continue-on-error:
# true` — and on 21 Sep 2026 that is exactly what happened: west-peek-os#155
# added `validate:green-means-something` cases quoting both, in a `.mjs` file,
# and the audit reported "a failing step is being reported as success" FATAL
# against a PR that had made the check stricter. So these three are judged on
# added lines from `.yml`/`.yaml` files only. A `.mjs`, `.py` or `.md` cannot
# excuse a workflow step, whatever it says.
check_workflow_patterns() {
  local label="$1" added="$2" found=0
  while IFS='~' read -r pattern why; do
    [ -z "$pattern" ] && continue
    local hits
    hits="$(printf '%s\n' "$added" | grep -nE "$pattern" || true)"
    if [ -n "$hits" ]; then
      found=1
      say "  ✗ FATAL $label — $why"
      printf '%s\n' "$hits" | head -3 | sed 's/^/      /'
    fi
  done <<'PATTERNS'
continue-on-error[[:space:]]*:[[:space:]]*true~a failing step is being reported as success
continue-on-error:[[:space:]]*[$][{][{]~a failing step is being excused by an expression
allow_failure:[[:space:]]*true~a failing job is being declared acceptable
PATTERNS
  [ "$found" -eq 1 ] && D_FATAL=$((D_FATAL + 1))
  return 0
}

# The added lines of a diff that belong to YAML files: the `+++ b/<path>` header
# names the file every following `+` line is in.
added_yaml_lines() {
  printf '%s\n' "$1" | awk '
    /^[+][+][+] / { yaml = ($0 ~ /[.]ya?ml$/); next }
    /^[+]/ && yaml { print }
  '
}

check_diff() {
  local label="$1" diff="$2"
  D_FATAL=0; D_SUSPECT=0; D_ALWAYS=0
  local added added_code added_yaml_code
  # BRACKET EXPRESSIONS, NOT BACKSLASHES. `grep -v '^\+\+\+'` is a BASIC regex, where `\+` is a
  # GNU extension that BSD grep rejects outright — "repetition-operator operand invalid". The
  # extraction then errored, `added` came back empty, and every diff read as clean. The detector
  # reported nothing wrong with a diff that was nothing but temp fixes, which is the precise
  # failure it exists to prevent, in itself.
  added="$(printf '%s\n' "$diff" | grep -E '^[+]' | grep -Ev '^[+][+][+]' || true)"
  [ -z "$added" ] && return 0

  # PURE COMMENT LINES ARE NOT CODE, AND CANNOT WEAKEN ANYTHING.
  #
  # west-peek-os#24 was reported FATAL by the first version of this rewrite for
  # having `if: always()` and `continue-on-error` in the same diff. Both were in
  # ONE COMMENT, which reads, in full:
  #
  #   # THIS IS NOT A WEAKENED GATE, and the distinction matters. There is no
  #   # `continue-on-error` here, no `if: always()`, and nothing skipped: ...
  #
  # An auditor that fails a pull request for explaining, in prose, that it did
  # not weaken anything is the 2026-09-09 abort with extra steps. So the
  # executable checks read CODE lines only.
  #
  # The suppression and exception checks keep the full text on purpose: what
  # they are judging IS a comment -- whether a `# noqa` names its rule and says
  # why -- and stripping comments there would blind them completely.
  added_code="$(printf '%s\n' "$added" | grep -Ev '^[+][[:space:]]*([#]|//|/\*|\*)' || true)"

  added_yaml_code="$(added_yaml_lines "$diff" | grep -Ev '^[+][[:space:]]*[#]' || true)"

  check_fatal_patterns "$label" "$added_code"
  check_workflow_patterns "$label" "$added_yaml_code"
  check_exception_handling "$label" "$added"
  check_suppressions "$label" "$added"
  check_always "$label" "$added_yaml_code"
  return 0
}

# --- the evidence test for if: always() --------------------------------------
# Ask GitHub whether the workflows this PR touched have concluded `failure` since
# it landed. A failure after the change is proof the guard did not make failures
# invisible — the exact proof that cleared #99, automated so it never has to be
# re-established by hand at 10:57 in the morning.
always_is_proven_honest() {
  local repo_dir="$1" num="$2" diff="$3"
  local paths since flow concl
  paths="$(printf '%s\n' "$diff" | grep -oE '^[+][+][+] b/\.github/workflows/[^[:space:]]+' \
         | sed 's|^+++ b/||' | sort -u)"
  [ -z "$paths" ] && return 1
  since="$(cd "$repo_dir" && gh pr view "$num" --json createdAt --jq '.createdAt' 2>/dev/null || true)"
  [ -z "$since" ] && return 1
  for flow in $paths; do
    concl="$(cd "$repo_dir" && gh run list --workflow "$flow" --limit 40 \
            --json conclusion,createdAt \
            --jq "[.[]|select(.createdAt >= \"$since\")|.conclusion]|join(\",\")" 2>/dev/null || true)"
    case "$concl" in
      *failure*|*timed_out*|*cancelled*)
        say "      evidence: $flow still concluded failure after this landed — the guard masks nothing"
        return 0 ;;
    esac
  done
  return 1
}

# --- fixture mode: prove the detector detects --------------------------------
if [ -n "$FIXTURE" ]; then
  # CI_SWEEP_AUDIT_EXPECT=catch (default) — the fixture is a temp fix and must be caught.
  # CI_SWEEP_AUDIT_EXPECT=pass          — the fixture is a REAL fix and must not be flagged.
  # CI_SWEEP_AUDIT_EXPECT=suspect       — the fixture is ambiguous and must be named, not aborted on.
  # All three directions are needed: a detector whose regexes never compile catches nothing and
  # would sail through a one-sided self-test that only ever fed it a bad diff, and a detector
  # that is fatal about everything passes a catch-only self-test while being unusable.
  expect="${CI_SWEEP_AUDIT_EXPECT:-catch}"
  say "audit self-test ($expect): $FIXTURE"
  check_diff "fixture" "$(cat "$FIXTURE")"
  say "  -> fatal=$D_FATAL suspect=$D_SUSPECT always=$D_ALWAYS"
  case "$expect" in
    catch)   [ "$D_FATAL" -gt 0 ] && { say "SELF-TEST PASSED: the known-bad diff was caught as FATAL."; exit 0; } ;;
    pass)    [ "$D_FATAL" -eq 0 ] && [ "$D_SUSPECT" -eq 0 ] && { say "SELF-TEST PASSED: the good diff was left alone."; exit 0; } ;;
    suspect) [ "$D_FATAL" -eq 0 ] && [ "$D_SUSPECT" -gt 0 ] && { say "SELF-TEST PASSED: named as SUSPECT, not fatal."; exit 0; } ;;
  esac
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

    label="$name#$num ($title)"
    check_diff "$label" "$diff"

    # An `if: always()` is cleared by evidence, not by argument.
    if [ "$D_ALWAYS" -eq 1 ] && [ "$D_FATAL" -eq 0 ]; then
      if always_is_proven_honest "$repo" "$num" "$diff"; then
        say "  ✓ NOTE $label — adds \`if: always()\`, PROVEN not to mask (see evidence above)"
      else
        D_SUSPECT=$((D_SUSPECT + 1))
        say "  ? SUSPECT $label — adds \`if: always()\` and no post-merge failure exists to prove it"
        say "      does not mask one. Not fatal: a step with \`if: always()\` still fails its job."
      fi
    fi

    if [ "$D_FATAL" -gt 0 ] && ! in_scope "$name"; then
      say "  ? SUSPECT $label — the FATAL finding above is OUT OF THIS ROUND'S SCOPE: the sweep was"
      say "      dispatched to [$SCOPE_REPOS], not $name, so this is someone else's pull request"
      say "      updated in the window. A person should read it; the sweep is not aborted for it."
      suspect=1
    elif [ "$D_FATAL" -gt 0 ]; then
      fatal=1
    elif [ "$D_SUSPECT" -gt 0 ]; then
      suspect=1
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
if [ "$fatal" -eq 1 ]; then
  say "TEMP FIXES DETECTED — the sweep reached green by weakening something. Do not merge."
  exit 1
fi
if [ "$suspect" -eq 1 ]; then
  say "SUSPECT CHANGES — named above, per pull request. NOT an abort: these need a person's eye,"
  say "  and discarding a whole sweep's work over an unproven finding is what happened on 2026-09-09."
  exit 3
fi
say "No weakening patterns found."
exit 0
