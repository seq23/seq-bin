#!/bin/bash
# land must decide "large change" from measured numbers, never from a feeling.
#
# On demand only, and after a large change (owner, 2 Oct 2026): the e2e workflows run on
# `workflow_dispatch` alone, so after a merge the only thing that ever runs them is `land` — and it
# runs them when the PR is LARGE. "Large" is defined in land's `large` block (pure, no gh) and this
# evals that block verbatim and checks every rule from both sides: each threshold at its edge, each
# path trigger, the fail-closed case for an unreadable size, and the env overrides. Then it breaks
# the lines rule and proves this test would catch it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- large begin/,/^# --- large end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the large block"; exit 1; }
eval "$BLOCK"
fails=0; n=0
# reason ADD DEL FILES paths... -> the printed reason, or "SMALL"
reason() { local add="$1" del="$2" files="$3"; shift 3; printf '%s\n' "$@" | large_reason "$add" "$del" "$files" || echo SMALL; }
check() { # label expected-substring actual
  n=$((n+1))
  case "$3" in *"$2"*) echo "  ok   $1 → '$3'" ;; *) echo "  FAIL $1: expected '$2' in '$3'"; fails=$((fails+1)) ;; esac
}

echo "defaults: $LAND_LARGE_LINES lines, $LAND_LARGE_FILES files, UI surface at $LAND_LARGE_UI_LINES lines"
check "a one-line README fix is small"                         SMALL "$(reason 1 0 1 README.md)"
check "199 lines in the worker is small"                       SMALL "$(reason 150 49 3 worker/domain/sync.ts worker/crons/daily.ts shared/types.ts)"
check "200 lines is large by lines (+/- shown)"                "200 lines changed (+150/-50) ≥ 200" "$(reason 150 50 3 worker/domain/sync.ts worker/crons/daily.ts shared/types.ts)"
check "deletions count: -200 alone is large"                   "200 lines changed (+0/-200)" "$(reason 0 200 1 worker/old.ts)"
check "7 files is small"                                       SMALL "$(reason 7 7 7 a.md b.md c.md d.md e.md f.md g.md)"
check "8 files is large by files"                              "8 files changed ≥ 8" "$(reason 8 8 8 a.md b.md c.md d.md e.md f.md g.md h.md)"
check "a migration is large at any size"                       "touches the schema or the browser-test contract (migrations/0042_posts.sql)" "$(reason 3 0 1 migrations/0042_posts.sql)"
check "an e2e spec is large at any size"                       "browser-test contract (tests/e2e/calendar.spec.ts)" "$(reason 1 1 1 tests/e2e/calendar.spec.ts)"
check "a top-level e2e/ spec (boss-os, west-peek-os) likewise" "browser-test contract (e2e/p25-journeys.spec.ts)" "$(reason 1 1 1 e2e/p25-journeys.spec.ts)"
check "a Playwright config likewise"                           "browser-test contract (playwright.open.config.ts)" "$(reason 1 1 1 playwright.open.config.ts)"
check "a 39-line UI change is small (a copy fix)"              SMALL "$(reason 30 9 2 app/pages/Calendar.tsx app/styles.css)"
check "a 40-line UI change is large by surface"                "2 UI-surface file(s) touched with 40 lines changed (≥ 40)" "$(reason 30 10 2 app/pages/Calendar.tsx app/styles.css)"
check "src/client (boss-os, west-peek-os) is a UI surface"     "1 UI-surface file(s)" "$(reason 40 0 1 src/client/home/Home.tsx)"
check "public/ (justbeingmercedes) is a UI surface"            "1 UI-surface file(s)" "$(reason 40 0 1 public/index.html)"
check "functions/ (Pages Functions) is a UI surface"           "1 UI-surface file(s)" "$(reason 40 0 1 functions/photos.js)"
check "worker/routes is a UI surface"                          "1 UI-surface file(s)" "$(reason 40 0 1 worker/routes/posts.ts)"
check "a 40-line worker-only change is small"                  SMALL "$(reason 40 0 1 worker/domain/sync.ts)"
check "a 40-line .html at the root (secondaries) is a surface" "1 UI-surface file(s)" "$(reason 40 0 1 index.html)"
check "no paths at all, small numbers: small"                  SMALL "$(reason 5 5 1)"
check "unreadable size is large, fail closed"                  "PR size unreadable (+?/-?, ? files) — treated as large, fail closed" "$(reason '?' '?' '?')"
check "an empty size is large, fail closed"                    "treated as large, fail closed" "$(printf '' | large_reason "" "" "" || echo SMALL)"

echo "env overrides"
check "LAND_LARGE_LINES=50 makes 60 lines large"   "60 lines changed (+60/-0) ≥ 50" "$( (LAND_LARGE_LINES=50; reason 60 0 1 worker/x.ts) )"
check "…and set in the environment before the block is read" "60 lines changed (+60/-0) ≥ 50" "$( (export LAND_LARGE_LINES=50; eval "$BLOCK"; reason 60 0 1 worker/x.ts) )"
check "LAND_LARGE_FILES=3 makes 3 files large"     "3 files changed ≥ 3" "$( (LAND_LARGE_FILES=3; reason 1 1 3 a.md b.md c.md) )"
check "LAND_LARGE_UI_LINES=10 makes a 10-line UI change large" "with 10 lines changed (≥ 10)" "$( (LAND_LARGE_UI_LINES=10; reason 10 0 1 app/App.tsx) )"

# NEGATIVE PROOF: a block that never finds a change large must fail this test.
BROKEN="$(printf '%s\n' "$BLOCK" | sed 's/\[ "\$lines" -ge "\$LAND_LARGE_LINES" \]/[ "$lines" -ge 999999999 ]/')"
[ "$BROKEN" != "$BLOCK" ] || { echo "FAIL: could not construct the broken block for the negative proof"; exit 1; }
got="$( (eval "$BROKEN"; reason 500 500 1 worker/x.ts) )"
n=$((n+1))
if [ "$got" = SMALL ]; then echo "  ok   negative proof: the broken block calls a 1000-line change small ('$got') and this test would catch it"
else echo "  FAIL negative proof did not exercise the broken rule: got '$got'"; fails=$((fails+1)); fi

[ "$n" -ge 25 ] || { echo "FAIL: examined only $n cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-large: $fails failure(s)"; exit 1; }
echo "test-land-large: $n cases passed — large is measured (≥ $LAND_LARGE_LINES lines, ≥ $LAND_LARGE_FILES files, a schema/e2e/Playwright change, or a UI surface at ≥ $LAND_LARGE_UI_LINES lines), unreadable is large, small stays small"
