#!/bin/bash
# Prove the lint hard-fails when it examines ZERO items.
#
# WHY THIS EXISTS
# Five of eight validators in west-peek-os passed while examining nothing. A loop
# over an empty list exits 0 and looks identical to a clean run, which is the
# quietest way for a check to be worthless. This points lint-shell.sh at an empty
# directory and requires a non-zero exit, and it pairs that with a positive
# control so the suite cannot pass by the lint being broken in both directions.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LINT="$ROOT/tests/lint-shell.sh"

[ -x "$LINT" ] || { echo "NAMED STOP [NO_LINT] $LINT is missing or not executable."; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

asserts=0
failed=0

# --- empty directory must NOT pass -------------------------------------------
mkdir -p "$TMP/empty"
asserts=$((asserts + 1))
"$LINT" "$TMP/empty" >"$TMP/out" 2>&1
got=$?
if [ "$got" -eq 0 ]; then
  echo "  x the lint PASSED while examining zero scripts — this is the defect itself"
  sed 's/^/        /' "$TMP/out"
  failed=$((failed + 1))
elif grep -q 'LINTED_NOTHING' "$TMP/out"; then
  echo "  o exit $got  an empty directory is a named Rule 0 failure, not a clean lint"
else
  echo "  x exit $got  non-zero, but without the named LINTED_NOTHING reason"
  sed 's/^/        /' "$TMP/out"
  failed=$((failed + 1))
fi

# --- positive control: a directory with a good script must pass --------------
# Without this, a lint that failed unconditionally would satisfy the check above.
mkdir -p "$TMP/good"
printf '#!/bin/bash\nset -euo pipefail\necho hello\n' >"$TMP/good/ok.sh"
asserts=$((asserts + 1))
if "$LINT" "$TMP/good" >"$TMP/out" 2>&1; then
  echo "  o exit 0  a directory with one clean script passes"
else
  echo "  x the lint failed on a directory containing one clean script"
  sed 's/^/        /' "$TMP/out"
  failed=$((failed + 1))
fi

# --- negative control: a directory with a broken script must fail ------------
mkdir -p "$TMP/bad"
printf '#!/bin/bash\nif [ 1 -eq 1 ]; then\n  echo unterminated\n' >"$TMP/bad/broken.sh"
asserts=$((asserts + 1))
if "$LINT" "$TMP/bad" >"$TMP/out" 2>&1; then
  echo "  x the lint PASSED a script that does not parse"
  failed=$((failed + 1))
else
  echo "  o exit non-zero  a script that does not parse is caught"
fi

# --- the validation-only guard: Rule 0 and teeth -----------------------------
GUARD="$ROOT/tests/validation-only.sh"
[ -x "$GUARD" ] || { echo "NAMED STOP [NO_GUARD] $GUARD is missing or not executable."; exit 3; }

mkdir -p "$TMP/wf-empty/.github/workflows"
asserts=$((asserts + 1))
"$GUARD" "$TMP/wf-empty" >"$TMP/out" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -q 'EXAMINED_NOTHING' "$TMP/out"; then
  echo "  o exit $got  an empty workflows directory is a named Rule 0 failure"
else
  echo "  x exit $got  an empty workflows directory did not hard-fail with a named reason"
  sed 's/^/        /' "$TMP/out"
  failed=$((failed + 1))
fi

# Teeth: a workflow that pulls a credential onto the runner and deploys must be
# rejected. This is the west-peek-os shape the guard exists to prevent.
mkdir -p "$TMP/wf-bad/.github/workflows"
{
  printf 'name: bad\n'
  printf 'jobs:\n'
  printf '  go:\n'
  printf '    steps:\n'
  printf '      - run: npx wrangler deploy\n'
  printf '        env:\n'
  printf '          TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}\n'
} >"$TMP/wf-bad/.github/workflows/deploy.yml"
asserts=$((asserts + 1))
if "$GUARD" "$TMP/wf-bad" >"$TMP/out" 2>&1; then
  echo "  x NO TEETH — the guard passed a workflow that deploys with a production token"
  failed=$((failed + 1))
else
  echo "  o exit non-zero  a deploying, credential-carrying workflow is rejected"
fi

if [ "$asserts" -eq 0 ]; then
  echo "RULE 0 [ASSERTED_NOTHING] this suite executed zero assertions."
  exit 2
fi

echo "=== $asserts assertion(s) executed ==="
if [ "$failed" -gt 0 ]; then
  echo "RULE 0 TESTS FAILED: $failed of $asserts."
  exit 1
fi
echo "The lint hard-fails on zero items, passes a clean script, and catches a broken one."
exit 0
