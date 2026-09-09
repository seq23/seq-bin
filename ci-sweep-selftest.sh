#!/bin/bash
# The guard on the guard on the guard.
#
# WHY THIS EXISTS
# On 2026-09-09 the 10:07 sweep aborted at 10:57 with MAIN-RED-TEMPFIX and filed
# west-peek-os#21, throwing away a whole sweep's work, because ci-sweep-audit.sh
# saw `if: always()` in authority-backlink-network#99 — on a REPORTING step that
# masks nothing, as run 34371631703 proves by concluding FAILURE on the very
# commit that carries it. At the same time ci-sweep-probe.sh was reporting
# local-guides-generator's `Build Starter Pack` as SILENT on every single run,
# a healthy workflow whose `paths:` filter correctly did not match the day's
# CHANGELOG-only commit.
#
# BOTH DEFECTS WERE THE SAME MISTAKE: matching a string instead of testing an
# outcome. Both are now fixed, and this is what stops them coming back.
#
# RULE 0: THIS SCRIPT HARD-FAILS WHEN IT EXAMINES ZERO ITEMS. A validator that
# passes on an empty loop is the defect class this portfolio names most often,
# and it would be an especially bad joke here.
#
# EXIT 0 all checks passed · 1 a check failed · 2 examined nothing

set -uo pipefail

# THE SCRIPT'S OWN DIRECTORY, not $HOME/bin. On a CI runner the checkout lives at
# /home/runner/work/<repo>/<repo>, so a $HOME/bin default made every path miss and
# the whole validator exit 2 having examined nothing — the Rule 0 stop firing
# correctly, on a fault of its own making.
BIN="${CI_SWEEP_BIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
AUDIT="$BIN/ci-sweep-audit.sh"
TRIGGERS="$BIN/ci-sweep-triggers.py"
FIXTURES="$BIN/ci-sweep-fixtures"
GITHUB_DIR="${CI_SWEEP_GITHUB_DIR:-$HOME/GitHub}"

pass=0; failed=0; examined_fixtures=0; examined_workflows=0

ok()   { pass=$((pass+1));   echo "  ✓ $*"; }
bad()  { failed=$((failed+1)); echo "  ✗ FAIL $*"; }

for f in "$AUDIT" "$TRIGGERS"; do
  [ -x "$f" ] || { echo "NAMED STOP [MISSING] $f is missing or not executable."; exit 2; }
done

# ===========================================================================
echo "=== 1. the auditor: legitimate patterns must NOT be flagged ==========="
# Each of these is a real construct from this fleet that the old grep called a
# temp fix. If any of them fails here, the auditor is once again able to throw
# away a sweep over a text match.
for fx in good-if-always-reporting good-scoped-noqa; do
  [ -f "$FIXTURES/$fx.diff" ] || { bad "$fx.diff missing"; continue; }
  examined_fixtures=$((examined_fixtures+1))
  if CI_SWEEP_AUDIT_FIXTURE="$FIXTURES/$fx.diff" CI_SWEEP_AUDIT_EXPECT=pass \
       "$AUDIT" >/dev/null 2>&1; then
    ok "$fx — left alone, as it must be"
  else
    bad "$fx — a legitimate pattern was flagged; the auditor can abort a good sweep again"
  fi
done

# ===========================================================================
echo "=== 2. the auditor: real weakenings must STILL be caught as FATAL ====="
# Relaxing a detector is only safe if you prove it still detects. These are the
# unambiguous cheats, and every one must be fatal.
for fx in bad-continue-on-error bad-pytest-skip bad-bare-noqa \
          bad-swallow-pass bad-always-plus-continue-on-error; do
  [ -f "$FIXTURES/$fx.diff" ] || { bad "$fx.diff missing"; continue; }
  examined_fixtures=$((examined_fixtures+1))
  if CI_SWEEP_AUDIT_FIXTURE="$FIXTURES/$fx.diff" CI_SWEEP_AUDIT_EXPECT=catch \
       "$AUDIT" >/dev/null 2>&1; then
    ok "$fx — caught as FATAL"
  else
    bad "$fx — a real weakening got through; the auditor is now blind to it"
  fi
done

# ===========================================================================
echo "=== 3. the auditor: ambiguity must be SUSPECT, never fatal ============"
# The severity split is the point. Something a person should look at names the
# one pull request; it does not discard everyone else's work.
fx=suspect-unexplained-except
if [ ! -f "$FIXTURES/$fx.diff" ]; then
  bad "$fx.diff missing"
else
  examined_fixtures=$((examined_fixtures+1))
  if CI_SWEEP_AUDIT_FIXTURE="$FIXTURES/$fx.diff" CI_SWEEP_AUDIT_EXPECT=suspect \
       "$AUDIT" >/dev/null 2>&1; then
    ok "$fx — named as SUSPECT, not fatal"
  else
    bad "$fx — should be SUSPECT; it is either ignored or fatal"
  fi
fi

# ===========================================================================
echo "=== 4. the trigger model: the exact false positive that caused this ==="
# THESE RUN AGAINST COMMITTED COPIES OF THE REAL WORKFLOWS, not against the
# fleet checkout, so the regression is proven on a CI runner that has never seen
# ~/GitHub. A test that can only run on one laptop is a test that stops running.
STARTER="$FIXTURES/workflows/build_starter_pack.yml"
DISPATCH="$FIXTURES/workflows/add_city_request.yml"

if [ ! -f "$STARTER" ]; then
  bad "fixtures/workflows/build_starter_pack.yml missing — the regression case cannot be proven"
