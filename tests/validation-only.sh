#!/bin/bash
# Assert this repository's CI stays a VALIDATION lane and never becomes a
# deployment one.
#
# WHY THIS EXISTS
# On 2026-09-03 west-peek-os was found with no CI at all, and the trap in fixing
# it was restoring the deleted workflow as-is: it auto-deployed with a bare
# `wrangler deploy` on every push, which that repository's own documentation
# warned against and which had been switched off deliberately days earlier. A
# production credential sitting in CI is real blast radius.
#
# This repository is the scheduled machinery for one Mac. Its README states that
# it holds no credentials and that every credential reference is a path, never a
# value. Nothing enforced that. This does, structurally, by reading the workflow
# files rather than asserting a sentence about them.
#
# RULE 0: examining zero workflow files is NOT a pass.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WF_DIR="$ROOT/.github/workflows"

[ -d "$WF_DIR" ] || { echo "NAMED STOP [NO_WORKFLOW_DIR] $WF_DIR does not exist."; exit 3; }

examined=0
failed=0

# A deploy verb in a workflow is the west-peek-os shape. `secrets.` is how a
# credential reaches a runner. Neither belongs in this repository at all.
FORBIDDEN='secrets[.]|\bwrangler\b|\bdeploy\b|\bpublish\b|AWS_ACCESS|GH_TOKEN|API_KEY|ANTHROPIC_API'

while IFS= read -r wf; do
  [ -z "$wf" ] && continue
  examined=$((examined + 1))
  # Comment lines are excluded: a YAML comment cannot deploy anything, and this
  # file's own explanation of what it forbids would otherwise trip it.
  hits="$(grep -nE "$FORBIDDEN" "$wf" | grep -vE '^[0-9]+:[[:space:]]*#')"
  if [ -n "$hits" ]; then
    echo "  x $wf introduces deployment or credential surface:"
    printf '%s\n' "$hits" | sed 's/^/        /'
    failed=$((failed + 1))
  else
    echo "  o $wf is validation-only: no credential reference, no deploy step"
  fi
done < <(find "$WF_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)

if [ "$examined" -eq 0 ]; then
  echo "RULE 0 [EXAMINED_NOTHING] no workflow file was found under $WF_DIR, so this check"
  echo "  examined zero items. A repository with a workflow directory and no workflows in it"
  echo "  is the silence defect, not a pass."
  exit 2
fi

echo "=== examined $examined workflow file(s) ==="
if [ "$failed" -gt 0 ]; then
  echo "DEPLOYMENT OR CREDENTIAL SURFACE DETECTED in $failed workflow file(s)."
  exit 1
fi
echo "CI here is validation-only, as this repository's README promises."
exit 0
