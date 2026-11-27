#!/bin/bash
# land --check, the ONE template, and the reviewer list (her words 27 Nov 2026: "forms line in it s description is
# going to keep tripping you up ... give a root fix to this ---is there a template followed?" and "u need to come up
# with a set of final rules of what needs a reviewer and what doesnt"; "everything doesnt fucking neeed a reviewr").
#
# Drives the REAL land (`land --check 7`) in a real git checkout against a fake gh that logs every call, so:
#   - one run lists EVERYTHING a description lacks, each with the line to add, read from pr-body-template.md;
#   - land never asks for a line the template does not carry (and this test goes red when the template loses one);
#   - only her list waits on a reviewer: a declared class, a review-required label (now or ever), a change to
#     live-repos.json, anything unread. A repo not on live-repos.json is no class by that alone;
#   - a missing Review class line is read as none ONLY from paths that touch no class surface, never guessed;
#   - GitHub not answering is exit 75 "could not verify", never "has everything";
#   - --check writes nothing: no merge, comment, label or edit call, and no HANDOFF line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAND="${LAND_UNDER_TEST:-$HERE/land}"
[ -r "$LAND" ] || { echo "FAIL: no land at $LAND"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
export LAND_HANDOFF="$W/HANDOFF.md" BOSS_OS_REPO="$W/no-boss-os" LAND_RETRY_SECS=0 LAND_RATE_WAIT=1 LAND_TODAY=2026-11-27
export GIT_AUTHOR_NAME=builder GIT_AUTHOR_EMAIL=builder@example.test GIT_COMMITTER_NAME=builder GIT_COMMITTER_EMAIL=builder@example.test
F="$W/fake"; BIN="$W/bin"; mkdir -p "$F" "$BIN"; export FAKE_DIR="$F"
printf '## Today\n- nothing due\n' > "$LAND_HANDOFF"; cp "$LAND_HANDOFF" "$W/HANDOFF.before"
pass=0; failn=0
check() { local d="$1"; shift; if "$@"; then pass=$((pass + 1)); echo "  ok   $d"; else failn=$((failn + 1)); echo "  FAIL $d"; [ -z "${CHECK_TEST_SHOW:-}" ] || sed 's/^/    | /' <<<"rc $RC"$'\n'"$OUT" | cut -c1-400; fi; }

# --- the fake gh: every call is logged; only reads are answered ---
cat > "$BIN/gh" <<'SH'
#!/bin/bash
F="$FAKE_DIR"; echo "$*" >> "$F/calls"
mode() { cat "$F/$1" 2>/dev/null; }
down() { case "$(mode "$1")" in
  tls) echo "Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout" >&2; exit 1 ;;
  ratelimit) echo "HTTP 403: API rate limit exceeded for user ID 1." >&2; exit 1 ;;
  401) echo "HTTP 401: Requires authentication (https://api.github.com/graphql)" >&2; exit 1 ;;
  empty) exit 0 ;;
esac; }
case "$*" in
  "pr view "*)
    down outage
    lb="$(cat "$F/labels" 2>/dev/null || echo '[]')"   # "null" = labels absent from GitHub's answer (unread)
    jq -n --arg body "$(cat "$F/body" 2>/dev/null)" --arg head "$HEADSHA" --arg st "$(cat "$F/state" 2>/dev/null || echo OPEN)" \
      --arg base "$(cat "$F/base" 2>/dev/null || echo main)" --arg url "$(cat "$F/url" 2>/dev/null || echo https://github.com/o/newrepo/pull/7)" \
      --argjson fl "$(cat "$F/files" 2>/dev/null || echo '[{"path": "README.md"}]')" --argjson cm "$(cat "$F/comments" 2>/dev/null || echo '[]')" --argjson lb "$lb" \
      '{state: $st, baseRefName: $base, headRefOid: $head, files: $fl, body: $body, comments: $cm, author: {login: "builder-bot"},
        commits: [], url: $url, changedFiles: ($fl | length), additions: 3, deletions: 1} + (if $lb == null then {} else {labels: $lb} end)'; exit 0 ;;
  "api --paginate repos/"*"/issues/"*"/events"*) down events; cat "$F/label-events" 2>/dev/null || echo '[]'; exit 0 ;;
  "api rate_limit"*) echo $(( $(date +%s) + 3 )); exit 0 ;;   # the allowance comes back in 3 s: past LAND_RATE_WAIT=1
  "api repos/{owner}/{repo}/commits/"*"/check-suites"*) jq -rn '"2026-11-22T12:05:00Z" | fromdateiso8601'; exit 0 ;;
