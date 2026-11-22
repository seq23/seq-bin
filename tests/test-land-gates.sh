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
# Negative proofs at the foot: a block whose signoff ignores the builder, and one whose patch check
# never reads history, both fail these cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAND="${LAND_UNDER_TEST:-$HERE/land}"
export LAND_SURFACES="$HERE/land-surfaces.json"
BLOCK="$(sed -n '/^# --- gates begin/,/^# --- gates end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: no gates block in $LAND"; exit 1; }
grep -q 'GATE_MSG="$(gate_pr "$PR" "$HEAD" "$PRMETA")"' "$LAND" || { echo "FAIL: land no longer calls gate_pr before merging"; exit 1; }
grep -q 'BASELINE_RED="$(baseline_red "$CHECKS")" && die' "$LAND" || { echo "FAIL: land no longer reads the ship-ready-baseline check"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
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
  local b="$1"; [ -n "${NOPROOF:-}" ] || b="$b"$'\n\n''## Mutation proof'$'\n''| alpha +1 back to +0 | tests/sync.test.ts alpha goes red |'
  jq -n --arg b "$b" --argjson f "$f" \
    '{files: $f, body: $b, author: {login: "seq23"}, commits: [{authors: [{name: "builder", email: "builder@example.test", login: ""}],
      messageBody: "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01BUILDER"}]}'
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
short() { local n="${2:-7}"; while [ "$n" -lt 40 ] && [[ ! "${1:0:$n}" =~ [a-f] ]]; do n=$((n + 1)); done; printf '%s' "${1:0:$n}"; }
gate() { # PR-view JSON -> RC, MSG (run in the repo, through the block, in a subshell)
  MSG="$(cd "$W/r" && PATH="$W/bin:$PATH" bash -c "$BLOCK"$'\n''gate_pr 9 "$1" "$2"' _ "$PR_HEAD" "${1//@HEAD@/$(short "$PR_HEAD" 8)}")"; RC=$?
  [ -z "${GATES_TEST_SHOW:-}" ] || echo "    | rc $RC: $MSG"
}
one_line() { [ "$(grep -c . <<<"$MSG")" -eq 1 ]; }
SITE='[{"path":"site/index.html"}]'
# @HEAD@ is the PR head's short sha, filled in by gate(): a PASS names the commit it looked at (STALE_PASS).
GOOD='Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px and 1280 px at @HEAD@; Engineering: PASS'

run_cases() {
echo "=== ship-ready: a PR that changes what people see ==="
repo; pr_head 2 '  return x + 2;'
gate "$(meta 'Tweaks the page.' "$SITE")"
check "no PASS line -> refused (rc 1)" [ "$RC" -eq 1 ]
check "…in one plain line that says what to add" eval 'one_line && grep -q "Ship-ready: PASS — " <<<"$MSG"'
for who in builder builder@example.test 'Claude Opus 5.5' seq23 'me' 'agent session_01BUILDER' '<reviewer>'; do
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
gate "$(meta "" '[{"path":"worker/x.ts"},{"path":"tests/site/x.test.tsx"},{"path":"README.md"},{"path":"docs/a.html"}]')"
check "server code, tests and docs need no line (rc 0)" [ "$RC" -eq 0 ]

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
passed_at() { printf 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px at %s; Engineering: PASS' "$(short "$PASSED" 9)"; }
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
check "a PASS that names no commit -> refused STALE_PASS, with the head to name" eval '[ "$RC" -eq 1 ] && one_line && grep -q "STALE_PASS" <<<"$MSG" && grep -q "names no commit" <<<"$MSG" && grep -q " at ${PR_HEAD:0:8}; Engineering: PASS" <<<"$MSG"'
gate "$(meta 'Ship-ready: PASS — hostile-review agent session_01REVIEW looked at the home page at 390 px at deadbeef1; Engineering: PASS' "$SITE")"
check "a PASS naming a commit not on the PR -> refused STALE_PASS" eval '[ "$RC" -eq 1 ] && grep -q "names no commit" <<<"$MSG"'
# Review F1 of #137: a re-check line names the old commit first ("the diff A..B", "diff since A … at B").
stale_pr; echo '<h1>fixed after the fail</h1>' > "$W/r/site/index.html"; git -C "$W/r" commit -qam "the fix"; publish_pr
gate "$(meta "Ship-ready: PASS — re-check agent session_01RECHECK looked at the diff $(short "$PASSED" 8)..$(short "$PR_HEAD" 8) at 390 px; Engineering: PASS" "$SITE")"
check "a re-check PASS on 'the diff <old>..<head>' -> allowed (the newest commit it names)" [ "$RC" -eq 0 ]
gate "$(meta "Ship-ready: PASS — re-check agent session_01RECHECK looked at the diff since $(short "$PASSED" 8), tests at $(short "$PR_HEAD" 8); Engineering: PASS" "$SITE")"
check "a re-check PASS on 'diff since <old> … at <head>' -> allowed" [ "$RC" -eq 0 ]
gate "$(meta "Ship-ready: PASS — re-check agent session_01RECHECK looked at the diff since $(short "$PASSED" 8); Engineering: PASS" "$SITE")"
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
gate "$(meta "Changes alpha.")"; ask="$(sed -E 's/.*the line  //' <<<"$MSG")"
gate "$(jq --arg c "${ask/<why a patch and not a rebuild of that design>/alpha is one line of arithmetic and the fix set the wrong constant}" '.comments = [{authorAssociation: "OWNER", body: $c}]' <<<"$(meta "Changes alpha.")")"
check "…following the refusal's own words (an owner-account comment) -> allowed (R4)" [ "$RC" -eq 0 ]
gate "$(jq --arg c "Patch or rebuild: alpha is one line of arithmetic and #41 set the wrong constant" '.comments = [{authorAssociation: "OWNER", body: $c}, {authorAssociation: "OWNER", body: "VERDICT: fail\n- F2 other"}]' <<<"$(meta "Changes alpha.")")"
check "…a later fail verdict does not void the builder's Patch line (it is not a verdict)" [ "$RC" -eq 0 ]
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
gate "$(NOPROOF=1 meta "Docs only." '[{"path":"README.md"},{"path":"tests/x.test.ts"}]')"
check "docs and tests only need no proof (rc 0)" [ "$RC" -eq 0 ]
gate "$(NOPROOF=1 meta 'Owner override: "ship it, land it now" (22 Nov 2026 12:00 CT)')"
check "her Owner override skips it (rc 0)" [ "$RC" -eq 0 ]
}

run_cases
echo "test-land-gates: $passes passed, $fails failed"
[ "$fails" -eq 0 ] || exit 1

# --- negative proofs: a gate that cannot refuse must fail this file -------------------------------
[ -n "${LAND_UNDER_TEST:-}" ] && exit 0
neg() { # label, sed expression applied to land
  sed "$2" "$HERE/land" > "$W/land-broken"
  if LAND_UNDER_TEST="$W/land-broken" bash "$0" >/dev/null 2>&1; then echo "  FAIL negative proof: $1 still passes"; exit 1; fi
  echo "  ok   negative proof: $1 fails this test"
}
neg "a signoff that never asks who signed" '/^is_builder()/a\
  return 1'
neg "a patch check that never reads history" '/^patch_fixes()/a\
  return 0'
neg "a Ship-ready PASS that never asks about engineering" '/^covers_engineering()/a\
  return 0'
neg "a PASS that is never checked against its commit" '/^fresh_pass()/a\
  return 0'
neg "main's own commits counted as the PR's new code" 's/ --name-only "\$1\.\.\$2" --not origin\/main$/ --name-only "$1..$2"/; s/git rev-list --merges "\$1\.\.\$2" --not origin\/main/git rev-list --merges "$1..$2"/; s/--cc --name-only/-m --name-only/'
neg "a quality gate that sees no surfaces" 's/^  \[ -n "\$files" \] || return 0$/  return 0/'
neg "a mutation gate that never reads the body" '/^proof_listed()/a\
  return 0'
echo "test-land-gates: every gate refuses what it should and lets through what it should"
