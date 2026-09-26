#!/bin/bash
# land must decide staging / production / waiting from the route and the full-e2e verdict.
#
# Build first, test in batches (26 Sep 2026): a repo whose route names a full e2e workflow deploys
# staging on every land and production ONLY when a completed run of that workflow on the exact
# merged sha concluded success; otherwise it reports WAITING (exit 0) and `land --promote` ships
# the newest e2e-green commit later. Routes without an e2e workflow are unchanged (production at
# once). This evals the `plan` block out of `land` verbatim — two pure functions, no gh, no git —
# and checks every branch of both, then breaks the "waiting" branch and proves the check fails.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- plan begin/,/^# --- plan end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the plan block"; exit 1; }
eval "$BLOCK"
fails=0; n=0
check() { # label expected actual
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "  ok   $1 → '$3'"; else echo "  FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi
}
P="npm run deploy:production"; S="npm run deploy:staging"

echo "land_plan DEPLOY STAGING E2E_WF E2E_CONCLUSION"
check "e2e route, e2e green on the sha: staging then production"   "staging production" "$(land_plan "$P" "$S" e2e success)"
check "e2e route, no completed e2e run on the sha: staging, waiting" "staging waiting"   "$(land_plan "$P" "$S" e2e "")"
check "e2e route, e2e failed on the sha: staging, waiting"          "staging waiting"    "$(land_plan "$P" "$S" e2e failure)"
check "e2e route, e2e cancelled on the sha: staging, waiting"       "staging waiting"    "$(land_plan "$P" "$S" e2e cancelled)"
check "e2e route with no staging command: production on green"      "production"         "$(land_plan "$P" "" e2e success)"
check "e2e route with no staging command: waiting otherwise"        "waiting"            "$(land_plan "$P" "" e2e "")"
check "no e2e workflow on the route: production at once, as before" "production"         "$(land_plan "$P" "" "" "")"
check "no e2e workflow but a staging command: staging then production" "staging production" "$(land_plan "$P" "$S" "" "")"
check "self-deploying repo: self"                                   "self"               "$(land_plan "" "" "" "")"
check "self-deploying repo with staging: staging then self"         "staging self"       "$(land_plan "" "$S" "" "")"
check "a green e2e verdict never reaches production without a deploy command" "self" "$(land_plan "" "" e2e success)"

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

# NEGATIVE PROOF: a plan that ships production without the e2e verdict must fail this test.
BROKEN="$(printf '%s\n' "$BLOCK" | sed 's/\[ "\$conc" = success \]/[ -n "$e2e" ]/')"
[ "$BROKEN" != "$BLOCK" ] || { echo "FAIL: could not construct the broken plan for the negative proof"; exit 1; }
got="$( (eval "$BROKEN"; land_plan "$P" "$S" e2e "") )"
n=$((n+1))
if [ "$got" = "staging production" ]; then echo "  ok   negative proof: the broken plan ships production unproven ('$got') and this test would catch it"
else echo "  FAIL negative proof did not exercise the broken branch: got '$got'"; fails=$((fails+1)); fi

[ "$n" -ge 20 ] || { echo "FAIL: examined only $n cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-plan: $fails failure(s)"; exit 1; }
echo "test-land-plan: $n cases passed — staging on every land, production only on a green full e2e, promote picks the newest green above production"