esac
echo "fake gh: unexpected $*" >&2; exit 1
SH
chmod +x "$BIN/gh"

# --- two checkouts whose origin reads as github.com/o/<repo>: neither repo is on live-repos.json, and land has no
# deploy route for either (a repo not yet launched). newrepo holds no data store; dbrepo has a migration on main. ---
mkrepo() { # $1 name  $2.. extra files on main
  local n="$1" f; shift
  git init -q --bare -b main "$W/github.com/o/$n.git"
  git init -q -b main "$W/$n" && git -C "$W/$n" remote add origin "$W/github.com/o/$n.git"
  mkdir -p "$W/$n/src/client" "$W/$n/src/emails"; echo "# $n" > "$W/$n/README.md"; printf 'function alpha() {\n  return 1;\n}\n' > "$W/$n/src/app.js"
  echo "export const Home = 1;" > "$W/$n/src/client/Home.tsx"; echo "<p>hello</p>" > "$W/$n/src/emails/hello.html"   # screens and an email already on main: nothing here is a first launch
  for f in "$@"; do mkdir -p "$W/$n/$(dirname "$f")"; echo "-- $f" > "$W/$n/$f"; done
  git -C "$W/$n" add -A && git -C "$W/$n" commit -q -m "init" && git -C "$W/$n" push -q origin main && git -C "$W/$n" fetch -q origin
  git -C "$W/$n" checkout -q -b work; echo "more" >> "$W/$n/README.md"; printf 'function alpha() {\n  return 2;\n}\n' > "$W/$n/src/app.js"
  git -C "$W/$n" commit -q -am "the PR's work" && git -C "$W/$n" push -q origin HEAD:refs/pull/7/head
}
mkrepo newrepo; mkrepo dbrepo migrations/0001_init.sql
grep -q '"seq23/seq-bin"' "$HERE/live-repos.json" && ! grep -q '"o/newrepo"' "$HERE/live-repos.json" || { echo "FAIL: the fixture repo must not be on live-repos.json"; exit 1; }
eval "$(grep '^sha_name() ' "$LAND")"   # land's own helper, never a copy

chk() { # [repo dir name] -> OUT, RC of the real `land --check 7`
  local d="${1:-newrepo}"; HEADSHA="$(git -C "$W/$d" rev-parse HEAD)"; export HEADSHA
  OUT="$(cd "$W/$d" && PATH="$BIN:$PATH" env ${SURF:+LAND_SURFACES="$SURF"} "$LAND" --check 7 2>&1 </dev/null | sed $'s/\033\\[[0-9;]*m//g'; exit "${PIPESTATUS[0]}")"; RC=$?
}
reset() { rm -f "$F"/body "$F"/files "$F"/labels "$F"/comments "$F"/state "$F"/base "$F"/url "$F"/outage "$F"/events "$F"/label-events; printf '%s' "${1-}" > "$F/body"; }
has() { grep -qF -- "$1" <<<"$OUT"; }
problems() { grep -cE '^  [0-9]+\. \[[A-Z_]+\] ' <<<"$OUT"; }
codes() { sed -nE 's/^  [0-9]+\. \[([A-Z_]+)\] .*/\1/p' <<<"$OUT" | paste -sd' ' -; }
clean() { [ "$RC" -eq 0 ] && has "description has everything land asks" && [ "$(problems)" -eq 0 ]; }
DOCS=$'Review class: none — docs only, nothing runs\nOutcome: none — a readme change runs nothing\n\n## Not built\nNothing cut.'
CODE='[{"path": "README.md"}, {"path": "src/app.js"}]'
FULL=$'Changes alpha.\n\nReview class: none — a small local tool fix\nForms: none — no form page or server path here\nOutcome: none — a helper change runs nothing\n\n## Mutation proof\n- put alpha back to 1 and test-alpha went red\n\n## Not built\nNothing cut.'

