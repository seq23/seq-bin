#!/bin/bash
# Behavioural tests for ci-sweep-probe.sh — the script that decides whether main
# is really green.
#
# WHY THIS EXISTS
# The sweep's convergence loop reads this script's EXIT CODE and nothing else. If
# the mapping from lane states to exit codes is wrong, the loop either declares a
# red fleet converged or never stops. Nothing had ever exercised that mapping.
#
# The probe's network path (gh, jq, the GitHub API) is NOT tested here and cannot
# honestly be: it needs live credentials and a live account, and a test that
# stubbed all of it would be asserting the stub. What IS tested is the part the
# convergence loop actually depends on — the fixture path, which runs the same
# state-counting and the same exit-code decision with the lane lines supplied
# rather than fetched. Said plainly rather than papered over: the API querying
# and lane classification in the non-fixture path remain unverified by this lane.
#
# Contract under test (from the script's own header):
#   0  every lane GREEN
#   1  at least one RED or SILENT lane
#   2  no RED/SILENT, but lanes still PENDING
#   3  named stop
#
# RULE 0: zero assertions executed is NOT a pass.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROBE="$ROOT/ci-sweep-probe.sh"

[ -x "$PROBE" ] || { echo "NAMED STOP [NO_PROBE] $PROBE is missing or not executable."; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

asserts=0
failed=0

TAB="$(printf '\t')"

lane() { printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$TAB" "$2" "$TAB" "$3" "$TAB" "$4" "$TAB" "$5"; }

mkfix() {
  local out="$TMP/$1"; shift
  : >"$out"
  local l
  for l in "$@"; do printf '%s\n' "$l" >>"$out"; done
  printf '%s' "$out"
}

assert_exit() {
  local want="$1" what="$2" fix="$3"
  asserts=$((asserts + 1))
  CI_SWEEP_PROBE_FIXTURE="$fix" "$PROBE" >"$TMP/out" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  o exit $got  $what"
  else
    echo "  x exit $got (wanted $want)  $what"
    sed 's/^/        /' "$TMP/out"
    failed=$((failed + 1))
  fi
}

GREEN_A="$(lane GREEN courtscope Pages 'courtscope|Pages|ok' 'newest run succeeded')"
GREEN_B="$(lane GREEN charm-nest Build 'charm-nest|Build|ok' 'newest run succeeded')"
RED_A="$(lane RED local-guides-citation-velocity 'Velocity Content Release' 'lgcv|VCR|fail' 'newest run failed')"
PEND_A="$(lane PENDING secondaries Deploy 'secondaries|Deploy|pending' 'in progress')"
SILENT_A="$(lane SILENT seq-bin '(none)' 'seq-bin|NO_WORKFLOWS' 'no active workflows despite commits')"
QUIET_A="$(lane QUIET spry-vc Manual 'spry-vc|Manual|quiet' 'dispatch-only, never run')"

echo "=== exit-code contract ==="

assert_exit 0 "all lanes green means converged" \
  "$(mkfix all-green "$GREEN_A" "$GREEN_B")"

assert_exit 1 "one red lane blocks convergence" \
  "$(mkfix one-red "$GREEN_A" "$RED_A" "$GREEN_B")"

# The defect this whole portfolio is chasing. A repo with commits and no CI is
# not quiet, it is a finding, and it must block convergence exactly like a red
# lane — otherwise the silence stays invisible forever, which is how this very
# repository went without CI in the first place.
assert_exit 1 "a SILENT lane blocks convergence just like a red one" \
  "$(mkfix one-silent "$GREEN_A" "$SILENT_A")"

assert_exit 2 "green plus pending is not yet terminal" \
  "$(mkfix pending "$GREEN_A" "$PEND_A")"

# Red outranks pending: a fleet with a known failure is not "still waiting".
assert_exit 1 "red outranks pending" \
  "$(mkfix red-and-pending "$RED_A" "$PEND_A")"

echo "=== Rule 0: an empty input set must not read as a green day ==="

assert_exit 3 "an empty fixture is a named stop, not a clean bill of health" \
  "$(mkfix empty)"

assert_exit 3 "a fixture of only QUIET lanes counts no lanes and stops" \
  "$(mkfix quiet-only "$QUIET_A")"

asserts=$((asserts + 1))
CI_SWEEP_PROBE_FIXTURE="$TMP/does-not-exist" "$PROBE" >"$TMP/out" 2>&1
got=$?
if [ "$got" -eq 3 ]; then
  echo "  o exit 3  a missing fixture is a named stop"
else
  echo "  x exit $got (wanted 3)  a missing fixture is a named stop"
  failed=$((failed + 1))
fi

# --- negative proof ----------------------------------------------------------
# A copy of the probe with its red-lane branch neutralised must stop failing the
# red fixture. If a crippled probe still returns 1, the assertion above is not
# evidence that the probe detects anything.
echo "=== negative proof: with red detection removed, the red assertion must stop ==="
python3 - "$PROBE" "$TMP/crippled-probe.sh" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
needle = '[ "$red" -gt 0 ] && exit 1'
assert needle in s, "probe no longer contains the red-lane branch this proof neutralises"
open(dst, 'w').write(s.replace(needle, '[ "$red" -lt 0 ] && exit 1', 1))
PYEOF
chmod +x "$TMP/crippled-probe.sh"

asserts=$((asserts + 1))
CI_SWEEP_PROBE_FIXTURE="$TMP/one-red" "$TMP/crippled-probe.sh" >"$TMP/out" 2>&1
got=$?
if [ "$got" -eq 1 ]; then
  echo "  x NO TEETH — the probe still returned 1 after its red branch was removed"
  failed=$((failed + 1))
else
  echo "  o PROVEN   removing the red branch changes the exit code (got $got), so the"
  echo "             red assertion is really reading the probe's decision"
fi

# --- a lane outside the newest-80 window is not a lane that never ran ----------
# 2026-10-30: one 15-minute lane filled local-guides-generator's newest 80 runs,
# and three daily/weekly lanes with hundreds of green runs were declared
# SILENT/NEVER_RAN. lane_latest must fall back to the lane's own endpoint, and
# must report an unreadable endpoint as unproven (2), never as "no run".
echo "=== lane_latest: window overflow falls back to the workflow's own endpoint ==="
mkdir -p "$TMP/stubbin"
cat >"$TMP/stubbin/gh" <<'GHEOF'
#!/bin/bash
# Stub of `gh api .../actions/workflows/<file>/runs?...` answering post -q output.
case "$*" in
  *workflows/daily.yml/runs*)  echo '{"runs":[{"databaseId":213,"status":"completed","conclusion":"success","createdAt":"2026-10-30T13:19:38Z"}]}' ;;
  *workflows/never.yml/runs*)  echo '{"runs":[]}' ;;
  *workflows/inwindow.yml/*)   echo "STUB: in-window lane must not hit the endpoint" >&2; exit 9 ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$TMP/stubbin/gh"
printf '%s' '[{"workflowName":"Busy tick","status":"completed","conclusion":"success","createdAt":"2026-10-30T13:00:00Z","databaseId":1},{"workflowName":"In_window","status":"completed","conclusion":"success","createdAt":"2026-10-30T12:00:00Z","databaseId":7}]' >"$TMP/window.json"

lane_case() {  # <probe> <want-exit> <want-id-or-empty> <what> <repo branch flow path>
  local probe="$1" want="$2" wantid="$3" what="$4" args="$5" out got id
  asserts=$((asserts + 1))
  out="$(PATH="$TMP/stubbin:$PATH" CI_SWEEP_PROBE_LANE_RUNS="$TMP/window.json" \
        CI_SWEEP_PROBE_LANE_LATEST="$args" "$probe" 2>"$TMP/err")"; got=$?
  id="$(printf '%s' "$out" | jq -r '.databaseId // empty' 2>/dev/null)"
  if [ "$got" -eq "$want" ] && [ "$id" = "$wantid" ]; then
    echo "  o exit $got id=${id:-none}  $what"; return 0
  fi
  echo "  x exit $got id=${id:-none} (wanted $want id=${wantid:-none})  $what"
  sed 's/^/        /' "$TMP/err"; return 1
}
lane_case "$PROBE" 0 7 "a lane in the window is answered from it, never its endpoint" \
  "r main In_window .github/workflows/inwindow.yml" || failed=$((failed + 1))
lane_case "$PROBE" 0 213 "a lane pushed out of the window is found at its own endpoint" \
  "r main Daily .github/workflows/daily.yml" || failed=$((failed + 1))
lane_case "$PROBE" 0 "" "a lane with no run anywhere really is 'no run'" \
  "r main Never .github/workflows/never.yml" || failed=$((failed + 1))
lane_case "$PROBE" 2 "" "an unreadable endpoint is unproven (2), never 'no run'" \
  "r main Broken .github/workflows/broken.yml" || failed=$((failed + 1))

echo "=== negative proof: without the endpoint fallback, the overflow case must fail ==="
python3 - "$PROBE" "$TMP/no-fallback-probe.sh" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
needle = '[ -n "$wpath" ] || return 0'
assert needle in s, "probe no longer contains the endpoint fallback this proof removes"
open(dst, 'w').write(s.replace(needle, 'return 0', 1))
PYEOF
chmod +x "$TMP/no-fallback-probe.sh"
asserts=$((asserts + 1))
if lane_case "$TMP/no-fallback-probe.sh" 0 213 "(crippled) overflow lane" \
     "r main Daily .github/workflows/daily.yml" >/dev/null; then
  echo "  x NO TEETH — the overflow lane was still found with the fallback removed"
  failed=$((failed + 1))
else
  echo "  o PROVEN   removing the endpoint fallback loses the overflow lane"
fi

if [ "$asserts" -eq 0 ]; then
  echo "RULE 0 [ASSERTED_NOTHING] this suite executed zero assertions."
  exit 2
fi

echo "=== $asserts assertion(s) executed ==="
if [ "$failed" -gt 0 ]; then
  echo "PROBE TESTS FAILED: $failed of $asserts."
  exit 1
fi
echo "ci-sweep-probe.sh maps lane states to exit codes correctly and refuses an empty input."
exit 0
