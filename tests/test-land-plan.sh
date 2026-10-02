#!/bin/bash
# land must decide staging / production / suite / blocked from the route, the e2e verdict on the
# sha, the size of the change, and whether the suite is known red.
#
# Build first, test in batches (26 Sep 2026): a repo whose route names a full e2e workflow deploys
# staging on every land. Until 2 Oct 2026 production then moved ONLY when a completed run of that
# workflow on the exact merged sha concluded success, and everything else printed WAITING. With the
# suites on demand only, that held six repos on staging behind small changes nothing would ever run
# a suite for. The owner's ruling (2 Oct 2026): a SMALL change ships on the fast check alone; e2e
# gates production only after a LARGE change or when asked. What stays true, and is pinned here at
# least as strictly as the WAITING rule was:
#   · a LARGE change never reaches production without the suite (plan step `suite`);
#   · a small change never ships past a suite that is KNOWN RED on main (`blocked`);
#   · "could not read whether it is red" is never "not red" (`blocked`, fail closed);
#   · a red verdict on the exact sha blocks whatever came after it.
# This evals the `plan` block (two pure functions, no gh, no git) and the `verdict` block (the jq
# that picks the newest run that reached a verdict, driven through a fake gh over a fixture) out of
# `land` verbatim, checks every branch, then breaks each rule and proves the check would fail.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- plan begin/,/^# --- plan end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the plan block"; exit 1; }
VERDICT="$(sed -n '/^# --- verdict begin/,/^# --- verdict end/p' "$LAND")"
[ -n "$VERDICT" ] || { echo "FAIL: land no longer carries the verdict block"; exit 1; }
eval "$BLOCK"
fails=0; n=0
check() { # label expected actual
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "  ok   $1 → '$3'"; else echo "  FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi
}
P="npm run deploy:production"; S="npm run deploy:staging"; L="300 lines changed (+250/-50) ≥ 200"

echo "land_plan DEPLOY STAGING E2E_WF E2E_CONCLUSION LARGE LAST_VERDICT"
echo " — a green run on the exact sha ships, as before"
check "e2e green on the sha: staging then production"              "staging production" "$(land_plan "$P" "$S" e2e success "" "")"
check "…large or not"                                              "staging production" "$(land_plan "$P" "$S" e2e success "$L" failure)"
check "…with no staging command"                                   "production"         "$(land_plan "$P" "" e2e success "" "")"
echo " — a SMALL change ships on the fast check, unless the suite is known red"
check "small, the last verdict on main is success: production"     "staging production" "$(land_plan "$P" "$S" e2e "" "" success)"
check "small, no run on main ever reached a verdict: production"   "staging production" "$(land_plan "$P" "$S" e2e "" "" none)"
check "small, no staging command"                                  "production"         "$(land_plan "$P" "" e2e "" "" success)"
check "small, last verdict failure: blocked"                       "staging blocked"    "$(land_plan "$P" "$S" e2e "" "" failure)"
check "small, last verdict timed_out: blocked"                     "staging blocked"    "$(land_plan "$P" "$S" e2e "" "" timed_out)"
check "small, last verdict startup_failure: blocked"               "staging blocked"    "$(land_plan "$P" "$S" e2e "" "" startup_failure)"
check "small, a word this does not know is not 'not red'"          "staging blocked"    "$(land_plan "$P" "$S" e2e "" "" action_required)"
check "small, known red, no staging command: blocked"              "blocked"            "$(land_plan "$P" "" e2e "" "" failure)"
echo " — fail closed: an unread verdict is never 'not red' (these were the WAITING pins)"
check "no completed run on the sha, verdict unread: blocked"       "staging blocked"    "$(land_plan "$P" "$S" e2e "")"
check "e2e failed on the sha, verdict unread: blocked"             "staging blocked"    "$(land_plan "$P" "$S" e2e failure)"
check "e2e cancelled on the sha, verdict unread: blocked"          "staging blocked"    "$(land_plan "$P" "$S" e2e cancelled)"
check "no staging command, verdict unread: blocked"                "blocked"            "$(land_plan "$P" "" e2e "")"
check "an empty verdict passed explicitly: blocked"                "staging blocked"    "$(land_plan "$P" "$S" e2e "" "" "")"
echo " — a red verdict on the exact sha blocks a small change whatever came after"
check "failed on the sha, though main's last verdict is green"     "staging blocked"    "$(land_plan "$P" "$S" e2e failure "" success)"
check "timed_out on the sha, last verdict green"                   "staging blocked"    "$(land_plan "$P" "$S" e2e timed_out "" success)"
check "a CANCELLED run on the sha is not a verdict: last decides"  "staging production" "$(land_plan "$P" "$S" e2e cancelled "" success)"
check "…and still blocks when the last verdict is red"             "staging blocked"    "$(land_plan "$P" "$S" e2e cancelled "" failure)"
check "a skipped run on the sha is not a verdict either"           "staging production" "$(land_plan "$P" "$S" e2e skipped "" none)"
echo " — a LARGE change (or --run-e2e) never ships without the suite"
check "large, no run on the sha: suite"                            "staging suite"      "$(land_plan "$P" "$S" e2e "" "$L" success)"
check "large, the suite is known red: suite (a green run clears it)" "staging suite"    "$(land_plan "$P" "$S" e2e "" "$L" failure)"
check "large, e2e failed on the sha: suite again"                  "staging suite"      "$(land_plan "$P" "$S" e2e failure "$L" failure)"
check "large, verdict unread: suite"                               "staging suite"      "$(land_plan "$P" "$S" e2e "" "$L" "")"
check "--run-e2e on a small change: suite"                         "staging suite"      "$(land_plan "$P" "$S" e2e "" "--run-e2e given" success)"
check "large, no staging command: suite"                           "suite"              "$(land_plan "$P" "" e2e "" "$L" none)"
echo " — routes without an e2e workflow, and self-deploying repos, are unchanged"
check "no e2e workflow on the route: production at once"           "production"         "$(land_plan "$P" "" "" "")"
check "no e2e workflow, whatever the size or the verdict words"    "production"         "$(land_plan "$P" "" "" "" "$L" failure)"
check "no e2e workflow but a staging command: staging then production" "staging production" "$(land_plan "$P" "$S" "" "")"
check "self-deploying repo: self"                                  "self"               "$(land_plan "" "" "" "")"
check "self-deploying repo with staging: staging then self"        "staging self"       "$(land_plan "" "$S" "" "")"
check "a green e2e verdict never reaches production without a deploy command" "self"   "$(land_plan "" "" e2e success)"
check "a small change never reaches production without one either" "self"               "$(land_plan "" "" e2e "" "" success)"
echo " — a PROMOTE_VIA route (the repo's own workflow moves production) follows the same plan"
check "promote.yml, small, last verdict green: production"         "production"         "$(land_plan promote.yml "" e2e "" "" success)"
check "promote.yml, small, known red: blocked"                     "blocked"            "$(land_plan promote.yml "" e2e "" "" failure)"
check "promote.yml, large: suite"                                  "suite"              "$(land_plan promote.yml "" e2e "" "$L" success)"