echo "=== one run lists everything (the review you will face, 1 and 2) ==="
reset ""; chk
check "a README-only PR with an EMPTY body, in a repo not on live-repos.json: exit 1" [ "$RC" -eq 1 ]
check "…both missing lines in ONE run (Outcome, Not built), each with the line to add" eval '[ "$(codes)" = "OUTCOME_UNDECLARED NOT_BUILT_UNDECLARED" ] && has "       add: Outcome: none — <why nothing scheduled or produced changes, 3+ words>" && has "       add: Outcome: <the real output that proves it works> — check: <a read-only shell command> — expect: >= <N>" && has "       add: ## Not built"'
check "…and no reviewer is asked for (a repo not yet launched is no class; docs touch no class path)" eval '! grep -qiE "review|PASS" <<<"$(grep -E "^  [0-9]+\. |add: " <<<"$OUT")"'
check "…ending in ONE named stop that counts the rest" eval '[ "$(grep -c "STOPPED:" <<<"$OUT")" -eq 1 ] && has "STOPPED: NAMED STOP [OUTCOME_UNDECLARED]" && has "And 1 more (NOT_BUILT_UNDECLARED)"'
reset "$DOCS"; chk
check "the same PR with its lines filled in: exit 0, nothing to fix, and no reviewer PASS anywhere on it" clean
reset ""; echo "$CODE" > "$F/files"; chk
check "a code PR with an empty body: three lines missing, all three listed in one run, no reviewer" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = "MUTATION_PROOF_MISSING OUTCOME_UNDECLARED NOT_BUILT_UNDECLARED" ] && has "       add: ## Mutation proof" && ! has "needs a review"'
reset "$FULL"; echo "$CODE" > "$F/files"; chk
check "…and filled in: exit 0" clean

echo "=== the ONE template carries every line land can ask for ==="
BLOCK="$(sed -n '/^# --- gates begin/,/^# --- gates end/p' "$LAND")"
covered() { # $1 template file -> 0 when every line code has lines there, every code land raises is listed, and the template names no stranger
  # shellcheck disable=SC2034  # LAND_TEMPLATE is read by template_add, defined by the eval of land's gates block
  ( eval "$BLOCK"; LAND_TEMPLATE="$1"; rc=0
    for c in $LAND_BODY_CODES; do template_add "$c" | grep -q . || { echo "    no template entry for $c"; rc=1; }; done
    for c in $( { grep -oE '(body_add|pass_problem|problem) [A-Z][A-Z_]+ ' "$LAND" | awk '{print $2}'; grep -oE 'NAMED STOP \[STALE_PASS\]' "$LAND" | sed 's/.*\[//; s/\]//'; } | sort -u); do
      case " $LAND_BODY_CODES $LAND_STATE_CODES " in *" $c "*) ;; *) echo "    land raises $c, which is on neither list"; rc=1 ;; esac; done
    for c in $(sed -nE 's/^<!-- land:([A-Z_,]+).*/\1/p' "$1" | tr ',' '\n'); do
      case " $LAND_BODY_CODES " in *" $c "*) ;; *) echo "    the template names $c, which land never asks for"; rc=1 ;; esac; done
    exit "$rc" )
}
check "every code in LAND_BODY_CODES has its line(s) in pr-body-template.md; every code land raises is listed; no stranger in the template" covered "$HERE/pr-body-template.md"
grep -v '^Forms: ' "$HERE/pr-body-template.md" > "$W/template-no-forms.md"
check "…a template that lost its Forms lines is caught (this check can fail)" eval '! covered "$W/template-no-forms.md" >/dev/null'
sed 's/^<!-- land:NOT_BUILT_UNDECLARED/<!-- land:SOMETHING_ELSE/' "$HERE/pr-body-template.md" > "$W/template-renamed.md"
check "…and so is a marker land never asks for" eval '! covered "$W/template-renamed.md" >/dev/null'
check "the template points nowhere else: land, land-after and README name pr-body-template.md" eval 'grep -q "pr-body-template.md" "$LAND" && grep -q "pr-body-template.md" "$HERE/land-after" && grep -q "pr-body-template.md" "$HERE/README.md"'
UI='[{"path": "src/app.js"}, {"path": "src/client/App.tsx"}]'
reset "$(cat "$HERE/pr-body-template.md")"; echo "$UI" > "$F/files"; chk
check "edge: the template pasted UNTOUCHED (every <placeholder> left in) passes nothing: all five lines are still asked for" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = "MUTATION_PROOF_MISSING FORMS_UNDECLARED OUTCOME_UNDECLARED NOT_BUILT_UNDECLARED NOT_CLICKED_THROUGH" ]'
check "…and its placeholder Ship-ready line is never read as a reviewer's PASS" eval '! has "STALE_PASS" && ! has "signed by"'
FILLED="$(sed -E \
  -e 's/^Review class: none — <.*/Review class: none — a local tool with no data/' -e '/^Review class: <money/d' \
  -e 's/^Forms: none — <.*/Forms: none — the screen holds no form/' -e '/^Forms: <which/d' \
  -e 's/^Outcome: none — <.*/Outcome: none — a screen change runs nothing/' -e '/^Outcome: <the real/d' \
  -e 's/^Patch or rebuild: .*/Patch or rebuild: a one line fix of the constant, no redesign needed (#41)/' \
  -e 's/^Clicked through: .*/Clicked through: the app screen at 390 px, console clean/' \
  -e 's/^\| <the fix> .*/| alpha returns 2 | put it back to 1 | test-alpha went red |/' -e '/^Mutation proof: none/d' \
  -e 's/^<each item not built.*/Nothing cut./' -e '/^## Reviewer lines/,$d' "$HERE/pr-body-template.md")"
