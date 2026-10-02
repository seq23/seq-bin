#!/bin/bash
# land must decide "large change" from measured numbers, never from a feeling.
#
# On demand only, and after a large change (owner, 2 Oct 2026): the e2e workflows run on
# `workflow_dispatch` alone, so after a merge the only thing that ever runs them is `land` — and it
# runs them when the PR is LARGE. "Large" is defined in land's `large` block (pure, no gh) and this
# evals that block verbatim and checks every rule from both sides: each threshold at its edge, each
# path trigger, the fail-closed case for an unreadable size, and the env overrides. Then it breaks
# the lines rule and proves this test would catch it.
#
# SMALL CHANGES SHIP ON THE FAST CHECK (owner, 2 Oct 2026) — so "small" must be true of EVERYTHING
# production has not seen, not only of the PR in hand: a large change whose suite was never run
# (dispatch failed, cancelled at its ceiling, merged without land) must not ride out on the small
# change behind it. land's `range` block walks main between production's recorded sha and the sha
# about to ship and judges each commit with the same large_reason. Evaluated verbatim here against
# a real git history: every commit small, one large in the middle, the large one already in
# production, a merge commit, an unreadable or foreign production sha (fail closed), the cap — and
# a walk that looks only at the newest commit is proven to fail.
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

echo "unshipped_large_reason PRODUCTION_STATE SHA — every commit production has not seen"
RANGE="$(sed -n '/^# --- range begin/,/^# --- range end/p' "$LAND")"
[ -n "$RANGE" ] || { echo "FAIL: land no longer carries the range block"; exit 1; }
eval "$RANGE"
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$R"
commit() { # subject file lines -> prints the sha
  mkdir -p "$R/$(dirname "$2")"; seq 1 "$3" | sed "s/^/$1 /" >> "$R/$2"
  git -C "$R" add -A >/dev/null; git -C "$R" commit -qm "$1"; git -C "$R" rev-parse HEAD
}
C0="$(commit "base" README.md 5)"
C1="$(commit "docs: a README line" README.md 3)"
C2="$(commit "worker: ten lines" worker/sync.ts 10)"
C3="$(commit "big unproven change" worker/big.ts 250)"
C4="$(commit "ci: a comment" .github/workflows/ci.yml 4)"
C5="$(commit "schema: one column" migrations/0007_col.sql 2)"
C6="$(commit "docs: after the migration" README.md 1)"
git -C "$R" checkout -q -b side "$C0"; SIDE="$(commit "side branch work" side.txt 3)"
git -C "$R" checkout -q -b feature "$C2"; commit "feature work" worker/feature.ts 260 >/dev/null
git -C "$R" checkout -q -b merged "$C2"; git -C "$R" merge -q --no-ff -m "Merge feature (not squashed)" feature; MERGE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
range() { ( cd "$R" && unshipped_large_reason "$1" "$2" 2>/dev/null ) || echo SMALL; }
check "production unrecorded: nothing to judge, the PR alone decides" SMALL "$(range unrecorded "$C4")"
check "production unreadable: large, fail closed"              "what production runs could not be read" "$(range unreadable "$C4")"
check "production already runs the sha: nothing to judge"      SMALL "$(range "$C2" "$C2")"
check "two small commits past production: small"               SMALL "$(range "$C0" "$C2")"
check "…and it says how many it judged"                        "judged all 2 change(s) main carries past production ${C0:0:7}: none is large" "$( (cd "$R" && unshipped_large_reason "$C0" "$C2" 2>&1) || true)"
check "a large commit in the middle is found, by sha and subject" "main carries ${C3:0:7} (big unproven change) past production ${C0:0:7}, large and not yet proven: 250 lines changed (+250/-0) ≥ 200" "$(range "$C0" "$C4")"
check "…even when the commit being shipped is tiny"            "large and not yet proven" "$(range "$C2" "$C4")"
check "the large commit already IN production is not re-judged" SMALL "$(range "$C3" "$C4")"
check "a migration production has not seen is large at any size" "main carries ${C5:0:7} (schema: one column) past production ${C4:0:7}, large and not yet proven: touches the schema" "$(range "$C4" "$C6")"
check "a merge commit is judged by what it brought to main"    "main carries ${MERGE:0:7} (Merge feature (not squashed)) past production ${C2:0:7}, large and not yet proven: 260 lines" "$(range "$C2" "$MERGE")"
check "production on another branch is not an ancestor: large, fail closed" "production's recorded sha ${SIDE:0:7} is not an ancestor of ${C4:0:7}" "$(range "$SIDE" "$C4")"
check "a production sha this checkout does not have: large, fail closed" "is not an ancestor" "$(range dddddddddddddddddddddddddddddddddddddddd "$C2")"
# shellcheck disable=SC2034  # LAND_RANGE_MAX is read by the eval'd range block
check "more commits than LAND_RANGE_MAX: large"                "2 commits on main since production ${C0:0:7} (more than 1) — treated as large" "$( (LAND_RANGE_MAX=1; range "$C0" "$C2") )"
check "the thresholds are land's own (LAND_LARGE_LINES=5 here)" "10 lines changed (+10/-0) ≥ 5" "$( (LAND_LARGE_LINES=5; range "$C1" "$C2") )"
# NEGATIVE PROOF: a walk that judges only the newest commit lets the large one ride out.
BROKENR="$(printf '%s\n' "$RANGE" | sed 's/for c in \$(git rev-list --first-parent "\$prod\.\.\$sha"); do/for c in $(git rev-list --first-parent -1 "$sha"); do/')"
[ "$BROKENR" != "$RANGE" ] || { echo "FAIL: could not construct the broken range walk for the negative proof"; exit 1; }
got="$( (eval "$BROKENR"; range "$C0" "$C4") )"
n=$((n+1))
if [ "$got" = SMALL ]; then echo "  ok   negative proof: a walk that reads only the newest commit calls a range holding a 250-line change small ('$got') and this test would catch it"
else echo "  FAIL negative proof (range) did not exercise the broken walk: got '$got'"; fails=$((fails+1)); fi

# NEGATIVE PROOF: a block that never finds a change large must fail this test.
BROKEN="$(printf '%s\n' "$BLOCK" | sed 's/\[ "\$lines" -ge "\$LAND_LARGE_LINES" \]/[ "$lines" -ge 999999999 ]/')"
[ "$BROKEN" != "$BLOCK" ] || { echo "FAIL: could not construct the broken block for the negative proof"; exit 1; }
got="$( (eval "$BROKEN"; reason 500 500 1 worker/x.ts) )"
n=$((n+1))
if [ "$got" = SMALL ]; then echo "  ok   negative proof: the broken block calls a 1000-line change small ('$got') and this test would catch it"
else echo "  FAIL negative proof did not exercise the broken rule: got '$got'"; fails=$((fails+1)); fi

[ "$n" -ge 40 ] || { echo "FAIL: examined only $n cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-large: $fails failure(s)"; exit 1; }
echo "test-land-large: $n cases passed — large is measured (≥ $LAND_LARGE_LINES lines, ≥ $LAND_LARGE_FILES files, a schema/e2e/Playwright change, or a UI surface at ≥ $LAND_LARGE_UI_LINES lines), unreadable is large, small stays small, and every commit production has not seen is judged by the same rule"
