#!/bin/bash
# land's gates block (evaluated verbatim) against a real git origin and PR JSON, one negative test per
# path (rows 6c, 6e, 20 of 20 Nov 2026):
#   ship-ready  — a PR that changes what people see: no PASS line -> refused; a PASS signed by the
#                 builder (commit author, co-author, PR author, the builder's Claude session) ->
#                 refused; a fresh reviewer's PASS -> allowed; a PR people never see -> no line needed;
#                 something new going public also needs Launch-ready; a red ship-ready-baseline check
#                 is refused even with a PASS (row 18's hook; absent check = nothing to read).
#   patch       — a PR changing a function a fix commit changed in the last 30 days -> refused without
#                 a "Patch or rebuild:" line naming that fix; allowed with one; a fix older than the
#                 window, or one in another function, asks nothing; a placeholder line is not an answer.
#   protected   — a noelle/ branch or a .github/ change (#175, her yes 27 Nov 2026): the body is never a review, her
#                 Owner override and --owner never clear REVIEW_REQUIRED, the PASS is an owner comment naming the current
#                 head (STALE_PASS otherwise), and the exact git diff sees a .github file deleted or renamed out; git that
#                 cannot tell is 75, and JSON whose exact diff was never read counts as protected.
# Negative proofs at the foot: a block whose signoff ignores the builder, and one whose patch check
# never reads history, both fail these cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAND="${LAND_UNDER_TEST:-$HERE/land}"
export LAND_SURFACES="$HERE/land-surfaces.json"
BLOCK="$(sed -n '/^# --- gates begin/,/^# --- gates end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: no gates block in $LAND"; exit 1; }
grep -q '^body_gates "$PR" "$HEAD" "$PRMETA" "${OWNER_WORDS:+1}"; BODY_RC=$?$' "$LAND" && grep -q 'out="$(gate_pr "$1" "$2" "$3")"; rc=$?' "$LAND" \
  || { echo "FAIL: land no longer runs gate_pr (through body_gates) before merging"; exit 1; }
grep -q 'BASELINE_RED="$(baseline_red "$CHECKS")" && die' "$LAND" || { echo "FAIL: land no longer reads the ship-ready-baseline check"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export LAND_DIR="$W/landdir"; mkdir -p "$LAND_DIR"; printf '{"live": ["o/live"]}\n' > "$LAND_DIR/live-repos.json"   # the list beside land (its re-exec sets LAND_DIR)
cp "$HERE/pr-body-template.md" "$LAND_DIR/"   # the ONE template, beside land: where every "add:" line comes from
export GIT_AUTHOR_NAME=builder GIT_AUTHOR_EMAIL=builder@example.test GIT_COMMITTER_NAME=builder GIT_COMMITTER_EMAIL=builder@example.test
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then echo "  ok   $label"; passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi; }