reset "$FILLED"; echo "$UI" > "$F/files"; chk
check "edge: the template with EVERY line filled in (its markers left in place): exit 0" clean
reset "$(sed 's/$/\r/' <<<"$FILLED")"; echo "$UI" > "$F/files"; chk
check "edge: the same body with CRLF line ends: exit 0" clean
reset ""; chk
check "edge: a zero-line body never reads as clean" eval '[ "$RC" -eq 1 ] && [ "$(problems)" -eq 2 ]'
reset ""; jq -nc --arg b "$DOCS" '[{authorAssociation: "OWNER", body: $b}]' > "$F/comments"; chk
check "edge: the lines in a comment by the repo's OWNER account count: exit 0" clean
reset ""; jq -nc --arg b "$DOCS" '[{authorAssociation: "CONTRIBUTOR", body: $b}]' > "$F/comments"; chk
check "abuse: the same lines in a stranger's comment do not: still 2 to fix" eval '[ "$RC" -eq 1 ] && [ "$(problems)" -eq 2 ]'
reset "Owner override: ship it now please (27 Nov 2026)"; echo "$UI" > "$F/files"; chk
check "her bypass (an Owner override line) is never blocked by a missing line: exit 0, recorded UNDECLARED" eval '[ "$RC" -eq 0 ] && has "Outcome: UNDECLARED (owner bypass)" && [ "$(problems)" -eq 0 ]'

echo "=== only her list waits on a reviewer (the review you will face, 3) ==="
for cls in money private-data delete store launch outreach; do
  reset "${DOCS/Review class: none — docs only, nothing runs/Review class: $cls — the brief put it there}"; chk
  check "'Review class: $cls' with no reviewer PASS: refused (exit 1) for the PASS, with the line the reviewer posts" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = REVIEW_PASS_MISSING ] && has "needs a review (it says Review class: $cls)" && has "       add: Ship-ready: PASS — <fresh reviewer, its session or run id> looked at <the real output> at $(sha_name "$HEADSHA"); Engineering: PASS"'