echo "promote_pick PRODUCTION_SHA < main newest-first"
pick() { # prod, then lines
  local prod="$1"; shift
  printf '%s\n' "$@" | promote_pick "$prod" || echo "NONE"
}
check "newest green above production wins"             "c" "$(pick a $'d\tother' $'c\tgreen' $'b\tgreen' $'a\tgreen')"
check "head itself when green"                         "d" "$(pick a $'d\tgreen' $'c\tgreen' $'a\tgreen')"
check "production is the newest green: nothing"        "NONE" "$(pick c $'d\tother' $'c\tgreen' $'b\tgreen')"
check "production is head: nothing"                    "NONE" "$(pick d $'d\tgreen' $'c\tgreen')"
check "nothing green above production: nothing"        "NONE" "$(pick a $'d\tother' $'c\tfailure' $'a\tgreen')"
check "a green commit BELOW production never ships"    "NONE" "$(pick c $'d\tother' $'c\tother' $'b\tgreen')"
check "unrecorded production: the newest green"        "c" "$(pick "" $'d\tother' $'c\tgreen' $'b\tgreen')"
check "unrecorded production and nothing green: nothing" "NONE" "$(pick "" $'d\tother' $'c\tother')"
check "empty list: nothing"                            "NONE" "$(pick a)"

