#!/bin/bash
# shellcheck disable=SC2034,SC2329  # route vars and stubs are read by the land blocks eval'd below
# A deploy that fires on CI is not looked for until CI has finished (22 Nov 2026, west-peek-os #584:
# land printed "#584 IS MERGED and main is green", then NAMED STOP [DEPLOY_RUN_NOT_FOUND] after 5 min,
# while CI on the merge commit was still queued and deploy.yml runs only on CI's workflow_run).
# Evals land's deploy_gates, deploy_wf, gate_wait and deploy_wait blocks verbatim against a fake gh
# whose CI run moves only when it is read, and whose Deploy run exists only once CI has finished.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="${LAND_UNDER_TEST:-$HERE/../land}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
BLOCKS="$(sed -n '/^# --- run_conclusion begin/,/^# --- run_conclusion end/p;/^# --- gates begin/,/^# --- gates end/p;/^# --- deploy_gates begin/,/^# --- deploy_gates end/p;/^# --- deploy_wf begin/,/^# --- deploy_wf end/p;/^# --- gate_wait begin/,/^# --- gate_wait end/p' "$LAND")"
WAIT="$(sed -n '/^# --- deploy_wait begin/,/^# --- deploy_wait end/p' "$LAND")"
[ -n "$WAIT" ] && grep -q 'gate_wait()' <<<"$BLOCKS" && grep -q 'deploy_gates()' <<<"$BLOCKS" \
  || { echo "FAIL test-land-gate-wait: a land block is missing (deploy_gates, gate_wait or deploy_wait)"; exit 1; }
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# The fake gh. The CI run's states are consumed one per read (CI_STATES, the last one repeats); a read
# that returns "completed" marks CI done, and only then does the Deploy run exist. --jq/-q filters run
# through the real jq, so land's own filters are what is tested.
cat > "$W/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$STATE/calls"
q=""; prev=""; for a in "$@"; do [ "$prev" = "-q" ] || [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
out() { if [ -n "$q" ]; then jq -r "$q"; else cat; fi; }
case "$*" in
  "run list --branch main"*)
    case "${CI_FAIL:-}" in
      ratelimit) echo "HTTP 403: API rate limit exceeded for installation ID 1." >&2; exit 1 ;;
      auth) echo "HTTP 401: Requires authentication (https://api.github.com)" >&2; exit 1 ;;
    esac
    n=$(cat "$STATE/ci_reads" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STATE/ci_reads"
    read -r -a S <<<"${CI_STATES:-}"
    [ "${#S[@]}" -gt 0 ] || { echo '[]' | out; exit 0; }
    i=$(( n <= ${#S[@]} ? n - 1 : ${#S[@]} - 1 )); cur="${S[$i]}"
    st="${cur%%:*}"; conc=""; [ "$cur" = "${cur#*:}" ] || conc="${cur#*:}"
    [ "$st" = completed ] && [ "${CI_DONE_STARTS_DEPLOY:-1}" = 1 ] && [ "$conc" = success ] && touch "$STATE/ci_done"
    extra=""; [ -z "${LATER_RUN:-}" ] || extra=",{\"databaseId\":502,\"headSha\":\"later999\",\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"CI\"}"
    [ -z "${LATER_RUN:-}" ] || touch "$STATE/ci_done"
    printf '[%s{"databaseId":501,"headSha":"%s","status":"%s","conclusion":%s,"name":"CI"},{"databaseId":400,"headSha":"%s","status":"completed","conclusion":"success","name":"Playwright"}]\n' \
      "${extra:+${extra#,},}" "$MSHA" "$st" "$( [ -n "$conc" ] && echo "\"$conc\"" || echo null)" "$MSHA" | out ;;
  "run list --workflow deploy.yml"*)
    if [ -f "$STATE/ci_done" ] || [ "${DEPLOY_ON_PUSH:-}" = 1 ]; then
      printf '[{"databaseId":77,"headSha":"%s","status":"in_progress","conclusion":null}]\n' "$( [ -n "${LATER_RUN:-}" ] && echo later999 || echo "$MSHA")" | out
    else echo '[]' | out; fi ;;
  "api repos/{owner}/{repo}/actions/runs/77"*) echo success ;;
  "run cancel"*) touch "$STATE/cancelled" ;;
  *) echo "" ;;
esac
SH
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" STATE="$W"

CI_YML=$'name: Deploy\non:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n    branches: [main]\n  workflow_dispatch:\njobs: {}'
PUSH_YML=$'name: Deploy\non:\n  push:\n    branches: [ main ]\n  workflow_run:\n    workflows:\n      - Nightly\n    types: [ completed ]\njobs: {}'