done
check "the class list is ONE constant, her six: money, private-data, delete, store, launch, outreach" eval '[ "$(grep -c "^REVIEW_CLASSES=" "$LAND")" -eq 1 ] && grep -qx "REVIEW_CLASSES=\"money|private-data|delete|store|launch|outreach\"" "$LAND" && grep -q "^Review class: <money | private-data | delete | store | launch | outreach> — <why>$" "$HERE/pr-body-template.md"'
reset "${DOCS/Review class: none — docs only, nothing runs/Review class: children — an old class word}"; chk
check "a class word land does not know still waits on a reviewer (never read as none)" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = REVIEW_PASS_MISSING ]'
reset "$DOCS"; echo '[{"name": "review-required"}]' > "$F/labels"; chk
check "the review-required label, body says none: refused for the PASS" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = REVIEW_PASS_MISSING ] && has "it carries the review-required label"'
reset "$DOCS"; echo '["bug", "review-required"]' > "$F/label-events"; chk
check "abuse: the label taken off again (label history), body says none: still refused for the PASS" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = REVIEW_PASS_MISSING ] && has "a label taken off still counts"'
reset "$DOCS"; echo '[{"path": "README.md"}, {"path": "live-repos.json"}]' > "$F/files"; chk
check "abuse: a PR that changes live-repos.json, body says none: refused for the PASS" eval '[ "$RC" -eq 1 ] && has "[REVIEW_PASS_MISSING]" && has "it changes live-repos.json"'
reset "$DOCS"; echo null > "$F/labels"; chk
check "labels missing from GitHub's answer (unread): never 'no review needed'" eval '[ "$RC" -eq 1 ] && has "[REVIEW_PASS_MISSING]" && has "its labels could not be read"'
reset "$DOCS"; jq -nc '[{authorAssociation: "OWNER", body: "Review class: money — the coordinator put it there"}]' > "$F/comments"; chk
check "abuse: the body says none, an owner comment names a class: the class wins" eval '[ "$RC" -eq 1 ] && has "[REVIEW_PASS_MISSING]" && has "it says Review class: money"'
reset "${DOCS/Review class: none — docs only, nothing runs/Review class: money — a price changes}"; HEADSHA="$(git -C "$W/newrepo" rev-parse HEAD)"
jq -nc --arg b "Ship-ready: PASS — reviewer session_01REVIEW looked at the diff and the price page at $(sha_name "$HEADSHA"); Engineering: PASS" '[{authorAssociation: "OWNER", createdAt: "2026-11-27T13:00:00Z", body: $b}]' > "$F/comments"; chk
check "a money PR WITH a fresh reviewer's PASS for this head: exit 0" clean
reset "${DOCS/Review class: none — docs only, nothing runs/Review class: money — a price changes}"
jq -nc --arg b "Ship-ready: PASS — reviewer session_01REVIEW looked at the diff and the price page at $(sha_name "$HEADSHA"); Engineering: PASS" '[{authorAssociation: "NONE", createdAt: "2026-11-27T13:00:00Z", body: $b}]' > "$F/comments"; chk
check "abuse: the same PASS posted by a stranger counts for nothing" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = REVIEW_PASS_MISSING ]'

echo "=== a missing Review class line is read from the paths, never guessed (the review you will face, 4) ==="
NOCLASS="${FULL/Review class: none — a small local tool fix/}"
for row in "src/billing/charge.ts|money" "worker/stripe-webhook.ts|money" "migrations/0007_drop_users.sql|delete" "scripts/backfill-emails.mjs|delete" "store/listing.json|store" "src/emails/welcome.html|outreach" "worker/outreach-sender.ts|outreach"; do
  p="${row%%|*}"; c="${row##*|}"
  reset "$NOCLASS"; echo "[{\"path\": \"$p\"}]" > "$F/files"; chk
  check "no Review class line, the diff touches $p: NOT read as none; the line is asked for, naming $c" eval 'has "[REVIEW_CLASS_UNDECLARED]" && has "$c ($p)" && has "       add: Review class: none — <why this is in no review class, 3+ words>" && ! has "[REVIEW_PASS_MISSING]" && [ "$RC" -eq 1 ]'
done
reset "$FULL"; echo '[{"path": "src/billing/charge.ts"}]' > "$F/files"; chk
check "…the same payments path WITH a reasoned 'Review class: none': the builder's word stands, no class problem" eval '! has "REVIEW_CLASS_UNDECLARED" && ! has "REVIEW_PASS_MISSING"'
reset "$NOCLASS"; echo "$CODE" > "$F/files"; chk
check "no Review class line, a code change on no class path, a repo with no data store: read as none, exit 0" clean
reset "${FULL/Review class: none — a small local tool fix/Review class: none — <why>}"; echo '[{"path": "src/billing/charge.ts"}]' > "$F/files"; chk
check "edge: 'Review class: none — <why>' (the placeholder left in) is no line at all on a payments path" eval '[ "$RC" -eq 1 ] && has "[REVIEW_CLASS_UNDECLARED]"'
reset "$NOCLASS"; echo "$CODE" > "$F/files"; chk dbrepo
check "private data has no path test: in a repo that holds a data store (a migration on main), a code change with no line is asked for it" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = REVIEW_CLASS_UNDECLARED ] && has "holds a data store (migrations/0001_init.sql)"'
reset "${DOCS/Review class: none — docs only, nothing runs/}"; chk dbrepo
check "…a docs-only PR in that repo is still read as none: exit 0" clean
reset "$NOCLASS"; echo "$CODE" > "$F/files"; SURF="$W/no-such-surfaces.json" chk
check "outage: land-surfaces.json unreadable: never read as none, never clean" eval '[ "$RC" -eq 1 ] && has "LAND_SURFACES_UNREAD" && ! has "has everything"'
printf '{"exclude": ["(^|/)docs/"], "everywhere": [], "types": [], "launch": []}\n' > "$W/surfaces-no-review.json"
SURF="$W/surfaces-no-review.json" chk
check "outage: a land-surfaces.json with no review paths: the line is asked for, never inferred" eval '[ "$RC" -eq 1 ] && has "[REVIEW_CLASS_UNDECLARED]" && has "could not be read"'

