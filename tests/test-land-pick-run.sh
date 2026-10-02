#!/bin/bash
# land must watch the GATE run on main, not whichever run GitHub listed last.
#
# On 21 Sep 2026 west-peek-os moved its Playwright journeys into their own workflow, so one push
# to main starts two runs. `land` used to take `[0]` of `gh run list` — with two runs that is a
# coin flip, and the loser is a 20-minute journey suite the Deploy does not wait for. This evals
# the `pick_run` block out of `land` verbatim, against a fake `gh` that returns a fixed list, and
# checks every branch: gate preferred over Playwright and Deploy, filtered by sha, fallback to the
# newest when no gate run matches, and fallback to the newest when there is no deploy.yml at all.
# deploy.yml is read from origin/main (26 Sep 2026: land no longer checks out main in her tree), so
# the fixture repo is a real git repo and each deploy.yml variant is committed and pointed at by
# refs/remotes/origin/main — and a deploy.yml sitting UNCOMMITTED in the working tree is ignored.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- pick_run begin/,/^# --- pick_run end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the pick_run block"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repo/.github/workflows"
# Newest first, as gh prints it. The Playwright run is listed AFTER (newer than) the gate run.
cat > "$WORK/runs.json" <<'JSON'
[
 {"databaseId": 400, "headSha": "bbb", "event": "workflow_run", "name": "Deploy"},
 {"databaseId": 301, "headSha": "bbb", "event": "push", "name": "Playwright"},
 {"databaseId": 300, "headSha": "bbb", "event": "push", "name": "CI"},
 {"databaseId": 201, "headSha": "aaa", "event": "push", "name": "Playwright"},
 {"databaseId": 200, "headSha": "aaa", "event": "push", "name": "CI"},
 {"databaseId": 100, "headSha": "ccc", "event": "push", "name": "Nightly"}
]
JSON
# fake gh: only `gh run list ... -q <filter>` is answered, with the fixture through jq.
{
  echo '#!/bin/bash'
  echo 'q=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && q="$2"; shift; done'
  echo "jq -r \"\$q\" '$WORK/runs.json'"
} > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
fails=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 → '$3'"; else echo "  FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi
}
run_case() { # jq filter
  ( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" && eval "$BLOCK" && pick_run "$1" )
}
git -C "$WORK/repo" init -q
publish() { # commit the working tree and make it origin/main
  git -C "$WORK/repo" add -A .github && git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture \
    && git -C "$WORK/repo" update-ref refs/remotes/origin/main HEAD
}
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: [CI]\n' > "$WORK/repo/.github/workflows/deploy.yml"
publish
check "gate run for sha bbb, not Playwright (listed newer) or Deploy" 300 "$(run_case '.headSha == "bbb" and .event == "push"')"
check "gate run for sha aaa" 200 "$(run_case '.headSha == "aaa" and .event == "push"')"
check "newest gate run when unfiltered" 300 "$(run_case 'true')"
check "sha with no gate run falls back to its newest run" 100 "$(run_case '.headSha == "ccc"')"
check "sha with no run at all is empty" "" "$(run_case '.headSha == "zzz"')"
rm "$WORK/repo/.github/workflows/deploy.yml"
publish
check "no deploy.yml: the newest matching run, as before" 301 "$(run_case '.headSha == "bbb" and .event == "push"')"
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: [CI]\n' > "$WORK/repo/.github/workflows/deploy.yml"
check "an UNCOMMITTED deploy.yml in the working tree is ignored (origin/main has none)" 301 "$(run_case '.headSha == "bbb" and .event == "push"')"
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: ["CI"]\n' > "$WORK/repo/.github/workflows/deploy.yml"
publish
check "a quoted workflow name is read the same" 300 "$(run_case '.headSha == "bbb" and .event == "push"')"
# 26 Sep 2026: a route that names its full e2e workflow (E2E_WF) never watches that run as "main":
# no deploy.yml, the e2e listed newer, and the fast check is still the run picked.
rm "$WORK/repo/.github/workflows/deploy.yml"
publish
run_case_e2e() { ( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" && export E2E_WF=Playwright && eval "$BLOCK" && pick_run "$1" ); }
check "E2E_WF set, no deploy.yml: the fast check, never the e2e run" 300 "$(run_case_e2e '.headSha == "bbb" and .event == "push"')"
check "E2E_WF set, a sha with only an e2e run: empty (nothing to judge the merge on)" "" "$(run_case_e2e '.headSha == "ccc" and .name == "Playwright"')"
# 2 Oct 2026, local-guides-citation-velocity #163/#166: no deploy.yml, and the newest run on main
# was a 20-second "CI Health Red Recovery" — land watched it and called main green while Validate
# Repo on the merge commit was cancelled. The workflow that ran the PR's own checks (PR_WF) is the
# gate when deploy.yml names none with a run on the list.
run_case_pr() { ( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" && export PR_WF="$1" && eval "$BLOCK" && pick_run "$2" ); }
check "no deploy.yml, PR judged by CI: CI's run for the sha, not the newer Playwright run" 300 "$(run_case_pr CI '.headSha == "bbb" and .event == "push"')"
check "no deploy.yml, PR judged by CI, unfiltered: CI's newest run, not the Deploy run listed first" 300 "$(run_case_pr CI 'true')"
check "PR_WF names a workflow with no run on the list: the newest match, as before" 400 "$(run_case_pr 'No Such Workflow' 'true')"
check "PR_WF empty (unreadable): the newest match, as before" 400 "$(run_case_pr '' 'true')"
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: [CI]\n' > "$WORK/repo/.github/workflows/deploy.yml"
publish
check "deploy.yml's gate still wins over the PR's workflow" 300 "$(run_case_pr Playwright '.headSha == "bbb" and .event == "push"')"
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: [Gone]\n' > "$WORK/repo/.github/workflows/deploy.yml"
publish
check "deploy.yml names a gate with no run on the list: the PR's workflow, before the newest" 301 "$(run_case_pr Playwright '.headSha == "bbb" and .event == "push"')"
rm "$WORK/repo/.github/workflows/deploy.yml"
publish
# The exact shape of that main, newest first.
cat > "$WORK/runs.json" <<'JSON'
[
 {"databaseId": 903, "headSha": "old", "event": "workflow_run", "name": "CI Health Red Recovery"},
 {"databaseId": 902, "headSha": "old", "event": "workflow_run", "name": "Deploy Distribution"},
 {"databaseId": 901, "headSha": "new", "event": "push", "name": "Velocity Content Release"},
 {"databaseId": 900, "headSha": "new", "event": "push", "name": "Validate Repo"},
 {"databaseId": 800, "headSha": "old", "event": "workflow_dispatch", "name": "Validate Repo"}
]
JSON
check "the 2 Oct shape: Validate Repo's newest run on main, not the 20-second recovery run" 900 "$(run_case_pr 'Validate Repo' 'true')"
check "the 2 Oct shape, already merged: Validate Repo on the merge commit, not the release lane's run" 900 "$(run_case_pr 'Validate Repo' '.headSha == "new" and .event == "push"')"
check "the 2 Oct shape without the PR's workflow is the defect: the recovery run (negative proof)" 903 "$(run_case 'true')"
[ "$fails" -eq 0 ] || { echo "test-land-pick-run: $fails failure(s)"; exit 1; }
echo "test-land-pick-run: 19 cases passed — land watches the gate run on a two-workflow main, never the e2e run, and the PR's own workflow when deploy.yml names no gate"
