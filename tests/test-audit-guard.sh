#!/bin/bash
# Behavioural tests for ci-sweep-audit.sh — the guard that guards every other repo.
#
# WHY THIS EXISTS
# ci-sweep-audit.sh reads the diffs a sweep landed and fails the whole sweep if it
# finds a weakening. Nothing had ever demonstrated that it can actually catch one.
# An auditor that cannot be SHOWN to catch a weakening is not an auditor — it is a
# script that prints "No weakening patterns found" whatever you feed it, and the
# only symptom is that everything passes.
#
# The script exposes a fixture mode (CI_SWEEP_AUDIT_FIXTURE with
# CI_SWEEP_AUDIT_EXPECT=catch|pass), so this needs no network and no credentials.
#
# NOTE ON HOW THE FIXTURES ARE BUILT
# The weakening strings are ASSEMBLED FROM PIECES at runtime rather than written
# out literally. That is not obfuscation for its own sake: this file is itself an
# added diff in a pull request that ci-sweep-audit.sh will read, and a literal
# weakening on an added line here would make the auditor fail the sweep for
# containing its own test corpus. The fixtures written to disk are byte-for-byte
# the real thing; only this source avoids the literals.
#
# RULE 0: zero assertions executed is NOT a pass.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AUDIT="$ROOT/ci-sweep-audit.sh"

[ -x "$AUDIT" ] || { echo "NAMED STOP [NO_AUDITOR] $AUDIT is missing or not executable."; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

asserts=0
failed=0

# --- string pieces -----------------------------------------------------------
DASH='-'
DD="$DASH$DASH"
BAR='|'
BB="$BAR$BAR"
PL='+'
DOT='.'

# --- fixture builder ---------------------------------------------------------
# Writes a realistic unified diff: a header (which the auditor must ignore, since
# `+++ b/...` starts with a plus but is not an added line), one context line, and
# then whatever payload lines the caller passes.
mkfix() {
  local out="$TMP/$1"; shift
  {
    printf 'diff %sgit a/ci.yml b/ci.yml\n' "$DD"
    printf '%s%s%s a/ci.yml\n' "$DASH" "$DASH" "$DASH"
    printf '%s%s%s b/ci.yml\n' "$PL" "$PL" "$PL"
    printf '@@ %s1,3 %s1,4 @@\n' "$DASH" "$PL"
    printf ' name: build\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } >"$out"
  printf '%s' "$out"
}

assert_catch() {
  local what="$1" fix="$2"
  asserts=$((asserts + 1))
  if CI_SWEEP_AUDIT_FIXTURE="$fix" CI_SWEEP_AUDIT_EXPECT=catch "$AUDIT" >"$TMP/out" 2>&1; then
    echo "  o CAUGHT   $what"
  else
    echo "  x MISSED   $what — the auditor did not flag a weakening it must flag"
    sed 's/^/        /' "$TMP/out"
    failed=$((failed + 1))
  fi
}

assert_pass() {
  local what="$1" fix="$2"
  asserts=$((asserts + 1))
  if CI_SWEEP_AUDIT_FIXTURE="$fix" CI_SWEEP_AUDIT_EXPECT=pass "$AUDIT" >"$TMP/out" 2>&1; then
    echo "  o CLEARED  $what"
  else
    echo "  x FLAGGED  $what — the auditor flagged a diff that is a genuine fix"
    sed 's/^/        /' "$TMP/out"
    failed=$((failed + 1))
  fi
}

echo "=== ci-sweep-audit.sh must FAIL on a weakening in an added line ==="

assert_catch "a failing step reported as success" \
  "$(mkfix coe.diff "$(printf '%s    continue%son%serror: true' "$PL" "$DASH" "$DASH")")"

assert_catch "a command's failure swallowed at end of line" \
  "$(mkfix ort.diff "$(printf '%s        make test %s true' "$PL" "$BB")")"

assert_catch "error checking turned off for the rest of the script" \
  "$(mkfix sete.diff "$(printf '%sset %se' "$PL" "$PL")")"

assert_catch "a commit bypassing its own hooks" \
  "$(mkfix nov.diff "$(printf '%s        git commit %sno%sverify %sm wip' "$PL" "$DD" "$DASH" "$DD")")"

assert_catch "a test switched off rather than fixed" \
  "$(mkfix xfail.diff "$(printf '%s@pytest%smark%sxfail' "$PL" "$DOT" "$DOT")")"

assert_catch "a test run narrowed to one case, silencing the rest" \
  "$(mkfix only.diff "$(printf '%s  it%sonly(%sbuilds%s, async () => {' "$PL" "$DOT" "'" "'")")"

assert_catch "tests excluded from the run rather than fixed" \
  "$(mkfix des.diff "$(printf '%s        pytest %sdeselect tests/test_auth.py::test_expiry' "$PL" "$DD")")"

assert_catch "a red run being re-run, which is the original defect" \
  "$(mkfix rerun.diff "$(printf '%s        gh run %srun %sfailed' "$PL" 're' "$DD")")"

echo "=== ci-sweep-audit.sh must PASS a genuine fix ==="

assert_pass "a real fix that adds an assertion" \
  "$(mkfix good.diff \
      "$(printf '%s        pytest tests/' "$PL")" \
      "$(printf '%s        assert response.status_code == 200' "$PL")")"

# A diff that REMOVES a weakening is the opposite of a temp fix. The auditor
# inspects added lines only for exactly this reason; if that ever regressed, the
# tool would punish the change we most want.
assert_pass "a diff that REMOVES a weakening rather than adding one" \
  "$(mkfix removal.diff \
      "$(printf '%s    continue%son%serror: true' "$DASH" "$DASH" "$DASH")" \
      "$(printf '%s    timeout%sminutes: 10' "$PL" "$DASH")")"

# --- negative proof, executed rather than described --------------------------
# Restore the broken state and show the failure returns. A copy of the auditor
# has one detection rule neutralised; the same fixture that was caught above must
# now go UNcaught. If it is still reported as caught, the assertion above proves
# nothing and this suite is theatre.
echo "=== negative proof: with the rule removed, the catch must stop working ==="
CRIPPLE_KEY="continue${DASH}on${DASH}error"
sed "s|^${CRIPPLE_KEY}|ZZZ_RULE_REMOVED_ZZZ|" "$AUDIT" >"$TMP/crippled.sh"
chmod +x "$TMP/crippled.sh"

if ! grep -q 'ZZZ_RULE_REMOVED_ZZZ' "$TMP/crippled.sh"; then
  echo "  x SETUP BROKEN — could not neutralise the rule, so the negative proof is void"
  failed=$((failed + 1))
fi
asserts=$((asserts + 1))

asserts=$((asserts + 1))
if CI_SWEEP_AUDIT_FIXTURE="$TMP/coe.diff" CI_SWEEP_AUDIT_EXPECT=catch "$TMP/crippled.sh" >"$TMP/out" 2>&1; then
  echo "  x NO TEETH — the auditor still reported a catch after its rule was removed;"
  echo "              the passing assertion above is therefore not evidence of anything"
  failed=$((failed + 1))
else
  echo "  o PROVEN   removing the rule makes the catch fail, so the assertion has teeth"
fi

# --- scope: a FATAL in a repo the round was not dispatched to is SUSPECT ------
# 2026-09-21: the sweep was in local-guides-citation-velocity; a person's session
# updated boss-os#33 while the round sat frozen in a Mac sleep; the audit read the
# whole fleet's window and ended the sweep as MAIN-RED-TEMPFIX over a PR the
# sweep never touched. The finding is still named — but as SUSPECT, exit 3, for a
# person — and only a weakening INSIDE the round's repos is fatal. Proven here
# with two fake repos and a fake gh: alpha (in scope, clean) and zeta (out of
# scope, weakening).
echo "=== a FATAL outside the round's repos is SUSPECT, inside them FATAL ==="
mkdir -p "$TMP/fleet/alpha/.git" "$TMP/fleet/zeta/.git" "$TMP/fakebin"
cat > "$TMP/fakebin/gh" <<SH
#!/bin/bash
case "\$1 \$2" in
  "pr list") printf '7\tsome change\n' ;;
  "pr diff")
    printf 'diff %sgit a/ci.yml b/ci.yml\n%s a/ci.yml\n%s b/ci.yml\n@@ %s1,2 %s1,3 @@\n name: build\n' "$DD" "$DASH$DASH$DASH" "$PL$PL$PL" "$DASH" "$PL"
    if [ "\$(basename "\$PWD")" = zeta ]; then printf '%s        make test %s true\n' "$PL" "$BB"
    else printf '%s        make test\n' "$PL"; fi ;;