# repo: origin/main holds a site page and src/sync.ts with two functions; history per case.
repo() {
  rm -rf "$W/origin.git" "$W/r"; git init -q --bare -b main "$W/origin.git"; git clone -q "$W/origin.git" "$W/r" 2>/dev/null
  mkdir -p "$W/r/src" "$W/r/site"; echo '<h1>hi</h1>' > "$W/r/site/index.html"
  printf 'export function alpha(x) {\n  return x + 1;\n}\n\nexport function beta(y) {\n  return y * 2;\n}\n' > "$W/r/src/sync.ts"
  git -C "$W/r" add -A; GIT_COMMITTER_DATE="2026-01-01T00:00:00" git -C "$W/r" commit -qm "start" --date 2026-01-01T00:00:00
}
commit() { # message [date] -- changes src/sync.ts line $LINE to $TEXT
  sed -i.bak "${LINE}s/.*/${TEXT}/" "$W/r/src/sync.ts" && rm -f "$W/r/src/sync.ts.bak"
  if [ -n "${2:-}" ]; then GIT_COMMITTER_DATE="$2" git -C "$W/r" commit -qam "$1" --date "$2"; else git -C "$W/r" commit -qam "$1"; fi
}
pr_head() { # leaves main pushed, then a PR commit on top -> PR_HEAD
  git -C "$W/r" push -q origin HEAD:main; git -C "$W/r" fetch -q origin
  LINE="$1" TEXT="$2" commit "the PR"; PR_HEAD="$(git -C "$W/r" rev-parse HEAD)"
  git -C "$W/r" push -q origin "HEAD:refs/pull/9/head"; git -C "$W/r" reset -q --hard origin/main
}
meta() { # body [files json] [extra json] -> PR view JSON
  local f='[{"path":"src/sync.ts"}]'; [ -z "${2:-}" ] || f="$2"
  local b="$1"; [ -n "${NOPROOF:-}" ] || b="$b"$'\n\n''## Mutation proof'$'\n''- alpha +1 back to +0: tests/sync.test.ts alpha goes red'
  # a code PR (the default files) carries a fresh reviewer's PASS too, unless NOREVIEW (22 Nov 2026: the gate is real for code)
  [ -n "${2:-}" ] || [ -n "${NOREVIEW:-}" ] || b="$b"$'\n''Ship-ready: PASS — code reviewer session_01REVIEW looked at the diff and its tests at @HEAD@; Engineering: PASS'
  jq -n --arg b "$b" --argjson f "$f" \
    '{files: $f, body: $b, from_git_github: false, author: {login: "seq23"}, commits: [{authors: [{name: "builder", email: "builder@example.test", login: ""}],
      messageBody: "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01BUILDER"}]}' \
    | if [ -n "${FAST:-}" ]; then   # FAST: a PR in no review class (a launched repo, no label ever, a reasoned none)
        jq -c '. + {labels: [], label_history: [], url: "https://github.com/o/live/pull/9"} | .body += "\nReview class: none — docs and tests only here"'
      else cat; fi
}
# gh, for the one read the gates make: when a commit reached GitHub (its earliest check suite, review F5 of #137).
# $W/suites/<sha> holds that epoch; none is a commit with no suite; $W/suites-down is GitHub not answering.
mkdir -p "$W/bin" "$W/suites"
cat > "$W/bin/gh" <<SH
#!/bin/bash
case "\$*" in
  "api repos/{owner}/{repo}/commits/"*"/check-suites"*)
    [ -f "$W/suites-down" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
    c="\${2#repos/\{owner\}/\{repo\}/commits/}"; c="\${c%%/*}"; cat "$W/suites/\$c" 2>/dev/null; exit 0 ;;
esac
echo "unexpected gh call: \$*" >&2; exit 1
SH
chmod +x "$W/bin/gh"
pushed() { jq -rn --arg t "$2" '$t | fromdateiso8601' > "$W/suites/$1" || exit 1; }   # sha, when GitHub first saw it (jq: BSD and GNU date differ, and CI is Linux)
# A short sha the gate can read: land takes 7-40 hex characters with at least one a-f (a bare number is a size, not a
# commit), so a prefix that happens to be all digits (8 chars: about 1 in 40 commits) is lengthened, never a flake.
eval "$(grep '^sha_name() ' "$LAND")"   # land's own helper, never a copy
gate() { # PR-view JSON -> RC, MSG: gate_pr's problems as land prints them (numbered, each with the line to add from
  # the ONE template), or its one plain line when it could not read (rc 75). Run in the repo, through the block.
  MSG="$(cd "$W/r" && PATH="$W/bin:$PATH" bash -c "$BLOCK"$'\n''out="$(gate_pr 9 "$1" "$2")"; rc=$?; if [ "$rc" -eq 1 ]; then problems_print 9 "$1" <<<"$out"; else printf "%s" "$out"; fi; exit "$rc"' _ "$PR_HEAD" "${1//@HEAD@/$(sha_name "$PR_HEAD")}")"; RC=$?
  [ -z "${GATES_TEST_SHOW:-}" ] || echo "    | rc $RC: $MSG"
}
one_line() { [ "$(grep -cE '^  [0-9]+\. \[[A-Z_]+\] ' <<<"$MSG")" -eq 1 ] && grep -q '^       add: ' <<<"$MSG"; }   # ONE problem, with its line to add
check "sha_name: an all-digit 8-char prefix is lengthened to its first a-f (12345678901b…) -> 12345678901b" [ "$(sha_name 12345678901b3c4d5e6f7a8b9c0d1e2f3a4b5c6d)" = 12345678901b ]
check "sha_name: a prefix with a letter stays 8 characters" [ "$(sha_name 1a345678901b3c4d5e6f7a8b9c0d1e2f3a4b5c6d)" = 1a345678 ]
no_bare8() { ! grep -qE '[$][{][a-zA-Z0-9]+:0:8[}]' "$LAND"; }
check "land never prints a bare 8-char sha for a reviewer to post (every one goes through sha_name)" no_bare8
SITE='[{"path":"site/index.html"}]'
# @HEAD@ is the PR head's short sha, filled in by gate(): a PASS names the commit it looked at (STALE_PASS).
GOOD='Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px and 1280 px at @HEAD@; Engineering: PASS'

run_cases() {
echo "=== ship-ready: a PR that changes what people see ==="
repo; pr_head 2 '  return x + 2;'
gate "$(meta 'Tweaks the page.' "$SITE")"
check "no PASS line -> refused (rc 1)" [ "$RC" -eq 1 ]
check "…in one plain line that says what to add" eval 'one_line && grep -q "Ship-ready: PASS — " <<<"$MSG"'
gate "$(meta "Ship-ready: PASS — <reviewer> looked at the home page at 390 px" "$SITE")"
check "a PASS line still holding the template's <reviewer> placeholder is no PASS -> refused, asking for a fresh reviewer's line" eval '[ "$RC" -eq 1 ] && one_line && grep -q "no fresh reviewer.s Ship-ready PASS line stands" <<<"$MSG"'
for who in builder builder@example.test 'Claude Opus 5.5' seq23 'me' 'agent session_01BUILDER'; do
  gate "$(meta "Ship-ready: PASS — $who looked at the home page at 390 px" "$SITE")"
  check "PASS signed by the builder ($who) -> refused" eval '[ "$RC" -eq 1 ] && one_line && grep -q "signed by the builder" <<<"$MSG"'
done
gate "$(meta "$GOOD" "$SITE")"
check "a fresh reviewer's PASS -> allowed (rc 0)" [ "$RC" -eq 0 ]
echo "=== a PASS posted as a PR comment counts only from the repo's owner account (22 Nov 2026 review N8) ==="
with_comment() { jq --arg c "$2" --arg who "$3" '.comments = [{author: {login: "x"}, authorAssociation: $who, body: $c}]' <<<"$1"; }
gate "$(with_comment "$(meta 'Tweaks the page.' "$SITE")" "$GOOD" OWNER)"
check "a fresh reviewer's PASS in a comment by the owner account -> allowed (rc 0)" [ "$RC" -eq 0 ]
for who in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR COLLABORATOR; do
  gate "$(with_comment "$(meta 'Tweaks the page.' "$SITE")" "$GOOD" "$who")"
  check "the same PASS in a comment by a $who account -> refused" eval '[ "$RC" -eq 1 ] && one_line && grep -q "Ship-ready: PASS — " <<<"$MSG"'
done
gate "$(with_comment "$(meta 'Tweaks the page.' "$SITE")" 'Ship-ready: PASS — builder looked at the page; Engineering: PASS' OWNER)"
check "an owner-account comment signed by the builder -> still refused as the builder's" eval '[ "$RC" -eq 1 ] && grep -q "signed by the builder" <<<"$MSG"'
two_comments() { jq --arg a "$2" --arg b "$3" '.comments = [{authorAssociation: "OWNER", body: $a}, {authorAssociation: "OWNER", body: $b}]' <<<"$1"; }
gate "$(two_comments "$(meta 'Tweaks the page.' "$SITE")" "$GOOD" $'VERDICT: fail\n- F1 the page is blank at 390 px')"
check "a later VERDICT: fail comment voids an earlier PASS comment -> refused (N9)" [ "$RC" -eq 1 ]
check "…and says why: the PASS is voided by the later fail, post it again as a new comment" eval 'one_line && grep -q "PASS in an owner comment" <<<"$MSG" && grep -q "voids it" <<<"$MSG" && grep -q "NEW PR comment" <<<"$MSG"'
gate "$(two_comments "$(meta "$GOOD" "$SITE")" $'VERDICT: fail\n- F1 blank' 'Thanks, fixing.')"
check "a PASS in the body before an owner fail comment -> refused, naming the body as voided" eval '[ "$RC" -eq 1 ] && grep -q "PASS in the PR body does not count" <<<"$MSG"'
gate "$(jq --arg c "$GOOD" '.comments = [{authorAssociation: "NONE", body: $c}, {authorAssociation: "OWNER", body: "VERDICT: fail"}]' <<<"$(meta 'Tweaks the page.' "$SITE")")"
check "abuse: a stranger's PASS before an owner fail is never called voided, never echoed" eval '[ "$RC" -eq 1 ] && ! grep -q "does not count" <<<"$MSG" && ! grep -q "session_01REVIEW" <<<"$MSG"'
gate "$(two_comments "$(meta 'Tweaks the page.' "$SITE")" $'VERDICT: fail\n- F1 blank' 'Thanks, fixing.')"
check "a fail with no PASS before it -> the plain refusal (nothing to call voided)" eval '[ "$RC" -eq 1 ] && ! grep -q "does not count" <<<"$MSG" && grep -q "Ship-ready: PASS — " <<<"$MSG"'

gate "$(two_comments "$(meta 'Tweaks the page.' "$SITE")" $'VERDICT: fail\n- F1 blank' "$GOOD")"
check "a PASS posted after the fail comment -> allowed (rc 0)" [ "$RC" -eq 0 ]
echo "=== only a first-line VERDICT: fail voids a PASS (review R5) ==="
for later in 'verdict: failsafe is how the gate behaves' 'Verdict: failed checks fixed in 34d66c9' $'Re-check notes\nR3 earlier VERDICT: fail now fixed'; do
  gate "$(two_comments "$(meta 'Tweaks the page.' "$SITE")" "$GOOD" "$later")"
  check "a later comment '${later%%$'\n'*}…' does not void the PASS (rc 0)" [ "$RC" -eq 0 ]
done
gate "$(two_comments "$(meta 'Tweaks the page.' "$SITE")" "$GOOD" $'**VERDICT:** fail\n- F1 blank')"
check "a later first-line **VERDICT:** fail still voids it (rc 1)" [ "$RC" -eq 1 ]
echo "=== engineering rides on the Ship-ready PASS (her ruling 21 Nov 2026) ==="
gate "$(meta 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px' "$SITE")"
check "a PASS that says nothing of engineering -> refused (rc 1)" [ "$RC" -eq 1 ]
check "…in one line naming engineering.md and exactly what to add" eval 'one_line && grep -q "every automatic fail in ~/.claude/skills/ship-ready/engineering.md" <<<"$MSG" && grep -q "; Engineering: PASS" <<<"$MSG"'
gate "$(meta 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px; checked engineering.md 1–6' "$SITE")"
check "a numbered range (\"engineering.md 1–6\") is not a sign-off: it skips fails added since -> refused" eval '[ "$RC" -eq 1 ] && grep -q "; Engineering: PASS" <<<"$MSG"'
gate "$(meta "$(printf 'Engineering: PASS\nShip-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px')" "$SITE")"
check "Engineering: PASS on another line is not this reviewer's -> refused" [ "$RC" -eq 1 ]
gate "$(meta 'Ship-ready: PASS — builder looked at the home page at 390 px; Engineering: PASS' "$SITE")"
check "Engineering: PASS signed by the builder -> refused as the builder's" eval '[ "$RC" -eq 1 ] && grep -q "signed by the builder" <<<"$MSG"'
gate "$(meta 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px; Engineering: FAIL (engineering.md fail 1)' "$SITE")"
check "Engineering: FAIL -> refused" [ "$RC" -eq 1 ]
echo "=== owner override (her ruling 21 Nov 2026) ==="
gate "$(meta "$(printf 'Tweaks the page.\n\nOwner override: "land it deploy it finish it" (21 Nov 2026 13:10 CT)')" "$SITE")"
check "her Owner override line, no PASS -> allowed (rc 0)" [ "$RC" -eq 0 ]
gate "$(meta "$(printf 'Owner override: <her words> (date)')" "$SITE")"
check "a placeholder override is not her words -> refused" [ "$RC" -eq 1 ]
gate "$(meta "$(printf 'Owner override: ok')" "$SITE")"
check "a one-word override is refused" [ "$RC" -eq 1 ]
gate "$(meta "$(printf 'Notes\n- Ship-ready: PASS -- Codex review run 4412 looked at the rendered welcome email at 390 px at @HEAD@; engineering: pass')" '[{"path":"src/mail/welcome.ts"}]')"
check "an email template counts, and '--' and a list bullet are accepted" [ "$RC" -eq 0 ]
gate "$(meta "" '[{"path":"src/mail/welcome.ts"}]')"
check "…and without the line the email is refused" [ "$RC" -eq 1 ]
gate "$(FAST=1 meta "" '[{"path":"tests/site/x.test.tsx"},{"path":"README.md"},{"path":"docs/a.html"},{"path":"data/rows.json"}]')"
check "outside the review classes, tests, docs and data need no line (rc 0)" [ "$RC" -eq 0 ]
gate "$(meta "" '[{"path":"tests/site/x.test.tsx"},{"path":"README.md"},{"path":"docs/a.html"},{"path":"data/rows.json"}]')"
check "a REVIEW-CLASS PR needs the PASS even for tests, docs and data (eng check of #155: data skipped review) -> refused" [ "$RC" -eq 1 ]

echo "=== a reviewer's PASS on every code PR (22 Nov 2026, her words: make the reviewer gate real in land now) ==="
CODE='[{"path":"worker/x.ts"},{"path":"README.md"}]'
gate "$(meta "Adds the sync." "$CODE")"
check "server code with no PASS -> refused in one line, naming the code and the line to post at the head" eval '[ "$RC" -eq 1 ] && one_line && grep -q "changes code (worker/x.ts" <<<"$MSG" && grep -q "Ship-ready: PASS — " <<<"$MSG" && grep -q "at $(sha_name "$PR_HEAD"); Engineering: PASS" <<<"$MSG"'
gate "$(meta "$GOOD" "$CODE")"
check "…with a fresh reviewer's PASS at the head -> allowed" [ "$RC" -eq 0 ]
gate "$(meta 'Ship-ready: PASS — builder session_01BUILDER looked at the diff at @HEAD@; Engineering: PASS' "$CODE")"
check "abuse: the builder's own session signs it -> refused as the builder's" eval '[ "$RC" -eq 1 ] && grep -q "signed by the builder" <<<"$MSG"'
gate "$(meta 'Ship-ready: PASS — me looked at the diff at @HEAD@; Engineering: PASS' "$CODE")"
check "abuse: signed 'me' -> refused as the builder's" eval '[ "$RC" -eq 1 ] && grep -q "signed by the builder" <<<"$MSG"'
gate "$(with_comment "$(meta 'Adds the sync.' "$CODE")" "$GOOD" NONE)"
check "abuse: the PASS in a stranger's comment -> refused" [ "$RC" -eq 1 ]
gate "$(meta 'Ship-ready: PASS — reviewer session_01REVIEW looked at the diff at @HEAD@' "$CODE")"
check "a PASS that does not cover engineering -> refused" eval '[ "$RC" -eq 1 ] && grep -q "Engineering: PASS" <<<"$MSG"'
gate "$(meta "$GOOD" '[{"path":"worker/x.ts"},{"path":"wrangler.toml"}]')"
check "code alone never needs Launch-ready (rc 0)" [ "$RC" -eq 0 ]
gate "$(meta 'Owner override: "ship it, land it now" (22 Nov 2026 12:00 CT)' "$CODE")"
check "her Owner override still skips it (rc 0)" [ "$RC" -eq 0 ]

echo "=== launch-ready: something new goes public ==="
gate "$(meta "$GOOD" '[{"path":"site/index.html"},{"path":"wrangler.toml"}]')"
check "a new site (wrangler.toml added) with only Ship-ready -> refused" eval '[ "$RC" -eq 1 ] && one_line && grep -q "Launch-ready: PASS — " <<<"$MSG"'
gate "$(meta "$GOOD"$'\n''Launch-ready: PASS — launch reviewer session_01LAUNCH looked at logo, banner, bio, links, starter posts, 404 at @HEAD@' '[{"path":"site/index.html"},{"path":"wrangler.toml"}]')"
check "…with a fresh Launch-ready PASS -> allowed" [ "$RC" -eq 0 ]
gate "$(meta "$GOOD"$'\n''Launch-ready: PASS — builder looked at the 404' '[{"path":"site/index.html"},{"path":"wrangler.toml"}]')"
check "…signed by the builder -> refused" [ "$RC" -eq 1 ]
rm -f "$W/r/site/index.html"; git -C "$W/r" commit -qam "no pages"; git -C "$W/r" push -q origin HEAD:main
gate "$(meta "$GOOD" '[{"path":"app/screens/Home.tsx"}]')"
check "the repo's first surface ever needs Launch-ready" eval '[ "$RC" -eq 1 ] && grep -q "first surface" <<<"$MSG"'

echo "=== a PASS is for the commit it names: STALE_PASS (22 Nov 2026) ==="
# stale_pr: main pushed; the PR's commit A changes the page and is what the reviewer passed (PASSED).
stale_pr() {
  repo; git -C "$W/r" push -q origin HEAD:main; git -C "$W/r" checkout -q -b pr
  echo '<h1>reviewed</h1>' > "$W/r/site/index.html"; git -C "$W/r" commit -qam "the page"; PASSED="$(git -C "$W/r" rev-parse HEAD)"
}
publish_pr() { PR_HEAD="$(git -C "$W/r" rev-parse HEAD)"; git -C "$W/r" push -q -f origin "HEAD:refs/pull/9/head"; git -C "$W/r" checkout -q main; git -C "$W/r" branch -q -D pr; }
passed_at() { printf 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px at %s; Engineering: PASS' "$(sha_name "$PASSED")"; }
stale_pr; publish_pr
gate "$(meta "$(passed_at)" "$SITE")"
check "a PASS naming the head -> allowed (rc 0)" [ "$RC" -eq 0 ]
stale_pr; echo '<h1>changed after the review</h1>' > "$W/r/site/index.html"; git -C "$W/r" commit -qam "after the PASS"; publish_pr
gate "$(meta "$(passed_at)" "$SITE")"
check "new code after the PASS -> refused STALE_PASS (rc 1)" eval '[ "$RC" -eq 1 ] && one_line && grep -q "STALE_PASS" <<<"$MSG" && grep -q "site/index.html" <<<"$MSG"'
stale_pr; git -C "$W/r" checkout -q main; echo two > "$W/r/other.txt"; git -C "$W/r" add other.txt; git -C "$W/r" commit -qm "main moves on"
git -C "$W/r" push -q origin HEAD:main; git -C "$W/r" checkout -q pr; git -C "$W/r" merge -q --no-edit main; publish_pr
gate "$(meta "$(passed_at)" "$SITE")"
check "a main merge after the PASS -> allowed, the PASS survives (rc 0)" [ "$RC" -eq 0 ]
stale_pr; git -C "$W/r" checkout -q main; echo two > "$W/r/other.txt"; git -C "$W/r" add other.txt; git -C "$W/r" commit -qm "main moves on"
git -C "$W/r" push -q origin HEAD:main; git -C "$W/r" checkout -q pr; git -C "$W/r" merge -q --no-commit main
echo '<h1>slipped into the merge</h1>' > "$W/r/site/index.html"; git -C "$W/r" add -A; git -C "$W/r" commit -qm "merge main"; publish_pr
gate "$(meta "$(passed_at)" "$SITE")"
check "new lines inside a merge commit -> refused STALE_PASS" eval '[ "$RC" -eq 1 ] && grep -q "STALE_PASS" <<<"$MSG"'
stale_pr; publish_pr
gate "$(meta 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px; Engineering: PASS' "$SITE")"
check "a PASS that names no commit -> refused STALE_PASS, with the head to name" eval '[ "$RC" -eq 1 ] && one_line && grep -q "STALE_PASS" <<<"$MSG" && grep -q "names no commit" <<<"$MSG" && grep -q " at $(sha_name "$PR_HEAD"); Engineering: PASS" <<<"$MSG"'
gate "$(meta 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px at deadbeef1; Engineering: PASS' "$SITE")"
check "a PASS naming a commit not on the PR -> refused STALE_PASS" eval '[ "$RC" -eq 1 ] && grep -q "names no commit" <<<"$MSG"'
# Review F1 of #137: a re-check line names the old commit first ("the diff A..B", "diff since A … at B").
stale_pr; echo '<h1>fixed after the fail</h1>' > "$W/r/site/index.html"; git -C "$W/r" commit -qam "the fix"; publish_pr
gate "$(meta "Ship-ready: PASS — re-check agent session_01RECHECK looked at the diff $(sha_name "$PASSED")..$(sha_name "$PR_HEAD") at 390 px; Engineering: PASS" "$SITE")"
check "a re-check PASS on 'the diff <old>..<head>' -> allowed (the newest commit it names)" [ "$RC" -eq 0 ]
gate "$(meta "Ship-ready: PASS — re-check agent session_01RECHECK looked at the diff since $(sha_name "$PASSED"), tests at $(sha_name "$PR_HEAD"); Engineering: PASS" "$SITE")"
check "a re-check PASS on 'diff since <old> … at <head>' -> allowed" [ "$RC" -eq 0 ]
gate "$(meta "Ship-ready: PASS — re-check agent session_01RECHECK looked at the diff since $(sha_name "$PASSED"); Engineering: PASS" "$SITE")"
check "…naming only the old commit, with work after it -> still STALE_PASS" eval '[ "$RC" -eq 1 ] && grep -q "STALE_PASS" <<<"$MSG"'
# Review F2 of #137: the reviewer template's line names no commit; its time decides, where it is known.
SHALESS='Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px; Engineering: PASS'
at_comment() { jq --arg c "$SHALESS" --arg at "$2" '.comments = [{authorAssociation: "OWNER", createdAt: $at, body: $c}]' <<<"$1"; }
stale_pr; git -C "$W/r" commit -q --amend --no-edit --date 2026-01-02T00:00:00Z; GIT_COMMITTER_DATE=2026-01-02T00:00:00Z git -C "$W/r" commit -q --amend --no-edit; publish_pr
pushed "$PR_HEAD" 2026-01-02T00:05:00Z
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-03T00:00:00Z)"
check "a PASS naming no commit, in an owner comment posted after the PR's last commit reached GitHub -> allowed" [ "$RC" -eq 0 ]
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-01T12:00:00Z)"
check "…posted before it reached GitHub -> refused STALE_PASS" eval '[ "$RC" -eq 1 ] && one_line && grep -q "STALE_PASS" <<<"$MSG" && grep -q "posted before its last commit reached GitHub" <<<"$MSG"'
# Review F5 of #137: the commit's date is the builder's. Committed 10:00, PASS 10:10 (on the older head), pushed 10:20.
stale_pr; git -C "$W/r" commit -q --amend --no-edit --date 2026-01-03T10:00:00Z; GIT_COMMITTER_DATE=2026-01-03T10:00:00Z git -C "$W/r" commit -q --amend --no-edit; publish_pr
pushed "$PR_HEAD" 2026-01-03T10:20:00Z
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-03T10:10:00Z)"
check "committed 10:00, PASS 10:10, pushed 10:20 -> refused STALE_PASS (the push time decides, not the commit date)" eval '[ "$RC" -eq 1 ] && grep -q "STALE_PASS" <<<"$MSG" && grep -q "posted before its last commit reached GitHub" <<<"$MSG"'
rm -f "$W/suites/$PR_HEAD"
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-03T00:00:00Z)"
check "…no check suite on the commit (when it arrived is unknown) -> refused STALE_PASS, never a pass" eval '[ "$RC" -eq 1 ] && grep -q "STALE_PASS" <<<"$MSG" && grep -q "unknown (no check suite)" <<<"$MSG"'
: > "$W/suites-down"
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-03T00:00:00Z)"
check "…GitHub not answering for the suites -> could not verify (rc 75), never a pass" eval '[ "$RC" -eq 75 ]'
gate "$(at_comment "$(meta 'Adds the sync.' '[{"path":"worker/x.ts"}]')" 2026-01-03T00:00:00Z)"
check "outage: a code PR whose PASS cannot be checked (GitHub not answering) -> could not verify (rc 75), never a pass" eval '[ "$RC" -eq 75 ]'
rm -f "$W/suites-down"; pushed "$PR_HEAD" 2026-01-02T00:05:00Z
gate "$(jq '.comments[0] |= del(.createdAt)' <<<"$(at_comment "$(meta 'Tweaks the page.' "$SITE")" x)")"
check "…a comment whose time is missing -> refused STALE_PASS (unknown is never a pass)" eval '[ "$RC" -eq 1 ] && grep -q "STALE_PASS" <<<"$MSG"'
stale_pr; GIT_COMMITTER_DATE=2026-01-02T00:00:00Z git -C "$W/r" commit -q --amend --no-edit; git -C "$W/r" checkout -q main
echo two > "$W/r/other.txt"; git -C "$W/r" add other.txt; git -C "$W/r" commit -qm "main moves on"; git -C "$W/r" push -q origin HEAD:main
OWN="$(git -C "$W/r" rev-parse pr)"; pushed "$OWN" 2026-01-02T00:05:00Z
git -C "$W/r" checkout -q pr; git -C "$W/r" merge -q --no-edit main; publish_pr
pushed "$PR_HEAD" 2026-01-04T00:00:00Z   # the main merge reached GitHub after the comment: it is not the PR's own work
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-03T00:00:00Z)"
check "…a main merge after that comment -> still allowed (the PASS survives updates)" [ "$RC" -eq 0 ]