# e2e_last_verdict: the verdict block, verbatim, through a fake gh that answers `run list … -q
# <filter>` with a fixture run list (newest first, as gh prints it) through real jq.
echo "e2e_last_verdict — the newest run on main that reached a verdict"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; C="cccccccccccccccccccccccccccccccccccccccc"
run() { printf '{"databaseId":%s,"headSha":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3" "$4"; }
last() { # runs (JSON objects, newest first) -> what e2e_last_verdict prints
  local IFS=,
  echo "[$*]" > "$WORK/runs.json"
  ( E2E_WF=e2e
    gh() { local q=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && q="$2"; shift; done; jq -r "$q" "$WORK/runs.json"; }
    gh_read() { local want="$1" out; shift; out="$(gh "$@")" || return 1; grep -qE "$want" <<<"$out" || return 1; printf '%s\n' "$out"; }
    eval "$VERDICT"; e2e_last_verdict )
}
T=$'\t'
check "no runs at all: none"                                    "none" "$(last)"
check "the newest completed run is green"                       "success${T}30${T}$C" "$(last "$(run 30 $C completed '"success"')" "$(run 20 $B completed '"failure"')")"
check "the newest completed run is red, a green one is OLDER: red" "failure${T}30${T}$C" "$(last "$(run 30 $C completed '"failure"')" "$(run 20 $B completed '"success"')")"
check "a green run NEWER than the red one clears it"            "success${T}30${T}$C" "$(last "$(run 30 $C completed '"success"')" "$(run 20 $B completed '"failure"')" "$(run 10 $A completed '"success"')")"
check "a cancelled run is passed over: the red under it stands" "failure${T}20${T}$B" "$(last "$(run 30 $C completed '"cancelled"')" "$(run 20 $B completed '"failure"')")"
check "a cancelled run is passed over: the green under it stands" "success${T}20${T}$B" "$(last "$(run 30 $C completed '"cancelled"')" "$(run 20 $B completed '"success"')")"
check "a skipped run is passed over"                            "failure${T}10${T}$A" "$(last "$(run 30 $C completed '"skipped"')" "$(run 10 $A completed '"failure"')")"
check "a run still in flight proves nothing: the red under it stands" "failure${T}20${T}$B" "$(last "$(run 30 $C in_progress null)" "$(run 20 $B completed '"failure"')")"
check "timed_out is a verdict, and it is red"                   "timed_out${T}30${T}$C" "$(last "$(run 30 $C completed '"timed_out"')" "$(run 20 $B completed '"success"')")"
check "only cancelled runs: none"                               "none" "$(last "$(run 30 $C completed '"cancelled"')")"
check "an answer that is not a verdict line is NOTHING (unread)" "" "$( ( E2E_WF=e2e; gh_read() { return 1; }; eval "$VERDICT"; e2e_last_verdict ) )"
# …and what the plan does with each of those answers, end to end through both blocks.
via() { local v; v="$(last "$@")"; land_plan "$P" "$S" e2e "" "" "${v%%$'\t'*}"; }
check "small + red newer than the last green: blocked"          "staging blocked"    "$(via "$(run 30 $C completed '"failure"')" "$(run 20 $B completed '"success"')")"
check "small + green newer than the red: production"            "staging production" "$(via "$(run 30 $C completed '"success"')" "$(run 20 $B completed '"failure"')")"
check "small + cancelled over red: blocked"                     "staging blocked"    "$(via "$(run 30 $C completed '"cancelled"')" "$(run 20 $B completed '"failure"')")"
check "small + no history: production"                          "staging production" "$(via)"

# NEGATIVE PROOFS: each rule broken in a copy of the block must change an answer checked above.
neg() { # label, sed expression over the plan block, args for land_plan..., then the wrong answer the break produces
  local label="$1" expr="$2" wrong="$3"; shift 3
  local broken got
  broken="$(printf '%s\n' "$BLOCK" | sed "$expr")"
  n=$((n+1))
  if [ "$broken" = "$BLOCK" ]; then echo "  FAIL negative proof ($label): could not construct the broken plan"; fails=$((fails+1)); return; fi
  got="$( (eval "$broken"; land_plan "$@") )"
  if [ "$got" = "$wrong" ]; then echo "  ok   negative proof: $label ('$got') — and the checks above would catch it"
  else echo "  FAIL negative proof ($label) did not exercise the broken branch: got '$got'"; fails=$((fails+1)); fi
}
neg "a plan that ships a LARGE change without the suite" \
    '/if \[ -n "\$large" \]; then/d' "staging production" "$P" "$S" e2e "" "$L" success
neg "a plan that ships a small change past a KNOWN RED suite" \
    's/^    success|none) /    success|none|failure) /' "staging production" "$P" "$S" e2e "" "" failure
neg "a plan that reads an UNREAD verdict as not red" \
    's/^    success|none) /    success|none|"") /' "staging production" "$P" "$S" e2e "" "" ""
neg "a plan that ignores a red verdict on the exact sha" \
    '/case "\$conc" in ""|cancelled|skipped) : ;;/d' "staging production" "$P" "$S" e2e failure "" success
# …and the verdict filter: one that does not pass over a cancelled run calls a red suite "cancelled".
BROKENV="$(printf '%s\n' "$VERDICT" | sed 's/ and \.conclusion != "cancelled"//')"
n=$((n+1))
if [ "$BROKENV" = "$VERDICT" ]; then echo "  FAIL negative proof: could not construct the broken verdict filter"; fails=$((fails+1))
else
  echo "[$(run 30 $C completed '"cancelled"'),$(run 20 $B completed '"failure"')]" > "$WORK/runs.json"
  # shellcheck disable=SC2034  # E2E_WF is read by the eval'd verdict block
  got="$( ( E2E_WF=e2e
    gh() { local q=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && q="$2"; shift; done; jq -r "$q" "$WORK/runs.json"; }
    gh_read() { shift; gh "$@"; }
    eval "$BROKENV"; e2e_last_verdict ) )"
  if [ "${got%%$'\t'*}" = cancelled ]; then echo "  ok   negative proof: a filter that keeps cancelled runs answers '${got%%$'\t'*}' over a red suite — caught above"
  else echo "  FAIL negative proof (verdict filter) did not exercise the break: got '$got'"; fails=$((fails+1)); fi
fi

[ "$n" -ge 65 ] || { echo "FAIL: examined only $n cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-plan: $fails failure(s)"; exit 1; }
echo "test-land-plan: $n cases passed — staging on every land; a small change ships on the fast check unless the suite is known red or unread; a large change only through the suite; promote picks the newest green above production"
