#!/bin/bash
# land must re-raise a merge whose push event GitHub dropped, never watch the previous commit's run.
#
# 21 Oct 2026, p-n-p #124 (3d4ae11): the merge moved main but GitHub recorded no activity-log entry,
# no PushEvent and no webhook, so no push-triggered workflow ran and Cloudflare Pages never built;
# land fell back to main's newest run (the previous commit's) and read it as green. This evals the
# dropped_push and pages_kick blocks out of `land` verbatim against fakes and checks: a dropped push
# dispatches the PR's workflow and watches the dispatched run on the merge sha; a push GitHub DID
# record (activity entry present) is left alone; an unanswered activity read is not called dropped;
# a workflow with no workflow_dispatch is a NAMED STOP; pages_kick triggers a build for exactly the
# Pages projects that build this repo from Git (across pages of the project list), keeps the token
# off every command line, and fails named when nothing matches.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
DP="$(sed -n '/^# --- dropped_push begin/,/^# --- dropped_push end/p' "$LAND")"
PK="$(sed -n '/^# --- pages_kick begin/,/^# --- pages_kick end/p' "$LAND")"
[ -n "$DP" ] || { echo "FAIL: land no longer carries the dropped_push block"; exit 1; }
[ -n "$PK" ] || { echo "FAIL: land no longer carries the pages_kick block"; exit 1; }
grep -q 'DROPPED_PUSH:-}" \] || pages_kick' "$LAND" || { echo "FAIL: step 5 no longer calls pages_kick on a dropped push"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# ---- dropped_push ----------------------------------------------------------------------------
# shellcheck disable=SC2034  # MERGESHA, PR, PR_WF, LAND_RUN_APPEAR_SECS are read by the eval-ed block
run_dp() { # $1 activity answer ("ERR" = API error), $2 workflow file body; prints the log
  ( ACTIVITY="$1"; WFBODY="$2"; LOG="$WORK/log"; : > "$LOG"
    MERGESHA=abc123; RID=""; PR=124; PR_WF="Deploy Distribution"; LAND_RUN_APPEAR_SECS=1
    say() { echo "SAY $*" >> "$LOG"; }
    die() { echo "DIE $*" >> "$LOG"; exit 1; }
    sleep() { :; }
    gh() {
      case "$1 $2" in
        "api repos/{owner}/{repo}/activity"*) [ "$ACTIVITY" = ERR ] && return 1; printf '%s\n' "$ACTIVITY" ;;
        "api repos/{owner}/{repo}/actions/workflows"*) echo ".github/workflows/deploy-distribution.yml" ;;
        "workflow run") echo "DISPATCH $3 $4 $5" >> "$LOG"; touch "$WORK/dispatched" ;;
      esac
    }
    git() { [ "$1" = show ] && printf '%s\n' "$WFBODY"; }
    pick_run() { case "$1" in *workflow_dispatch*) [ -e "$WORK/dispatched" ] && echo 999 ;; esac; }
    rm -f "$WORK/dispatched"
    eval "$DP"
    echo "RID=$RID DROPPED=$DROPPED_PUSH" >> "$LOG"
  ); cat "$WORK/log"
}
WF=$'on:\n  push:\n    branches: [main]\n  workflow_dispatch:\n'
out="$(run_dp $'def456\n0caf7b9' "$WF")"
grep -q 'DISPATCH .github/workflows/deploy-distribution.yml --ref main' <<<"$out" && ok "dropped push dispatches the PR's workflow on main" || bad "dropped push did not dispatch ($out)"
grep -q 'RID=999 DROPPED=1' <<<"$out" && ok "dropped push watches the dispatched run on the merge sha" || bad "dropped push did not pick the dispatched run ($out)"
out="$(run_dp $'abc123\ndef456' "$WF")"
grep -q 'DISPATCH' <<<"$out" && bad "a recorded push was re-dispatched" || ok "a push GitHub recorded is left alone"
grep -q 'DROPPED=$' <<<"$out" && ok "a recorded push is not called dropped" || bad "a recorded push was called dropped ($out)"
out="$(run_dp ERR "$WF")"
grep -q 'DISPATCH' <<<"$out" && bad "an unanswered activity read was treated as a dropped push" || ok "an unanswered activity read is not called dropped"
out="$(run_dp $'def456' $'on:\n  push:\n    branches: [main]\n')"
grep -q 'DIE NAMED STOP \[PUSH_DROPPED\]' <<<"$out" && ok "no workflow_dispatch is a NAMED STOP" || bad "no workflow_dispatch did not stop named ($out)"

# ---- pages_kick ------------------------------------------------------------------------------
mkdir -p "$WORK/home/.wrangler/config"
printf 'oauth_token = "SECRET-TOKEN-XYZ"\nrefresh_token = "r"\n' > "$WORK/home/.wrangler/config/default.toml"
run_pk() { # $1 repo slug; prints the log and the function's output
  # shellcheck disable=SC2034  # CLOUDFLARE_ACCOUNT_ID is read by the eval-ed block
  ( HOME="$WORK/home"; SLUG="$1"; LOG="$WORK/pklog"; : > "$LOG"; CLOUDFLARE_ACCOUNT_ID=acct
    wrangler() { :; }
    gh() { echo "$SLUG"; }
    curl() {
      echo "ARGS $*" >> "$LOG"
      local a url=""; for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
      case "$url" in
        *"projects?page=1") echo '{"result_info":{"total_pages":2},"result":[{"name":"p-n-p","source":{"type":"github","config":{"owner":"seq23","repo_name":"p-n-p","production_branch":"main"}}},{"name":"other","source":{"type":"github","config":{"owner":"seq23","repo_name":"other","production_branch":"main"}}}]}' ;;
        *"projects?page=2") echo '{"result_info":{"total_pages":2},"result":[{"name":"p-n-p-two","source":{"type":"github","config":{"owner":"seq23","repo_name":"p-n-p","production_branch":"main"}}},{"name":"direct","source":null}]}' ;;
        */deployments) echo "POST $url" >> "$LOG"; echo '{"success":true}' ;;
      esac
    }
    eval "$PK"
    pages_kick; echo "RC=$?"
  ) > "$WORK/pkout"; cat "$WORK/pkout" "$WORK/pklog"
}
out="$(run_pk seq23/p-n-p)"
[ "$(grep -c '^POST ' <<<"$out")" = 2 ] && grep -q 'POST .*/projects/p-n-p/deployments' <<<"$out" && grep -q 'POST .*/projects/p-n-p-two/deployments' <<<"$out" \
  && ok "pages_kick triggers every project that builds this repo, across pages" || bad "pages_kick triggered the wrong set ($out)"
grep -q 'projects/other/deployments' <<<"$out" && bad "pages_kick triggered another repo's project" || ok "another repo's project is left alone"
grep -q 'RC=0' <<<"$out" && ok "pages_kick returns 0 when it triggered a build" || bad "pages_kick rc ($out)"
grep -q 'SECRET-TOKEN-XYZ' <<<"$out" && bad "the OAuth token appeared on a command line" || ok "the OAuth token never reaches a command line"
out="$(run_pk seq23/nothing-builds-me)"
grep -q 'RC=1' <<<"$out" && grep -q 'nothing to trigger' <<<"$out" && ok "no matching project fails named" || bad "no matching project did not fail named ($out)"

[ "$fails" -eq 0 ] && echo "PASS test-land-dropped-push" || { echo "FAIL test-land-dropped-push ($fails)"; exit 1; }