echo "=== ship-ready-baseline (row 18 hook) ==="
eval "$BLOCK"
check "red baseline -> refused" baseline_red '[{"name":"ship-ready-baseline","bucket":"fail"},{"name":"test","bucket":"pass"}]'
check "a caller's job name (\"Ship ready / ship-ready-baseline\") is the same check" baseline_red '[{"name":"Ship ready / ship-ready-baseline","bucket":"cancel"}]'
check "green baseline -> not red" eval '! baseline_red "[{\"name\":\"ship-ready-baseline\",\"bucket\":\"pass\"}]"'
check "no baseline check (no repo has one yet) -> nothing to read" eval '! baseline_red "[{\"name\":\"test\",\"bucket\":\"pass\"}]"'

echo "=== patch history ==="
repo; LINE=2 TEXT='  return x + 9;' commit "fix(sync): alpha adds nine (#41)"; pr_head 2 '  return x + 10;'
gate "$(meta "Changes alpha.")"
check "PR in a function a fix changed 3 days ago, no line -> refused" eval '[ "$RC" -eq 1 ] && one_line && grep -q "Patch or rebuild: " <<<"$MSG" && grep -q "#41" <<<"$MSG"'
gate "$(meta "Patch or rebuild: <why a patch and not a rebuild of that design> (#41)")"
check "…the placeholder copied as-is -> refused" [ "$RC" -eq 1 ]
gate "$(meta "Patch or rebuild: alpha is one line of arithmetic and #41 set the wrong constant, nothing to rebuild")"
check "…with a line naming #41 and why -> allowed" [ "$RC" -eq 0 ]
gate "$(meta "Patch or rebuild: alpha is one line of arithmetic and #4 set the wrong constant")"
check "…a line naming another fix (#4, not #41) -> refused" [ "$RC" -eq 1 ]
gate "$(meta "Changes alpha.")"; ask="$(sed -nE 's/^ +add: //p' <<<"$MSG" | head -1)"; refs="$(grep -oE 'and names #[0-9]+( #[0-9]+)*' <<<"$MSG" | sed 's/^and names //')"
check "…the refusal gives the template's line to add and names the fix (#41)" eval 'grep -q "^Patch or rebuild: <why a patch" <<<"$ask" && [ "$refs" = "#41" ]'
ask="${ask/<why a patch and not a rebuild of that design, 5+ words>/alpha is one line of arithmetic and the fix set the wrong constant}"; ask="${ask/<each fix ref land names, like #41>/$refs}"
gate "$(jq --arg c "$ask" '.comments = [{authorAssociation: "OWNER", body: $c}]' <<<"$(meta "Changes alpha.")")"
check "…following the refusal's own words (an owner-account comment) -> allowed (R4)" [ "$RC" -eq 0 ]
gate "$(jq --arg c "Patch or rebuild: alpha is one line of arithmetic and #41 set the wrong constant" '.comments = [{authorAssociation: "OWNER", body: $c}, {authorAssociation: "OWNER", body: "VERDICT: fail\n- F2 other"}, {authorAssociation: "OWNER", body: $p}]' --arg p "$GOOD" <<<"$(meta "Changes alpha.")")"
check "…a later fail verdict does not void the builder's Patch line (it is not a verdict; the PASS after it stands)" [ "$RC" -eq 0 ]
gate "$(jq --arg c "Patch or rebuild: alpha is one line of arithmetic and #41 set the wrong constant" '.comments = [{authorAssociation: "NONE", body: $c}]' <<<"$(meta "Changes alpha.")")"
check "…the same line from a non-owner account -> refused" [ "$RC" -eq 1 ]
repo; LINE=6 TEXT='  return y * 3;' commit "fix(sync): beta triples (#42)"; pr_head 2 '  return x + 10;'
gate "$(meta "Changes alpha.")"
check "a fix in ANOTHER function (beta) asks nothing (clean PR, rc 0)" [ "$RC" -eq 0 ]
repo; LINE=2 TEXT='  return x + 9;' commit "fix(sync): alpha adds nine (#40)" 2026-01-05T00:00:00; pr_head 2 '  return x + 10;'
gate "$(meta "Changes alpha.")"
check "a fix older than 30 days asks nothing (rc 0)" [ "$RC" -eq 0 ]
repo; LINE=2 TEXT='  return x + 9;' commit "alpha adds nine, as asked (#43)"; pr_head 2 '  return x + 10;'
gate "$(meta "Changes alpha.")"
check "a change that was not a fix asks nothing (rc 0)" [ "$RC" -eq 0 ]

echo "=== mutation proof: a PR that changes code ==="
repo; pr_head 2 '  return x + 2;'
gate "$(NOPROOF=1 meta "Changes alpha.")"
check "code change, no mutation list -> refused in one line" eval '[ "$RC" -eq 1 ] && one_line && grep -q "## Mutation proof" <<<"$MSG"'
gate "$(NOPROOF=1 meta "Changes alpha."$'\n\n''## Mutations (each one made the named tests fail)'$'\n''| Mutation | Test that failed |'$'\n''|---|---|'$'\n''| <mutation> | <test> |')"
check "…a header row and a placeholder row are not proof -> refused" [ "$RC" -eq 1 ]
gate "$(NOPROOF=1 meta "Changes alpha."$'\n\n''## Mutations'$'\n''| Mutation | Test that failed |'$'\n''|---|---|'$'\n''| alpha back to +1 | tests/sync.test.ts \"adds two\" |')"
check "…a filled mutation table -> allowed" [ "$RC" -eq 0 ]
gate "$(jq --arg c $'Mutation proof:\n- undo alpha fix: tests/sync.test.ts goes red' '.comments = [{authorAssociation: "OWNER", body: $c}]' <<<"$(NOPROOF=1 meta "Changes alpha.")")"
check "…a list in an owner-account comment -> allowed" [ "$RC" -eq 0 ]
gate "$(jq --arg c $'Mutation proof:\n- undo alpha fix: tests/sync.test.ts goes red' '.comments = [{authorAssociation: "NONE", body: $c}]' <<<"$(NOPROOF=1 meta "Changes alpha.")")"
check "…the same list from a non-owner account -> refused" [ "$RC" -eq 1 ]
gate "$(NOPROOF=1 meta "Mutation proof: none — renames a local variable, no behaviour changes at all")"
check "…a reasoned none (6+ words) -> allowed" [ "$RC" -eq 0 ]
gate "$(NOPROOF=1 meta "Mutation proof: none")"
check "…a bare none -> refused" [ "$RC" -eq 1 ]
echo "=== mutation proof by structure, on real PR bodies (review of #141: 3 of 8 real proofs were refused) ==="
for f in seq-bin-139 seq-bin-138 boss-os-518; do
  gate "$(NOPROOF=1 meta "$(cat "$HERE/tests/fixtures/proof/$f.md")")"
  check "the real $f body, as its builder wrote it -> allowed" [ "$RC" -eq 0 ]
done
proof() { gate "$(NOPROOF=1 meta "Changes alpha."$'\n\n'"$1")"; }
proof $'## Mutation proof\n| Fix undone | Red tests |\n|---|---|'
check "a header-only table (any header words) -> refused" [ "$RC" -eq 1 ]
proof $'## Mutation proof\n| Mutation | Red test |\n|---|---|\n| | |'
check "a header and an empty row -> refused" [ "$RC" -eq 1 ]
proof $'## Mutations\nNo tests exist.'
check "'No tests exist.' -> refused" [ "$RC" -eq 1 ]
proof $'## Mutation proof\n- [ ] each fix undone and its test seen red\n- cap check reverted: tests/cap.sh case 3 went red'
check "an unticked [ ] box -> refused, even beside a real row" [ "$RC" -eq 1 ]
proof 'Mutation proof: none — I did not have time'
check "'none — I did not have time' -> refused" [ "$RC" -eq 1 ]
proof $'**Mutations**\n- cap check reverted: tests/cap.sh case 3 went red'
check "a bold **Mutations** opener -> allowed" [ "$RC" -eq 0 ]
proof $'## Self-proof\n- cap check reverted: tests/cap.sh case 3 went red'
check "a ## Self-proof heading -> allowed" [ "$RC" -eq 0 ]
proof 'Mutation proof: reverted the cap, e2e/login.spec.ts went red'
check "the proof on the heading line itself -> allowed" [ "$RC" -eq 0 ]
proof $'## Mutation proof\n| Mutation | Red |\n|---|---|\n| `<=` to `<` in the cap | cap case 3 went red |'
check "a row containing < -> allowed" [ "$RC" -eq 0 ]
proof 'Mutation proof: none — a change to none of the logic paths, comments only'
check "a reasoned none with a later 'none' in it -> allowed (the none sub is not greedy)" [ "$RC" -eq 0 ]
proof $'## Mutation proof\nShip-ready: PASS — reviewer session_01REVIEW looked at the diff and its tests; Engineering: PASS'
check "a reviewer's PASS line under the heading is not a proof row -> refused" [ "$RC" -eq 1 ]
gate "$(FAST=1 NOPROOF=1 meta "Docs only." '[{"path":"README.md"},{"path":"tests/x.test.ts"}]')"
check "docs and tests only need no proof (rc 0)" [ "$RC" -eq 0 ]
gate "$(NOPROOF=1 meta 'Owner override: "ship it, land it now" (22 Nov 2026 12:00 CT)')"
check "her Owner override skips it (rc 0)" [ "$RC" -eq 0 ]
echo "=== protected: a noelle/ branch or a change under .github/ needs a separate reviewer's comment for its head (#175) ==="
noelle() { jq -c '.headRefName = "noelle/work"'; }
owner_says() { jq -c --arg c "$1" --arg who "${2:-OWNER}" '.comments = ((.comments // []) + [{authorAssociation: $who, body: $c}])'; }
code_is() { grep -qE "^  [0-9]+\. \[$1\] " <<<"$MSG"; }
repo; pr_head 2 '  return x + 2;'
BYPASSED="$(FAST=1 NOREVIEW=1 meta "$GOOD"$'\nOwner override: "ship it right now" (27 Nov 2026 19:30 CT)' "$SITE")"
gate "$BYPASSED"
check "control: the same body on a normal PR lands on its Owner override (rc 0)" [ "$RC" -eq 0 ]
gate "$(noelle <<<"$BYPASSED")"
check "abuse: a noelle/ PR whose body carries a PASS and an Owner override -> refused REVIEW_REQUIRED (rc 1)" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
gate "$(FAST=1 NOREVIEW=1 meta "$GOOD" "$SITE" | noelle)"
check "abuse: a noelle/ PR's own body PASS, no override -> refused REVIEW_REQUIRED (the body is never a review)" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
gate "$(noelle <<<"$BYPASSED" | owner_says "$GOOD" CONTRIBUTOR)"
check "abuse: the PASS in a comment by a non-owner account -> refused" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
gate "$(noelle <<<"$BYPASSED" | owner_says 'Ship-ready: PASS — builder looked at the diff at @HEAD@; Engineering: PASS')"
check "abuse: an owner comment signed by the builder -> refused" eval '[ "$RC" -eq 1 ] && grep -q "signed by the builder" <<<"$MSG"'
gate "$(noelle <<<"$BYPASSED" | owner_says "$GOOD")"
check "a separate reviewer's owner comment naming the head -> allowed (rc 0)" [ "$RC" -eq 0 ]
gate "$(noelle <<<"$BYPASSED" | owner_says "$GOOD" | owner_says $'VERDICT: fail\n- F1 the gate is open')"
check "…a later VERDICT: fail comment voids it -> refused" [ "$RC" -eq 1 ]
gate "$(FAST=1 NOPROOF=1 meta 'Docs only.'$'\nOwner override: "ship it right now" (27 Nov 2026 19:30 CT)' '[{"path":"README.md"}]' | noelle)"
check "edge: a noelle/ PR with no .github change and docs only -> still needs the reviewer (REVIEW_REQUIRED)" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
WF='[{"path":".github/workflows/ci.yml"}]'
gate "$(FAST=1 NOREVIEW=1 NOPROOF=1 meta "$GOOD"$'\nOwner override: "ship it right now" (27 Nov 2026 19:30 CT)' "$WF")"
check "a .github/ change with a body PASS and an Owner override -> refused REVIEW_REQUIRED" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
check "…the refusal says to post it as an owner-account comment, with the line to add" eval 'one_line && grep -q "as a PR comment by the repo.s owner account" <<<"$MSG"'
gate "$(FAST=1 NOREVIEW=1 NOPROOF=1 meta 'Bumps CI.' "$WF" | owner_says "$GOOD")"
check "…with a separate reviewer's owner comment for this head -> allowed (rc 0)" [ "$RC" -eq 0 ]
gate "$(FAST=1 NOREVIEW=1 NOPROOF=1 meta "$GOOD"$'\nOwner override: "ship it right now" (27 Nov 2026 19:30 CT)' '[{"path":"ci/renamed.yml"}]' | jq -c '.from_git_github = true')"
check "a .github file renamed out (GitHub lists only the new path; the exact diff saw .github) -> refused REVIEW_REQUIRED" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
gate "$(FAST=1 NOREVIEW=1 NOPROOF=1 meta "$GOOD"$'\nOwner override: "ship it right now" (27 Nov 2026 19:30 CT)' '[{"path":"README.md"}]' | jq -c 'del(.from_git_github)')"
check "outage: a PR view whose exact diff was never read counts as protected -> refused, never bypassed" eval '[ "$RC" -eq 1 ] && code_is REVIEW_REQUIRED'
# STALE: a protected PASS names the current head itself; main's softer rules (a main merge after the PASS, a sha-less
# PASS posted after the head reached GitHub) do not apply.
stale_pr; git -C "$W/r" checkout -q main; echo two > "$W/r/other.txt"; git -C "$W/r" add other.txt; git -C "$W/r" commit -qm "main moves on"
git -C "$W/r" push -q origin HEAD:main; git -C "$W/r" checkout -q pr; git -C "$W/r" merge -q --no-edit main; publish_pr
gate "$(meta 'Tweaks the page.' "$SITE" | owner_says "$(passed_at)")"
check "control: a normal PR's PASS on the commit before a main merge still counts (rc 0)" [ "$RC" -eq 0 ]
gate "$(meta 'Tweaks the page.' "$SITE" | noelle | owner_says "$(passed_at)")"
check "abuse: a protected PR's PASS naming an older commit -> refused STALE_PASS, naming the current head" eval '[ "$RC" -eq 1 ] && code_is STALE_PASS && grep -q "an older commit" <<<"$MSG" && grep -q "naming $(sha_name "$PR_HEAD")" <<<"$MSG"'
stale_pr; publish_pr; pushed "$PR_HEAD" 2026-01-02T00:05:00Z
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE")" 2026-01-03T00:00:00Z)"
check "control: a normal PR's sha-less owner PASS posted after its head arrived counts (rc 0)" [ "$RC" -eq 0 ]
gate "$(at_comment "$(meta 'Tweaks the page.' "$SITE" | noelle)" 2026-01-03T00:00:00Z)"
check "a protected PR's sha-less PASS -> refused STALE_PASS (it must name the head)" eval '[ "$RC" -eq 1 ] && code_is STALE_PASS && grep -q "no commit on this PR" <<<"$MSG"'
echo "=== protected: --owner (body_gates' 4th argument) never clears it, and its forms/outcome leniency is off ==="
bg() { # PR-view JSON, owner flag -> BRC, BP: body_gates' problems
  BP="$(cd "$W/r" && PATH="$W/bin:$PATH" bash -c "$BLOCK"$'\n''body_gates 9 "$1" "$2" "$3"; rc=$?; printf "%s" "$BODY_PROBLEMS"; exit "$rc"' _ "$PR_HEAD" "${1//@HEAD@/$(sha_name "$PR_HEAD")}" "$2")"; BRC=$?
}
repo; pr_head 2 '  return x + 2;'
bg "$(FAST=1 NOREVIEW=1 meta 'Bumps CI.' "$WF" | jq -c '.body += "\nOutcome: none — a fixture change that runs nothing\n\n## Not built\nNothing cut."')" 1
check "a .github/ change under --owner: REVIEW_REQUIRED stands (rc 1)" eval '[ "$BRC" -eq 1 ] && grep -q "^REVIEW_REQUIRED" <<<"$BP"'
bg "$(FAST=1 NOREVIEW=1 meta 'Bumps CI.' "$WF" | owner_says "$GOOD")" 1
check "…with no Outcome or Not built line, --owner does not record them UNDECLARED: they are asked for" eval '[ "$BRC" -eq 1 ] && grep -q "^NOT_BUILT_UNDECLARED" <<<"$BP" && ! grep -q "^REVIEW_REQUIRED" <<<"$BP"'
bg "$(FAST=1 NOREVIEW=1 meta 'Fixes a page.' "$SITE" | jq -c '.body += "\nOutcome: none — a fixture change that runs nothing"')" 1
check "control: a normal PR under --owner: no problems (rc 0)" [ "$BRC" -eq 0 ]
echo "=== protected: the exact git diff of the head (verified_workflow_paths), deletes and renames included ==="
vwp() { # head -> VRC, VW (from_git_github, or empty)
  VW="$(cd "$W/r" && PATH="$W/bin:$PATH" bash -c "$BLOCK"$'\n''verified_workflow_paths 9 "$1" <<<"{\"files\":[]}" | jq -r .from_git_github; exit "${PIPESTATUS[0]}"' _ "$1")"; VRC=$?
}
wf_pr() { # git command run in the clone for the PR's one commit -> PR_HEAD (main holds .github/workflows/ci.yml)
  repo; mkdir -p "$W/r/.github/workflows"; echo 'name: ci' > "$W/r/.github/workflows/ci.yml"; git -C "$W/r" add -A; git -C "$W/r" commit -qm "ci"
  git -C "$W/r" push -q origin HEAD:main; git -C "$W/r" fetch -q origin
  (cd "$W/r" && eval "$1") && git -C "$W/r" commit -qam "the PR" && PR_HEAD="$(git -C "$W/r" rev-parse HEAD)"
  git -C "$W/r" push -q origin "HEAD:refs/pull/9/head"; git -C "$W/r" reset -q --hard origin/main
}
wf_pr 'git rm -q .github/workflows/ci.yml'; vwp "$PR_HEAD"
check "a .github file deleted -> from_git_github true" eval '[ "$VRC" -eq 0 ] && [ "$VW" = true ]'
wf_pr 'mkdir -p ci && git mv .github/workflows/ci.yml ci/ci.yml'; vwp "$PR_HEAD"
check "a .github file renamed out -> from_git_github true" eval '[ "$VRC" -eq 0 ] && [ "$VW" = true ]'
wf_pr 'echo "  on: push" >> .github/workflows/ci.yml'; vwp "$PR_HEAD"
check "a .github file edited -> from_git_github true" eval '[ "$VRC" -eq 0 ] && [ "$VW" = true ]'
wf_pr 'echo more >> site/index.html'; vwp "$PR_HEAD"
check "edge: no .github change (main has one) -> from_git_github false" eval '[ "$VRC" -eq 0 ] && [ "$VW" = false ]'
vwp 0123456789abcdef0123456789abcdef01234567
check "outage: a head git cannot fetch -> rc 75, never false" eval '[ "$VRC" -eq 75 ] && [ "$VW" != false ]'
git -C "$W/r" remote set-url origin "$W/no-such-origin.git"; vwp "$PR_HEAD"
check "outage: origin cannot be fetched -> rc 75, never false" eval '[ "$VRC" -eq 75 ] && [ "$VW" != false ]'
git -C "$W/r" remote set-url origin "$W/origin.git"
}

run_cases
echo "=== the shipped live-repos.json (land's list of launched repos) ==="
check "it parses as land reads it: a non-empty list of distinct seq23/<repo> strings, seq-bin itself on it" \
  jq -e '(.live | type == "array" and length > 0 and all(.[]; type == "string" and test("^seq23/[A-Za-z0-9_.-]+$")))
         and any(.live[]; . == "seq23/seq-bin") and ((.live | map(ascii_downcase) | unique | length) == (.live | length))' "$HERE/live-repos.json"
echo "test-land-gates: $passes passed, $fails failed"
[ "$fails" -eq 0 ] || exit 1

# --- negative proofs: a gate that cannot refuse must fail this file -------------------------------
[ -n "${LAND_UNDER_TEST:-}" ] && exit 0
neg() { # label, sed expression applied to land
  sed "$2" "$HERE/land" > "$W/land-broken"
  if LAND_UNDER_TEST="$W/land-broken" bash "$0" >/dev/null 2>&1; then echo "  FAIL negative proof: $1 still passes"; exit 1; fi
  echo "  ok   negative proof: $1 fails this test"
}
neg "a protected test that never says protected" '/^trusted_review_required()/a\
  return 1'
neg "a protected PR whose body still counts as a review" 's/--argjson strict "\$strict" <<</--argjson strict false <<</'
neg "her bypass applied to a protected PR" '/^pr_owner_override()/,/^}/s/^  trusted_review_required <<<"\$json" \&\& return 1$/  :/'
neg "a protected PASS that need not name the current head" 's/if \[ "\$sha" != "\$3" \] \&\& trusted_review_required/if false \&\& trusted_review_required/'
neg "an exact diff that git could not read counted as no .github change" '/^verified_workflow_paths()/,/^}/s/have_head "\$1" "\$2" >\/dev\/null || return 75/have_head "$1" "$2" >\/dev\/null || { jq -c ".from_git_github = false" <<<"$meta"; return 0; }/'
neg "a deleted .github file missed by the exact diff" 's/git diff --name-only --no-renames "\$base" "\$2" -- .github/git diff --name-only --no-renames --diff-filter=AM "$base" "$2" -- .github/'
neg "--owner clearing protection inside body_gates" 's/^  if ! trusted_review_required <<<"\$3"; then { \[ -n "\${4:-}" \] || pr_owner_override <<<"\$3"; } \&\& bypass=1; fi$/  { [ -n "${4:-}" ] || pr_owner_override <<<"$3"; } \&\& bypass=1/'
neg "a signoff that never asks who signed" '/^is_builder()/a\
  return 1'
neg "a patch check that never reads history" '/^patch_fixes()/a\
  return 0'
neg "a Ship-ready PASS that never asks about engineering" '/^covers_engineering()/a\
  return 0'
neg "a PASS that is never checked against its commit" '/^fresh_pass()/a\
  return 0'
neg "main's own commits counted as the PR's new code" 's/ --name-only "\$1\.\.\$2" --not origin\/main$/ --name-only "$1..$2"/; s/git rev-list --merges "\$1\.\.\$2" --not origin\/main/git rev-list --merges "$1..$2"/; s/--cc --name-only/-m --name-only/'
neg "a quality gate that never asks for a review" 's/^  if \[ -n "\$launch" \]; then cls=.*$/  return 0/'
neg "a mutation gate that never reads the body" '/^proof_listed()/a\
  return 0'
echo "test-land-gates: every gate refuses what it should and lets through what it should"