SAME_TREE_GREEN="$(sed -n 's/^  GREEN="\(.*\)"$/\1/p' "$LAND" | head -1)" # what land says on the same-tree path, read from land
[ -n "$SAME_TREE_GREEN" ] || { echo "FAIL test-land-gate-wait: land sets no GREEN on the same-tree path"; exit 1; }
run_wait() { # env: CI_STATES DEPLOY_TEXT MAIN_HEAD [LAND_MAIN_WAIT_SECS CI_FAIL LATER_RUN DEPLOY_ON_PUSH] -> prints output; rc file
  rm -f "$W/calls" "$W/ci_reads" "$W/ci_done" "$W/cancelled" "$W/rate-waits"
  ( LAND_POLL_SECS=0 LAND_DEPLOY_APPEAR_SECS="${APPEAR:-2}" LAND_MAIN_WAIT_SECS="${LAND_MAIN_WAIT_SECS:-5}" # bounded even under a mutation
    eval "$BLOCKS"
    sleep() { command sleep 0.1; }
    rate_wait() { is_rate_limit "$1" || return 1; echo x >> "$W/rate-waits"; return 0; }
    git() { case "$1 ${2:-}" in
        "cat-file -e") return 0 ;;
        "show origin/main:.github/workflows/deploy.yml") printf '%s\n' "$DEPLOY_TEXT" ;;
        "fetch -q") return 0 ;;
        "rev-parse origin/main") echo "$MAIN_HEAD" ;;
        "merge-base --is-ancestor") [ "$3" = "$4" ] || { [ "$3" = "$MSHA" ] && [ "$4" = later999 ]; } ;;
        *) return 1 ;;
      esac; }
    say() { printf '%s\n' "$*"; }
    die() { printf '\nSTOPPED: %s\n' "$*"; exit 1; }
    last_duration() { echo 600; }
    smoke_check() { return 0; }
    LAND_RC_UNVERIFIED=75 PR=584 NAME=west-peek-os E2E_WF="" SMOKE="" MERGESHA="$MSHA" DEPLOY_WF=deploy.yml
    GREEN="${GREEN0:-$SAME_TREE_GREEN}"
    eval "$WAIT"
    echo "(fell through)" ) > "$W/out" 2>&1
  echo $? > "$W/rc"
}
rc() { cat "$W/rc"; }
has() { grep -qF -- "$1" "$W/out"; }
green_before_ci() { # any "green" before the line that reports CI's success (or anywhere, if there is none)
  local ln; ln="$(grep -n "completed success" "$W/out" | head -1 | cut -d: -f1)"
  if [ -n "$ln" ]; then head -n "$((ln - 1))" "$W/out" | grep -qi green; else grep -qi 'main is green' "$W/out"; fi
}
show() { sed 's/^/        | /' "$W/out"; }
export MSHA=4d69588abcdef

echo "=== 1. CI still queued when the deploy lookup starts (the #584 shape) ==="
CI_STATES="queued queued queued in_progress completed:success" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA run_wait
if [ "$(rc)" = 0 ] && ! has "STOPPED" && has "LANDED — #584 is merged, main is green, and deploy.yml run 77 shipped 4d69588"; then ok "waited for CI, then for the deploy run: LANDED, not STOPPED"; else bad "queued CI: rc $(rc)"; show; fi
if ! green_before_ci; then ok "nothing says green before CI's run finished"; else bad "green was printed before CI finished"; show; fi
[ "$(cat "$W/ci_reads" 2>/dev/null)" = 5 ] && ok "CI read once per poll until it finished (5 reads)" || { bad "CI reads: $(cat "$W/ci_reads" 2>/dev/null)"; show; }
has "is queued — deploy.yml fires only when it finishes" && ok "says why it is waiting" || { bad "no waiting line"; show; }

echo "=== 2. CI on the merge commit finishes red ==="
CI_STATES="in_progress completed:failure" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA run_wait
if [ "$(rc)" = 1 ] && has "finished failure, so deploy.yml will not ship it" && ! grep -qi "main is green" "$W/out" && ! grep -q "run list --workflow deploy.yml" "$W/calls"; then ok "refused, never green, the deploy never looked for"; else bad "red CI: rc $(rc)"; show; fi

echo "=== 3. CI still running at the bound: unsure (75), never cancelled, never green ==="
CI_STATES="queued" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA LAND_MAIN_WAIT_SECS=1 run_wait
if [ "$(rc)" = 75 ] && has "NAMED STOP [MAIN_CI_UNFINISHED]" && [ ! -f "$W/cancelled" ] && ! grep -qi "main is green" "$W/out"; then ok "MAIN_CI_UNFINISHED, exit 75, the run left alone"; else bad "unfinished CI: rc $(rc)"; show; fi

