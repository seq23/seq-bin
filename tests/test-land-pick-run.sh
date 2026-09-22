#!/bin/bash
# land must watch the GATE run on main, not whichever run GitHub listed last.
#
# On 21 Sep 2026 west-peek-os moved its Playwright journeys into their own workflow, so one push
# to main starts two runs. `land` used to take `[0]` of `gh run list` — with two runs that is a
# coin flip, and the loser is a 20-minute journey suite the Deploy does not wait for. This evals
# the `pick_run` block out of `land` verbatim, against a fake `gh` that returns a fixed list, and
# checks every branch: gate preferred over Playwright and Deploy, filtered by sha, fallback to the
# newest when no gate run matches, and fallback to the newest when there is no deploy.yml at all.
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
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: [CI]\n' > "$WORK/repo/.github/workflows/deploy.yml"
check "gate run for sha bbb, not Playwright (listed newer) or Deploy" 300 "$(run_case '.headSha == "bbb" and .event == "push"')"
check "gate run for sha aaa" 200 "$(run_case '.headSha == "aaa" and .event == "push"')"
check "newest gate run when unfiltered" 300 "$(run_case 'true')"
check "sha with no gate run falls back to its newest run" 100 "$(run_case '.headSha == "ccc"')"
check "sha with no run at all is empty" "" "$(run_case '.headSha == "zzz"')"
rm "$WORK/repo/.github/workflows/deploy.yml"
check "no deploy.yml: the newest matching run, as before" 301 "$(run_case '.headSha == "bbb" and .event == "push"')"
printf 'name: Deploy\non:\n  workflow_run:\n    workflows: ["CI"]\n' > "$WORK/repo/.github/workflows/deploy.yml"
check "a quoted workflow name is read the same" 300 "$(run_case '.headSha == "bbb" and .event == "push"')"
[ "$fails" -eq 0 ] || { echo "test-land-pick-run: $fails failure(s)"; exit 1; }
echo "test-land-pick-run: 7 cases passed — land watches the gate run on a two-workflow main"