else
  tmp="$(mktemp)"
  # The real commit: 292ce39, `Record citation probe observations 2026-09-09`.
  printf 'CHANGELOG.md\ndata/signals/citation_probe_status.json\ndata/signals/llm_citation_observations.json\n' > "$tmp"
  v="$("$TRIGGERS" should-run --workflow "$STARTER" --branch main --changed-files "$tmp" | cut -f1)"
  examined_workflows=$((examined_workflows+1))
  if [ "$v" = "NO" ]; then
    ok "Build Starter Pack + a CHANGELOG-only commit -> NO (was a permanent SILENT before)"
  else
    bad "Build Starter Pack + a CHANGELOG-only commit -> $v, expected NO"
  fi

  # ...and the other direction, because a model that always says NO is useless
  # and would pass a one-sided test while detecting nothing at all.
  printf 'scripts/build_starter_pack.js\n' > "$tmp"
  v="$("$TRIGGERS" should-run --workflow "$STARTER" --branch main --changed-files "$tmp" | cut -f1)"
  examined_workflows=$((examined_workflows+1))
  if [ "$v" = "YES" ]; then
    ok "Build Starter Pack + a file inside its paths: filter -> YES"
  else
    bad "Build Starter Pack + a matching file -> $v, expected YES"
  fi
  rm -f "$tmp"
fi

if [ ! -f "$DISPATCH" ]; then
  bad "fixtures/workflows/add_city_request.yml missing"
else
  examined_workflows=$((examined_workflows+1))
  v="$("$TRIGGERS" should-run --workflow "$DISPATCH" --branch main | cut -f1)"
  if [ "$v" = "NO" ]; then
    ok "Add City Request (workflow_dispatch with required inputs) -> NO"
  else
    bad "Add City Request -> $v, expected NO"
  fi
fi

# ===========================================================================
echo "=== 5. the trigger model must PARSE the fleet, not shrug at it ========"
# UNKNOWN is safe — it never produces a finding — but a model that answers
# UNKNOWN everywhere has quietly stopped detecting silence at all, which is the
# opposite failure and just as invisible. So the parse rate is asserted.
#
# This one needs the fleet checkout. On a runner it does not exist, and the
# honest outcome is a NAMED STOP that a person reads, not a silent pass.
if [ "${CI_SWEEP_SELFTEST_OFFLINE:-0}" = "1" ] || [ ! -d "$GITHUB_DIR" ]; then
  echo "  - NAMED SKIP [NO_FLEET_CHECKOUT] $GITHUB_DIR is not present, so the fleet-wide"
  echo "    parse rate cannot be measured here. Section 4 above still proves the model"
  echo "    on committed copies of the real workflows."
else
  tmp="$(mktemp)"; printf 'README.md\n' > "$tmp"
  unknown=0; fleet=0
  for wfile in "$GITHUB_DIR"/*/.github/workflows/*.y*ml; do
    [ -f "$wfile" ] || continue
    fleet=$((fleet+1))
    examined_workflows=$((examined_workflows+1))
    case "$("$TRIGGERS" should-run --workflow "$wfile" --branch main --changed-files "$tmp" | cut -f1)" in
      UNKNOWN) unknown=$((unknown+1)) ;;
    esac
  done
  rm -f "$tmp"
  if [ "$fleet" -le 10 ]; then
    bad "only $fleet fleet workflow(s) found — too few to assert a parse rate against"
  else
    # 20% is generous headroom over the 6/140 measured on 2026-09-09; it is a
    # tripwire against the model silently degrading, not a target.
    limit=$(( fleet / 5 ))
    if [ "$unknown" -le "$limit" ]; then
      ok "$unknown/$fleet fleet workflows UNKNOWN (limit $limit)"
    else
      bad "$unknown/$fleet fleet workflows UNKNOWN (limit $limit) — the model has stopped understanding the fleet"
    fi
  fi
fi

# ===========================================================================
echo "=== 6. the probe must refuse to run without the trigger model ========="
# Otherwise a missing file silently reverts SILENT to a grep for `push:`, and
# nobody would ever know the detector had gone back to being broken.
if ! command -v gh >/dev/null 2>&1; then
  echo "  - NAMED SKIP [NO_GH_CLI] the probe cannot be exercised without gh."
else
  out="$(CI_SWEEP_TRIGGERS_BIN=/nonexistent/ci-sweep-triggers.py "$BIN/ci-sweep-probe.sh" 2>&1)"
  rc=$?
  if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'NO_TRIGGER_MODEL'; then
    ok "probe named-stops with NO_TRIGGER_MODEL instead of degrading silently"
  else
    bad "probe did not named-stop without its trigger model (rc=$rc)"
  fi
fi

# ===========================================================================
# RULE 0
if [ "$examined_fixtures" -eq 0 ] || [ "$examined_workflows" -eq 0 ]; then
  echo
  echo "NAMED STOP [EXAMINED_NOTHING] fixtures=$examined_fixtures workflows=$examined_workflows."
  echo "  This validator passed no checks because it had nothing to check. That is a FAILURE,"
  echo "  not a clean run — a guard that passes on an empty loop is the defect class this"
  echo "  portfolio names most often, and it would be a poor joke in this file of all files."
  exit 2
fi

echo
echo "=== $pass passed, $failed failed ($examined_fixtures fixtures, $examined_workflows workflows) ==="
[ "$failed" -gt 0 ] && exit 1
exit 0