echo "=== 4. CI's run list rate-limited, then auth-failed: could not verify (75) ==="
CI_STATES="completed:success" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA CI_FAIL=ratelimit run_wait
if [ "$(rc)" = 75 ] && has "could not verify" && has "NAMED STOP [MAIN_CI_UNREADABLE]" && ! has "LANDED" && [ "$(grep -c . "$W/rate-waits" 2>/dev/null)" = 1 ]; then ok "rate limit: waited for the reset once, then exit 75 with its STOPPED line"; else bad "rate-limited: rc $(rc)"; show; fi
CI_STATES="completed:success" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA CI_FAIL=auth run_wait
if [ "$(rc)" = 75 ] && has "could not verify" && ! has "LANDED" && ! grep -qi "main is green" "$W/out"; then ok "auth failure: exit 75, never green"; else bad "auth-failed: rc $(rc)"; show; fi

echo "=== 5. CI cancelled with no later commit: a named stop, not a 45-minute wait ==="
CI_STATES="completed:cancelled" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA run_wait
if [ "$(rc)" = 1 ] && has "NAMED STOP [MAIN_CI_CANCELLED]" && has "gh run rerun 501"; then ok "MAIN_CI_CANCELLED names the re-run"; else bad "cancelled CI: rc $(rc)"; show; fi

echo "=== 6. CI cancelled because a later merge superseded it: the later run carries it ==="
CI_STATES="completed:cancelled" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=later999 LATER_RUN=1 run_wait
if [ "$(rc)" = 0 ] && has "main's CI run 502 carrying 4d69588: completed success" && has "LANDED"; then ok "followed the later run that contains the merge"; else bad "superseded CI: rc $(rc)"; show; fi

echo "=== 7. no CI run for the merge ever appears ==="
CI_STATES="" DEPLOY_TEXT="$CI_YML" MAIN_HEAD=$MSHA LAND_MAIN_WAIT_SECS=1 run_wait
if [ "$(rc)" = 1 ] && has "NAMED STOP [MAIN_CI_NOT_FOUND]" && ! grep -qi "main is green" "$W/out"; then ok "MAIN_CI_NOT_FOUND, never green"; else bad "no CI run: rc $(rc)"; show; fi

echo "=== 8. a deploy that also fires on push is not held for its workflow_run gates ==="
CI_STATES="" DEPLOY_TEXT="$PUSH_YML" MAIN_HEAD=$MSHA DEPLOY_ON_PUSH=1 GREEN0="main is green" run_wait
if [ "$(rc)" = 0 ] && has "LANDED" && [ ! -f "$W/ci_reads" ]; then ok "push-triggered deploy: no gate wait, shipped"; else bad "push deploy: rc $(rc)"; show; fi

echo "=== 8b. same-tree path, a push deploy that never appears: the stop does not call main green ==="
CI_STATES="" DEPLOY_TEXT="$PUSH_YML" MAIN_HEAD=$MSHA run_wait
if [ "$(rc)" = 1 ] && has "NAMED STOP [DEPLOY_RUN_NOT_FOUND]" && ! grep -qi "main is green" "$W/out"; then ok "DEPLOY_RUN_NOT_FOUND names what was proven, never \"main is green\""; else bad "same-tree stop: rc $(rc)"; show; fi

echo "=== 9. deploy_gates reads every shape in her repos ==="
eval "$(sed -n '/^# --- deploy_gates begin/,/^# --- deploy_gates end/p' "$LAND")"
g() { deploy_gates <<<"$1" | paste -sd'|' -; }
[ "$(g "$CI_YML")" = "CI" ] && ok "[CI]" || bad "[CI] -> '$(g "$CI_YML")'"
y=$'on:\n  workflow_run:\n    workflows: ["Repository validation"] # the gate\n    types: [completed]'
[ "$(g "$y")" = "Repository validation" ] && ok "quoted name with a space keeps the space" || bad "quoted -> '$(g "$y")'"
y=$'on:\n  workflow_run:\n    workflows:\n      - Validate Repo\n      - \'Bounded Self-Healing\'\n    types:\n      - completed'
[ "$(g "$y")" = "Validate Repo|Bounded Self-Healing" ] && ok "a - list" || bad "list -> '$(g "$y")'"
y=$'on:\n  workflow_run:\n    workflows:\n      ["Daily Cycle", "Search Loop"]\n    types: [completed]'
[ "$(g "$y")" = "Daily Cycle|Search Loop" ] && ok "a bracket list on the next line" || bad "next-line list -> '$(g "$y")'"
y=$'on:\n  push:\n    branches: [main]\njobs:\n  x:\n    # workflows: [nope]\n    runs-on: ubuntu-latest'
[ -z "$(g "$y")" ] && ok "no workflow_run: no gates" || bad "push only -> '$(g "$y")'"

[ "$fails" -eq 0 ] && echo "PASS test-land-gate-wait" || { echo "FAIL test-land-gate-wait: $fails"; exit 1; }
