#!/bin/bash
# post-land-check against a fake gh (a comments store per PR) and a fake ai-run (posts the scenario's comment).
# Proves: unreadable HANDOFF is exit 2; nothing due is 0; a form PASS turns its line DONE with the link; a form FAIL
# turns it FAIL, raises a banner and files an issue; no verdict comment (or one from another account, or one older
# than the run) leaves the line DUE and exits 1; every ENG-CHECK runs in ONE ai-run and each PR gets its own verdict;
# --now runs only that PR's FORM-PROOF; a held lock skips the line; ai-run never eats the remaining lines on stdin.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; PLC="${PLC_UNDER_TEST:-$HERE/post-land-check}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/store"
cat > "$W/bin/gh" <<'GH'
#!/bin/bash
S="$PLC_STORE"
case "$1 $2" in
  "api user") echo "${FAKE_ME:-me}";;
  "api --paginate") f="$S/$(echo "$3" | tr '/' '_').json"; [ -f "$f" ] && cat "$f" || echo '[]';;
  "issue create") echo "$*" >> "$S/issues";;
  *) echo "fake gh: $*" >&2; exit 1;;
esac
GH
cat > "$W/bin/ai-run" <<'AI'
#!/bin/bash
# Reads the prompt; for each "owner/repo#N" in it, posts the scenario's verdict as a comment.
S="$PLC_STORE"; echo x >> "$S/ai-calls"
prompt="${@: -1}"
# Swallow stdin like claude -p would (bounded, so a mutation fails the test instead of hanging it).
timeout 5 cat >/dev/null 2>&1 || true
for key in $(grep -oE '[a-z0-9-]+/[a-z0-9-]+#[0-9]+' <<<"$prompt" | sort -u); do
  repo="${key%#*}"; pr="${key##*#}"; f="$S/$(echo "repos/$repo/issues/$pr/comments" | tr '/' '_').json"
  v="$(eval echo "\${VERDICT_${pr}:-}")"; [ -n "$v" ] || continue
  who="${COMMENT_USER:-me}"; when="${COMMENT_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
  jq -n --arg b "$v
details" --arg u "$who" --arg t "$when" --arg url "https://github.com/$repo/pull/$pr#c" \
    '[{body: $b, user: {login: $u}, created_at: $t, html_url: $url}]' > "$f"
done
AI
chmod +x "$W/bin/gh" "$W/bin/ai-run"
export PATH="$W/bin:$PATH" PLC_STORE="$W/store" POST_LAND_AI_RUN="$W/bin/ai-run" POST_LAND_LOG="$W/log" \
  POST_LAND_HANDOFF="$W/HANDOFF.md" POST_LAND_LOCKS="$W/locks" POST_LAND_NOTIFY="$W/bin/notify" POST_LAND_TASKS="$W/tasks"
printf '#!/bin/bash\necho "$1" >> "%s/store/banners"\n' "$W" > "$W/bin/notify"; chmod +x "$W/bin/notify"
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi; }
reset() { rm -rf "$W/store" "$W/locks" "$W/tasks"; mkdir -p "$W/store"; unset VERDICT_1 VERDICT_2 VERDICT_3 VERDICT_4 COMMENT_USER COMMENT_AT; }
handoff() { printf '# H\n<!-- TODAY:START -->\n<!-- JOBS:END -->\n%s\n<!-- TODAY:END -->\n' "$1" > "$W/HANDOFF.md"; }
F1='- FORM-PROOF DUE o/site#1 abc123 — forms: contact form; deployed 23 Nov 2026 10:00 CT; a marked TEST submission on production proves each one'
E2='- ENG-CHECK DUE o/app#2 def456 — landed on green CI with no reviewer'"'"'s PASS (Fast PRs) 23 Nov 2026 10:00 CT; a fresh reviewer checks'
E3='- ENG-CHECK DUE o/app#3 0a0b0c — landed under her bypass 23 Nov 2026 11:00 CT; a fresh reviewer checks'
run() { "$PLC" "$@" </dev/null >/dev/null 2>&1; echo $?; }

reset; rm -f "$W/HANDOFF.md"
check "unreadable HANDOFF is exit 2" [ "$(run)" = 2 ]
reset; handoff "- something else"
check "nothing due is exit 0" [ "$(run)" = 0 ]
check "nothing due calls no model" [ ! -f "$W/store/ai-calls" ]

reset; handoff "$F1"; export VERDICT_1="Form proof (production): PASS — contact form TEST 200, stored"
check "form PASS exits 0" [ "$(run)" = 0 ]
check "form PASS turns the line DONE with the link" grep -q '^- FORM-PROOF DONE o/site#1 abc123 .* → https://github.com/o/site/pull/1#c$' "$W/HANDOFF.md"

