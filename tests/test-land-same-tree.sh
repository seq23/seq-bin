#!/bin/bash
# land ships on the PR's green run ONLY when the merge is the same code (22 Nov 2026, her ask:
# "make this faster and not sacrifice quality"). Runs land's same_tree block against stub gh/git
# and checks the decision for each shape, with the skip-everything mutation as a negative proof.
set -uo pipefail
LAND="$(cd "$(dirname "$0")" && pwd)/../land"
BLOCK="$(sed -n '/^# --- deploy_gates begin/,/^# --- deploy_gates end/p;/^# --- same_tree begin/,/^# --- same_tree end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL test-land-same-tree: same_tree block not found"; exit 1; }
fails=0
decide() { # $1 block text; env: TM TH WF GATE PRWF RUNID HEADV MSHA → prints SAME_TREE
  ( gh() { case "$*" in
        *actions/workflows*) [ -n "${WFP:-}" ] && echo "$WFP" ;;
        *"commits/msha"*) [ -n "$TM" ] && echo "$TM" || return 1 ;;
        *"commits/hsha"*) [ -n "$TH" ] && echo "$TH" || return 1 ;;
        *mergeCommit*) echo msha ;;
      esac; }
    git() { case "$2" in
        origin/main:.github/workflows/deploy.yml) [ -n "$GATE" ] && printf 'on:\n  workflow_run:\n    workflows: [%s]\n' "$GATE" || return 1 ;;
        origin/main:.github/workflows/v.yml) printf '%s\n' "$WF" ;;
        *) return 1 ;;
      esac; }
    # shellcheck disable=SC2034  # read by the eval'd land block
    PR=1 PR_WF="$PRWF" RUNID="$RUNID" HEAD="$HEADV" MERGESHA="$MSHA" WFP="${WFP-.github/workflows/v.yml}"
    eval "$1"; echo "${SAME_TREE:-}" )
}
WFOK=$'name: validate\non: [push, pull_request]\nconcurrency:\n  group: v-${{ github.ref }}\njobs: {}'
WFEV=$'name: validate\njobs:\n  a:\n    if: github.event_name == '"'push'"
case_() { # name expect; env set by caller
  got="$(decide "$BLOCK")"
  [ "$got" = "$2" ] && echo "  ok   $1" || { echo "  FAIL $1 (got '${got}', want '$2')"; fails=$((fails+1)); }
}
base() { TM=t1 TH=t1 WF="$WFOK" GATE="" PRWF=validate RUNID=9 HEADV=hsha MSHA=msha; unset WFP; }
base; case_ "same tree, no gate, workflow is event-blind → ships on the PR run" 1
base; TH=t2; case_ "one byte different (tree differs) → watches main" ""
base; TM=""; case_ "merge tree unreadable → watches main" ""
base; TH=""; case_ "head tree unreadable → watches main" ""
base; RUNID=""; case_ "step 1 never verified the PR (already merged) → watches main" ""
base; GATE=deploy-gate; case_ "deploy.yml gates on another workflow → watches main" ""
base; GATE=validate; case_ "deploy.yml gates on the PR's own workflow → ships on the PR run" 1
base; WF="$WFEV"; case_ "workflow acts differently on push (github.event) → watches main" ""
base; WFP=""; case_ "PR workflow file not found → watches main" ""
base; PRWF=""; case_ "PR workflow unknown → watches main" ""
# Negative proof: a block that skips without comparing trees must fail the "differs" case.
MUT="$(sed 's/\[ "\$ST_TM" = "\$ST_TH" \]/true/' <<<"$BLOCK")"
base; TH=t2; got="$(decide "$MUT")"
[ "$got" = 1 ] && echo "  ok   negative proof: without the tree comparison, a different tree would ship" || { echo "  FAIL negative proof did not bite"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS test-land-same-tree" || { echo "FAIL test-land-same-tree ($fails)"; exit 1; }
