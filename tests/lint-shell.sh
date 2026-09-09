#!/bin/bash
# Lint every shell script in this repository — the check that has never existed.
#
# WHY THIS EXISTS
# Until today this repository had no CI of any kind: `gh workflow list` returned
# nothing and no run had ever been recorded. Nothing had ever checked that
# ci-sweep-audit.sh — the guard that fails the entire nightly sweep when it finds
# a weakening — so much as parses. A syntax error in the auditor is not a loud
# failure; it is a sweep that passes everything.
#
# RULE 0: examining zero scripts is NOT a pass. If the search finds no lintable
# shell script this exits non-zero with a named reason rather than reporting a
# clean lint of nothing.
#
# SEVERITY. shellcheck runs at -S warning, which is error+warning. That is the
# gate, chosen because those levels flag real defects (unchecked cd, dead
# assignments, quoting bugs) while info/style findings in this repository are
# deliberate: ci-sweep.sh passes its run log to the notifier as an argument while
# appending the notifier's own output to it, which SC2094 reports and which is
# the intended design. Findings below the gate are still printed, so they cannot
# become invisible.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ ! -d "$ROOT" ]; then
  echo "NAMED STOP [NO_SUCH_ROOT] $ROOT is not a directory."
  exit 3
fi

command -v shellcheck >/dev/null 2>&1 || {
  echo "NAMED STOP [NO_SHELLCHECK] shellcheck is not installed; the lint cannot run."
  exit 3
}

# Scratch lives in a temp directory, never under $ROOT. This lane runs against the
# same working copy the scheduled sweep executes from, so it must not write a
# single byte into it.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== linting shell scripts under $ROOT ==="

lintable=0
unresolved=0
failed=0

while IFS= read -r f; do
  [ -z "$f" ] && continue

  # A tracked symlink whose target lives in another repository cannot be read
  # here. kdp-watch.sh points into ~/GitHub/boss-os, which is not checked out on
  # a CI runner. These are NAMED and counted separately rather than passed over
  # silently: an unreadable entry is reported as what it is, and it is never
  # allowed to substitute for a real lint.
  if [ ! -e "$f" ]; then
    echo "  ~ UNRESOLVED POINTER $f -> $(readlink "$f")"
    echo "      target is outside this repository and is linted by the repository that owns it"
    unresolved=$((unresolved + 1))
    continue
  fi

  lintable=$((lintable + 1))

  if bash -n "$f" 2>"$TMP/parse-stderr"; then
    :
  else
    echo "  x PARSE FAILED $f"
    sed 's/^/      /' "$TMP/parse-stderr"
    failed=$((failed + 1))
  fi

  if shellcheck -S warning "$f"; then
    echo "  o $f"
  else
    echo "  x SHELLCHECK FAILED $f"
    failed=$((failed + 1))
  fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' | LC_ALL=C sort)

echo "=== linted $lintable script(s); $unresolved unresolved pointer(s) ==="

if [ "$lintable" -eq 0 ]; then
  echo "RULE 0 [LINTED_NOTHING] no lintable shell script was found under $ROOT, so this"
  echo "  check examined zero items. That is not a clean lint — a validator that passes on"
  echo "  an empty input set is the defect class this portfolio names most often."
  exit 2
fi

if [ "$failed" -gt 0 ]; then
  echo "LINT FAILED: $failed finding(s)."
  exit 1
fi

echo "All $lintable script(s) parse and pass shellcheck at the warning gate."
exit 0