reset; handoff "$F1"; export VERDICT_1="**Form proof (production): FAIL — 500 from /api/contact**"
check "form FAIL is a result (exit 0)" [ "$(run)" = 0 ]
check "form FAIL turns the line FAIL" grep -q '^- FORM-PROOF FAIL o/site#1 ' "$W/HANDOFF.md"
check "form FAIL files an issue on that repo" grep -q 'issue create --repo o/site' "$W/store/issues"
check "form FAIL raises a banner" grep -q 'FAILED' "$W/store/banners"

reset; handoff "$F1"
check "no verdict comment is exit 1" [ "$(run)" = 1 ]
check "no verdict leaves the line DUE" grep -q '^- FORM-PROOF DUE o/site#1 ' "$W/HANDOFF.md"

reset; handoff "$F1"; export VERDICT_1="Form proof (production): PASS — x" COMMENT_USER=someone-else
check "another account's comment never counts" [ "$(run)" = 1 ]
reset; handoff "$F1"; export VERDICT_1="Form proof (production): PASS — x" COMMENT_AT="2020-01-01T00:00:00Z"
check "a comment older than the run never counts" [ "$(run)" = 1 ]

F4='- FORM-PROOF DUE o/site#4 fff000 — forms: booking form; deployed 23 Nov 2026 10:05 CT; a marked TEST submission on production proves each one'
reset; handoff "$F1
$F4
$E2
$E3"; export VERDICT_4="Form proof (production): PASS — booking ok" VERDICT_1="Form proof (production): PASS — ok" VERDICT_2="Engineering check: PASS — read the diff" VERDICT_3="Engineering check: FAIL — fail 4: old path kept"
check "batch exits 0" [ "$(run)" = 0 ]
check "one run per form + ONE engineering run" [ "$(wc -l < "$W/store/ai-calls" | tr -d ' ')" = 3 ]
check "eng PASS is DONE" grep -q '^- ENG-CHECK DONE o/app#2 ' "$W/HANDOFF.md"
check "eng FAIL is FAIL" grep -q '^- ENG-CHECK FAIL o/app#3 ' "$W/HANDOFF.md"
check "the second form line, after an ai-run that reads stdin, was still checked" grep -q '^- FORM-PROOF DONE o/site#4 ' "$W/HANDOFF.md"
check "an eng FAIL files no issue" [ ! -f "$W/store/issues" ]
check "an eng FAIL writes its fix sheet: STATUS TODO with the verdict link" grep -q '^STATUS: TODO .*o/app#3.*https://github.com/o/app/pull/3#c$' "$W/tasks/engfix-app-3.md"
check "the fix sheet names the land that closes it" grep -q 'land-after <fix pr> --task engfix-app-3 --repo o/app' "$W/tasks/engfix-app-3.md"
check "an eng PASS writes no fix sheet" [ ! -e "$W/tasks/engfix-app-2.md" ]
check "the FAIL banner points at the fix sheet" grep -q 'fix sheet' "$W/store/banners"
echo "STATUS: TODO hand-edited" > "$W/tasks/engfix-app-3.md"
handoff "- ENG-CHECK DUE o/app#3 0a0b0c — again"; run >/dev/null
check "an existing fix sheet is never overwritten" grep -qx 'STATUS: TODO hand-edited' "$W/tasks/engfix-app-3.md"
rm -f "$W/store/banners"; handoff ""; run >/dev/null
check "a night with nothing due still banners the open fix" grep -q 'still open.*engfix-app-3' "$W/store/banners"
mkdir -p "$W/tasks/done"; mv "$W/tasks/engfix-app-3.md" "$W/tasks/done/"; rm -f "$W/store/banners"
handoff "- ENG-CHECK DUE o/app#3 0a0b0c — again"; run >/dev/null
check "a landed fix (sheet in done/) ends the banner" bash -c '! grep -q "still open" "$1" 2>/dev/null' _ "$W/store/banners"
check "…and a repeat FAIL never reopens a done fix" [ ! -e "$W/tasks/engfix-app-3.md" ]

reset; handoff "$F1
$E2"; export VERDICT_1="Form proof (production): PASS — ok" VERDICT_2="Engineering check: PASS — x"
check "--now exits 0" [ "$(run --now o/site#1)" = 0 ]
check "--now runs only that form" [ "$(wc -l < "$W/store/ai-calls" | tr -d ' ')" = 1 ]
check "--now leaves the engineering line DUE" grep -q '^- ENG-CHECK DUE o/app#2 ' "$W/HANDOFF.md"

reset; handoff "$F1"; export VERDICT_1="Form proof (production): PASS — ok"; mkdir -p "$W/locks/o_site_1.lock"
run >/dev/null
check "a held lock skips the line (no model run)" [ ! -f "$W/store/ai-calls" ]
check "a held lock leaves the line DUE" grep -q '^- FORM-PROOF DUE o/site#1 ' "$W/HANDOFF.md"

reset; handoff "$F1"; export VERDICT_1="Form proof (production): PASS — ok"
"$PLC" --dry-run </dev/null >/dev/null 2>&1
check "--dry-run runs no model" [ ! -f "$W/store/ai-calls" ]

echo "post-land-check: $passes ok, $fails failed"
[ "$fails" -eq 0 ]
