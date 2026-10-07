#!/bin/bash
# land must watch the run for ITS OWN merge commit, also on a fresh merge.
#
# 7 Oct 2026 (sprylabs-hpc-site #119): the fresh-merge path picked main's newest run 12 s after
# merging, before the merge commit's run existed, watched a July run to "failure" and stopped the
# deploy of a green main. This pins the fix: the merge sha is read back for a fresh merge, the
# sha-filtered pick is retried until a deadline, and the unfiltered pick is only the fallback.
set -euo pipefail
LAND="$(cd "$(dirname "$0")" && pwd)/../land"
BLOCK="$(sed -n '/^# --- pick_run end/,/watching run \$RID/p' "$LAND" | grep -v "^[[:space:]]*#")"
fails=0
need() { grep -qF -- "$2" <<<"$BLOCK" && echo "  ok   $1" || { echo "  FAIL $1"; fails=$((fails+1)); }; }
need "fresh merge reads its merge sha back" "--json mergeCommit -q '.mergeCommit.oid // empty'"
need "sha-filtered pick is retried until a deadline" 'APPEAR_DEADLINE'
need "sha-filtered pick" 'pick_run ".headSha == \"$MERGESHA\" and .event == \"push\""'
first_sha="$(grep -n 'pick_run ".headSha == ' <<<"$BLOCK" | head -1 | cut -d: -f1)"
first_any="$(grep -n 'pick_run "true"' <<<"$BLOCK" | head -1 | cut -d: -f1)"
if [ -n "$first_sha" ] && [ -n "$first_any" ] && [ "$first_sha" -lt "$first_any" ]; then echo "  ok   unfiltered pick only after the sha pick"; else echo "  FAIL unfiltered pick comes before (or without) the sha pick"; fails=$((fails+1)); fi
if grep -q 'if \[ -n "\$ALREADY_MERGED" \] && \[ -n "\$MERGESHA" \]; then' <<<"$BLOCK"; then echo "  FAIL the sha pick is limited to already-merged PRs again"; fails=$((fails+1)); fi
[ "$fails" -eq 0 ] && echo "PASS test-land-merge-run" || { echo "FAIL test-land-merge-run ($fails)"; exit 1; }