echo "=== GitHub not answering is 'could not verify', never clean (the review you will face, 6) ==="
for m in tls ratelimit 401 empty; do
  reset "$FULL"; echo "$m" > "$F/outage"; chk
  check "outage ($m) reading the PR: exit 75, 'could not verify', no problem list, never 'has everything'" eval '[ "$RC" -eq 75 ] && has "STOPPED: could not verify" && ! has "has everything" && [ "$(problems)" -eq 0 ]'
done
reset "$FULL"; echo tls > "$F/events"; chk
check "outage: the label history unread: exit 75, never 'no review needed'" eval '[ "$RC" -eq 75 ] && has "label history" && ! has "has everything"'
reset "$FULL"; echo MERGED > "$F/state"; chk
check "a merged PR: says so and exits 0 without calling it checked" eval '[ "$RC" -eq 0 ] && has "already MERGED" && ! has "has everything"'
reset "$FULL"; echo CLOSED > "$F/state"; chk
check "a closed PR: exit 1" eval '[ "$RC" -eq 1 ] && has "closed without merging"'
reset "$FULL"; echo WEIRD > "$F/state"; chk
check "rule 0: a state GitHub never sends is 'could not verify' (exit 75), never exit 0" eval '[ "$RC" -eq 75 ] && ! has "has everything"'
reset "$DOCS"; echo work/other > "$F/base"; chk
check "a stacked PR (base is not main): listed as STACKED_PR, exit 1" eval '[ "$RC" -eq 1 ] && [ "$(codes)" = STACKED_PR ] && has "merges into work/other"'

echo "=== --check only reads (safety) ==="
: > "$F/calls"
OUT="$(cd "$W/newrepo" && PATH="$BIN:$PATH" "$LAND" --check 7 '--owner=ship it now' 2>&1)"; RC=$?
check "--check with --owner (which writes her bypass onto the PR) is refused before any GitHub call" eval '[ "$RC" -eq 1 ] && has "land --check only reads" && [ ! -s "$F/calls" ]'
reset $'Review class: none — a page fix on a live site\nForms: contact form — preview: TEST submission 14:02 reached the test inbox, row 88 marked test\nOutcome: the page answers — check: curl -s https://example.com/ | grep -c Example — expect: >= 1 — by: next day\n\n## Mutation proof\n- undid the fix and test-contact went red\n\n## Not built\nNothing cut.'; echo "$CODE" > "$F/files"; chk
check "a PR with a real Outcome check and a form proven on the preview: exit 0" clean
check "…and nothing was written to HANDOFF (a check lands nothing: no FORM-PROOF or OUTCOME-CHECK line)" cmp -s "$LAND_HANDOFF" "$W/HANDOFF.before"
: > "$F/calls"; reset ""; chk; reset "$DOCS"; chk; reset "${DOCS/none — docs only, nothing runs/money — a price changes}"; chk
check "across a failing, a clean and a review-class check the fake gh saw ONLY reads: pr view, the label events, check suites; zero merge, comment, label, edit or API write calls" \
  eval '[ -s "$F/calls" ] && ! grep -vE "^pr view 7 --json |^api --paginate repos/o/newrepo/issues/7/events |^api repos/\{owner\}/\{repo\}/commits/[0-9a-f]+/check-suites|^api rate_limit" "$F/calls" | grep -q . && ! grep -qE "^pr (merge|comment|edit|close|ready|review)|^issue |^label |-X |--method|-f " "$F/calls"'
check "…and no merge happened: the PR's branch is not on main" eval '! git -C "$W/newrepo" merge-base --is-ancestor "$HEADSHA" origin/main'

echo
echo "test-land-check: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