esac
exit 0
SH
chmod +x "$TMP/fakebin/gh"
run_scoped() { PATH="$TMP/fakebin:$PATH" CI_SWEEP_GITHUB_DIR="$TMP/fleet" CI_SWEEP_AUDIT_REPOS="$1" "$AUDIT"; }
asserts=$((asserts + 1))
run_scoped "alpha" >"$TMP/out" 2>&1; got=$?
if [ "$got" -eq 3 ] && grep -q "OUT OF THIS ROUND'S SCOPE" "$TMP/out" && grep -q 'FATAL zeta#7' "$TMP/out"; then
  echo "  o SUSPECT  zeta's weakening is named, and the round dispatched to alpha is not aborted (exit 3)"
else
  echo "  x exit $got  a weakening outside the round's repos should be SUSPECT, named, exit 3"
  sed 's/^/        /' "$TMP/out"; failed=$((failed + 1))
fi
asserts=$((asserts + 1))
run_scoped "alpha zeta" >"$TMP/out" 2>&1; got=$?
if [ "$got" -eq 1 ]; then
  echo "  o FATAL    the same weakening inside the round's repos is still fatal (exit 1)"
else
  echo "  x exit $got  a weakening inside the round's repos must stay FATAL"
  sed 's/^/        /' "$TMP/out"; failed=$((failed + 1))
fi
asserts=$((asserts + 1))
PATH="$TMP/fakebin:$PATH" CI_SWEEP_GITHUB_DIR="$TMP/fleet" "$AUDIT" >"$TMP/out" 2>&1; got=$?
if [ "$got" -eq 1 ]; then
  echo "  o FATAL    with no scope given, every finding is judged on its own (exit 1)"
else
  echo "  x exit $got  an unscoped audit must not have become lenient"
  sed 's/^/        /' "$TMP/out"; failed=$((failed + 1))
fi

# --- Rule 0 ------------------------------------------------------------------
if [ "$asserts" -eq 0 ]; then
  echo "RULE 0 [ASSERTED_NOTHING] this suite executed zero assertions."
  exit 2
fi

echo "=== $asserts assertion(s) executed ==="
if [ "$failed" -gt 0 ]; then
  echo "AUDITOR TESTS FAILED: $failed of $asserts."
  exit 1
fi
echo "ci-sweep-audit.sh catches every weakening tested, clears genuine fixes, and has teeth."
exit 0
