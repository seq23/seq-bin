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
  "pr comment") # pr comment <n> --repo <r> --body-file <f>: appended to that PR's comments, as this account
    f="$S/$(echo "repos/$5/issues/$3/comments" | tr '/' '_').json"; [ -f "$f" ] || echo '[]' > "$f"
    jq --rawfile b "$7" --arg u "${FAKE_ME:-me}" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg url "https://github.com/$5/pull/$3#code" \
      '. + [{body: $b, user: {login: $u}, created_at: $t, html_url: $url}]' "$f" > "$f.t" && mv "$f.t" "$f"
    echo "https://github.com/$5/pull/$3#code";;
  *) echo "fake gh: $*" >&2; exit 1;;
esac
GH
cat > "$W/bin/ai-run" <<'AI'
#!/bin/bash
# Reads the prompt; for each "owner/repo#N" in it, posts the scenario's verdict as a comment.
S="$PLC_STORE"; echo x >> "$S/ai-calls"
echo "model=${AI_RUN_CLAUDE_MODEL:-} mcp=${AI_RUN_MCP:-} secs=${AI_RUN_MAX_SECS:-} runs=${AI_RUN_MAX_RUNS:-} ignore=${AI_RUN_IGNORE_PAUSE:-}" >> "$S/ai-env"
prompt="${@: -1}"
# Swallow stdin like claude -p would (bounded, so a mutation fails the test instead of hanging it).
timeout 5 cat >/dev/null 2>&1 || true
for key in $(grep -oE '[a-z0-9-]+/[a-z0-9-]+#[0-9]+' <<<"$prompt" | sort -u); do
  repo="${key%#*}"; pr="${key##*#}"; f="$S/$(echo "repos/$repo/issues/$pr/comments" | tr '/' '_').json"
  vn="VERDICT_${pr}"; v="${!vn:-}"; [ -n "$v" ] || continue
  who="${COMMENT_USER:-me}"; when="${COMMENT_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
  jq -n --arg b "$v
details" --arg u "$who" --arg t "$when" --arg url "https://github.com/$repo/pull/$pr#c" \
    '[{body: $b, user: {login: $u}, created_at: $t, html_url: $url}]' > "$f"
done
AI
chmod +x "$W/bin/gh" "$W/bin/ai-run"
export POST_LAND_SKIP="$W/no-skip-file" PATH="$W/bin:$PATH" PLC_STORE="$W/store" POST_LAND_AI_RUN="$W/bin/ai-run" POST_LAND_LOG="$W/log" \
  POST_LAND_HANDOFF="$W/HANDOFF.md" POST_LAND_LOCKS="$W/locks" POST_LAND_NOTIFY="$W/bin/notify" POST_LAND_TASKS="$W/tasks"
printf '#!/bin/bash\necho "$1" >> "%s/store/banners"\n' "$W" > "$W/bin/notify"; chmod +x "$W/bin/notify"
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); [ -z "${PLC_DEBUG:-}" ] || sed "s/^/    | /" "$W/out" 2>/dev/null | tail -8; fi; }
reset() { rm -rf "$W/store" "$W/locks" "$W/tasks"; mkdir -p "$W/store"; unset VERDICT_1 VERDICT_2 VERDICT_3 VERDICT_4 VERDICT_5 COMMENT_USER COMMENT_AT; }
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
check "an eng FAIL writes its fix sheet: STATUS TODO with the verdict link" grep -q '^STATUS: TODO .*app PR 3.*https://github.com/o/app/pull/3#c$' "$W/tasks/engfix-app-3.md"
check "line 1 names no owner/repo#n, so land-after takes the FIX PR on this sheet" bash -c '! head -1 "$1" | grep -qE "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+"' _ "$W/tasks/engfix-app-3.md"
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

echo "=== OUTCOME-CHECK (24 Nov 2026): code runs the check, a fresh model judges its meaning, the Notices line says it ==="
export POST_LAND_SANDBOX=off POST_LAND_NOTICE="$W/bin/notice" POST_LAND_TODAY=2026-11-25
printf '#!/bin/bash\n[ -z "${NOTICE_FAIL:-}" ] || exit 1\nprintf "%%s\\t%%s\\n" "$1" "$2" >> "%s/store/notices"\n' "$W" > "$W/bin/notice"; chmod +x "$W/bin/notice"
cat > "$W/bin/ai-run-down" <<'AI'
#!/bin/bash
echo x >> "$PLC_STORE/ai-calls"; echo "Claude usage limit reached" >&2; exit 1
AI
chmod +x "$W/bin/ai-run-down"
oline() { printf -- '- OUTCOME-CHECK DUE o/app#5 aaa111 — task:job5 by:%s expect:%s — outcome: Noelle acts on her decisions — check: %s' "${3:-2026-11-25}" "${2:->=3}" "$1"; }
# a fresh task-sheet folder per case (inside $W, which the EXIT trap removes)
osheet() { export POST_LAND_TASKS; POST_LAND_TASKS="$(mktemp -d "$W/tasks.XXXXXX")"; printf '%s\n## Not built (PR #5, from land)\nNothing cut.\n## End Not built\nGoal: g\n' "${1:-STATUS: LANDED-UNCHECKED o/app#5 aaa111 2026-11-24 — landed, not yet proven: outcome check due 2026-11-25}" > "$POST_LAND_TASKS/job5.md"; }
FOUR='printf "acted 1\nacted 2\nacted 3\nacted 4\n"'
CJ="$W/store/repos_o_app_issues_5_comments.json"
comments() { jq length "$CJ" 2>/dev/null || echo 0; }
notices() { if [ -f "$W/store/notices" ]; then wc -l < "$W/store/notices" | tr -d ' '; else echo 0; fi; }
# shellcheck disable=SC2120  # a case may pass flags
orun() { "$PLC" "$@" </dev/null >"$W/out" 2>&1; echo $?; }
calls() { if [ -f "$W/store/ai-calls" ]; then wc -l < "$W/store/ai-calls" | tr -d ' '; else echo 0; fi; }

reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4 of 4 decisions acted on. all from today"
check "outcome PASS: exit 0" [ "$(orun)" = 0 ]
check "…ONE model run judged it" [ "$(calls)" = 1 ]
check "…the HANDOFF line is DONE with the comment's link" grep -q '^- OUTCOME-CHECK DONE o/app#5 aaa111 — task:job5 .* → https://github.com/o/app/pull/5#c$' "$W/HANDOFF.md"
check "…the task sheet's line 1 is DONE and it moved to done/" eval 'head -1 "$POST_LAND_TASKS/done/job5.md" | grep -q "^STATUS: DONE o/app#5 aaa111 2026-11-25 — outcome checked live: saw 4 of 4" && [ ! -e "$POST_LAND_TASKS/job5.md" ]'
check "…the Notices line: '<repo> #<pr> <outcome>: working — <seen>', one sentence" \
  grep -qx $'outcome:o/app#5:working\tapp #5 Noelle acts on her decisions: working — saw 4 of 4 decisions acted on; all from today' "$W/store/notices"
check "…no banner on a PASS" [ ! -f "$W/store/banners" ]
check "…the check's raw output went to the local log only" grep -q '^acted 4$' "$W/log"
check "replay: a second run tonight posts no second comment and no second Notices line" eval '[ "$(orun)" = 0 ] && [ "$(calls)" = 1 ] && [ "$(notices)" = 1 ]'

reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): FAIL — saw 0 of 11 decisions acted on; the 4 lines are log headers"
check "outcome model FAIL (count met, meaning wrong): a result, exit 0" [ "$(orun)" = 0 ]
check "…the line is FAIL" grep -q '^- OUTCOME-CHECK FAIL o/app#5 ' "$W/HANDOFF.md"
check "…the sheet's line 1 is FAIL and it stays open" eval 'head -1 "$POST_LAND_TASKS/job5.md" | grep -q "^STATUS: FAIL o/app#5 aaa111 2026-11-25 — outcome NOT WORKING: saw 0 of 11"'
check "…the banner says NOT WORKING" grep -q '^NOT WORKING: app #5 Noelle acts on her decisions — saw 0 of 11' "$W/store/banners"
check "…the Notices line says NOT WORKING" grep -qx $'outcome:o/app#5:not-working\tapp #5 Noelle acts on her decisions: NOT WORKING — saw 0 of 11 decisions acted on; the 4 lines are log headers' "$W/store/notices"

reset; osheet; handoff "$(oline 'echo 1')"; export VERDICT_5="Outcome check (live): PASS — fine"
check "below the floor (1 < 3): FAIL by code, exit 0" [ "$(orun)" = 0 ]
check "…no model ran, so no model PASS could count" [ "$(calls)" = 0 ]
check "…code posted the FAIL comment itself, naming the count" eval 'jq -r ".[-1].body" "$CJ" | head -1 | grep -qx "Outcome check (live): FAIL — saw 1, needed at least 3"'
check "…the line is FAIL and the Notices line says NOT WORKING" eval 'grep -q "^- OUTCOME-CHECK FAIL o/app#5 " "$W/HANDOFF.md" && grep -q "NOT WORKING — saw 1, needed at least 3" "$W/store/notices"'

for o in "D1 5xx:echo 'D1_ERROR: 503 Service Unavailable' >&2; exit 1" "gh rate limit:echo 'HTTP 403: API rate limit exceeded' >&2; exit 1" "site down:echo 'curl: (7) Failed to connect' >&2; exit 7" "empty output:true"; do
  reset; osheet; handoff "$(oline "${o#*:}")"; export VERDICT_5="Outcome check (live): PASS — fine"
  check "outage (${o%%:*}): exit 1, never PASS" [ "$(orun)" = 1 ]
  check "…(${o%%:*}) the line stays DUE, no model ran, the sheet's line 1 unchanged" eval 'grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/HANDOFF.md" && [ "$(calls)" = 0 ] && head -1 "$POST_LAND_TASKS/job5.md" | grep -q "^STATUS: LANDED-UNCHECKED"'
  check "…(${o%%:*}) the comment says COULDNT-CHECK and the Notices line NOT CHECKED" eval 'jq -r ".[-1].body" "$CJ" | head -1 | grep -q "^Outcome check (live): COULDNT-CHECK — " && grep -q "^outcome:o/app#5:not-checked:2026-11-25	app #5 Noelle acts on her decisions: NOT CHECKED — " "$W/store/notices"'
done
check "replay of a COULDNT night: a second run posts no second comment or Notices line, and still exits 1" eval '[ "$(orun)" = 1 ] && [ "$(comments)" = 1 ] && [ "$(notices)" = 1 ]'
export POST_LAND_TODAY=2026-11-27
check "the next night it is tried again (a new day): exit 1, a new NOT CHECKED line for that day" eval '[ "$(orun)" = 1 ] && grep -q "^outcome:o/app#5:not-checked:2026-11-27" "$W/store/notices"'
check "…2 days past the by-day, NOT CHECKED also raises a banner" grep -q '^NOT CHECKED for 2 days: app #5' "$W/store/banners"
export POST_LAND_TODAY=2026-11-25

reset; osheet; handoff "$(oline "$FOUR")"; unset VERDICT_5
check "Rule 0, no comment after the model ran: exit 1" [ "$(orun)" = 1 ]
check "…the line stays DUE and the Notices line says NOT CHECKED" eval 'grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/HANDOFF.md" && grep -q "NOT CHECKED — the checker gave no verdict" "$W/store/notices"'
reset; osheet; handoff "$(oline "$FOUR")"
check "Rule 0, ai-run down or a usage limit: exit 1, line DUE, NOT CHECKED" eval '[ "$(POST_LAND_AI_RUN="$W/bin/ai-run-down" orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/HANDOFF.md" && grep -q "NOT CHECKED — the checker gave no verdict (it was down, out of its usage limit, or posted nothing)" "$W/store/notices" && ! grep -qi "exit" "$W/store/notices"'
reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): COULDNT-CHECK — the D1 query timed out"
check "the model says COULDNT-CHECK: exit 1, line DUE, NOT CHECKED with its words" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md" && grep -q "NOT CHECKED — the D1 query timed out" "$W/store/notices"'
reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4" COMMENT_USER=someone-else
check "another account's PASS comment never counts: exit 1, DUE" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md"'

reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4" POST_LAND_TODAY=2026-11-24
check "before its by-day: exit 0, nothing run, nothing written" eval '[ "$(orun)" = 0 ] && [ "$(calls)" = 0 ] && [ "$(notices)" = 0 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md"'
export POST_LAND_TODAY=2026-11-25

reset; osheet; handoff "$(oline infer infer)"; export VERDICT_5="Outcome check (live): PASS — saw 12 rows written today"
check "owner bypass (infer) with no 'Ran:' line: COULDNT, exit 1, never PASS" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md" && grep -q "NOT CHECKED — the checker did not say what it ran" "$W/store/notices"'
reset; osheet; handoff "$(oline infer infer)"; export VERDICT_5="Outcome check (live): PASS — saw 12 rows written today
Ran: wrangler d1 execute boss --remote --command 'select count(*) from x'"
check "owner bypass (infer) naming the command it ran: PASS, DONE" eval '[ "$(orun)" = 0 ] && grep -q "^- OUTCOME-CHECK DONE " "$W/HANDOFF.md"'

reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4 replies, one from someone@example.com"
check "a Notices write that fails: NAMED STOP, exit 1; the HANDOFF verdict stands" eval '[ "$(NOTICE_FAIL=1 orun)" = 1 ] && grep -q "NOTICE_UNWRITTEN" "$W/out" && grep -q "^- OUTCOME-CHECK DONE " "$W/HANDOFF.md"'
reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4 replies, one from someone@example.com"
check "private data: an address the model wrote is masked in the Notices line and sheet" eval '[ "$(orun)" = 0 ] && grep -q "one from \[email\]" "$W/store/notices" && ! grep -q "@example.com" "$W/store/notices" "$POST_LAND_TASKS/done/job5.md"'
reset; osheet; handoff "$(oline 'echo 0; echo ops@example.com >/dev/null')"
check "a check that counts 0 (the Noelle case: 0 of 11 acted on) is NOT WORKING by code, never 'could not check'" eval '[ "$(orun)" = 0 ] && grep -q "^- OUTCOME-CHECK FAIL " "$W/HANDOFF.md" && grep -q "NOT WORKING — saw 0, needed at least 3" "$W/store/notices"'
check "private data: code's own comment masks an address in the check" eval '! grep -q "ops@example.com" "$CJ" && grep -q "\[email\]" "$CJ"'

echo "=== the check only reads (F1): a check that could change something is never run, even if the HANDOFF line was edited by hand ==="
# Fake curl and wrangler that record every call: a refused check must leave no call behind.
printf '#!/bin/bash\necho "$*" >> "$PLC_STORE/curl-calls"; echo 1\n' > "$W/bin/curl"; chmod +x "$W/bin/curl"
printf '#!/bin/bash\necho "$*" >> "$PLC_STORE/wrangler-calls"; echo 1\n' > "$W/bin/wrangler"; chmod +x "$W/bin/wrangler"
for o in "curl -d:curl -s -d x=1 https://e.x/api | wc -l" "curl -X POST:curl -s -X POST https://e.x/api" \
         "echo && curl:echo ok && curl -s -d x=1 https://e.x/api" "\$(curl):echo \"\$(curl -s -d x=1 https://e.x/api)\"" \
         "gh issue create:gh issue create --repo o/app -t x -b y" "D1 DELETE:wrangler d1 execute db --remote --command 'SELECT 1; DELETE FROM t'" \
         "unknown tool:noelle-count"; do
  reset; osheet; handoff "$(oline "${o#*:}")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
  check "not read-only (${o%%:*}): exit 1, never run, never PASS" eval '[ "$(orun)" = 1 ] && [ ! -e "$W/store/curl-calls" ] && [ ! -e "$W/store/wrangler-calls" ] && [ ! -e "$W/store/issues" ] && [ "$(calls)" = 0 ]'
  check "…(${o%%:*}) the line stays DUE, the sheet unchanged, NOT CHECKED in plain words" eval 'grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/HANDOFF.md" && head -1 "$POST_LAND_TASKS/job5.md" | grep -q "^STATUS: LANDED-UNCHECKED" && grep -q "NOT CHECKED — the check was not run, because it could change something instead of only reading" "$W/store/notices"'
  check "…(${o%%:*}) code's comment names the gate's reason" eval 'jq -r ".[-1].body" "$CJ" | grep -q "^Refused by post-land-check.s read-only gate: "'
done
reset; osheet; handoff "$(oline 'curl -s -d x=1 https://e.x/api | wc -l')"
check "--dry-run: a not-read-only check is reported, never run" eval '[ "$(orun --dry-run)" = 0 ] && grep -q "would not be run" "$W/out" && [ ! -e "$W/store/curl-calls" ]'
reset; osheet; handoff "$(oline 'curl -s https://e.x/api | wc -l' '>=1')"; export VERDICT_5="Outcome check (live): PASS — saw 1"
check "a read-only curl check still runs and counts (PASS)" eval '[ "$(orun)" = 0 ] && [ "$(wc -l < "$W/store/curl-calls" | tr -d " ")" = 1 ] && grep -q "^- OUTCOME-CHECK DONE " "$W/HANDOFF.md"'
rm -f "$W/bin/curl" "$W/bin/wrangler"

echo "=== a count that exits 1 is still a reading (N1); other failures are not ==="
reset; osheet; handoff "$(oline 'grep -c acted /dev/null')"; export VERDICT_5="Outcome check (live): PASS — fine"
check "grep -c counting 0 (prints 0, exit 1) is NOT WORKING by code, not NOT CHECKED" eval '[ "$(orun)" = 0 ] && grep -q "^- OUTCOME-CHECK FAIL " "$W/HANDOFF.md" && grep -q "NOT WORKING — saw 0, needed at least 3" "$W/store/notices" && [ "$(calls)" = 0 ]'
reset; osheet; handoff "$(oline 'echo 0; exit 2')"; export VERDICT_5="Outcome check (live): PASS — fine"
check "exit 2 with a bare 0 is NOT CHECKED (only exit 1 is a count)" eval '[ "$(orun)" = 1 ] && grep -q "NOT CHECKED — the check failed to run" "$W/store/notices"'
reset; osheet; handoff "$(oline 'echo 5; echo 6; exit 1')"; export VERDICT_5="Outcome check (live): PASS — fine"
check "exit 1 with two lines is NOT CHECKED (only one bare integer line is a count)" eval '[ "$(orun)" = 1 ] && grep -q "NOT CHECKED — the check failed to run" "$W/store/notices"'

echo "=== NOT CHECKED says it plainly (N6): no exit codes, no line counts ==="
reset; osheet; handoff "$(oline "echo 'D1_ERROR: 503' >&2; exit 1")"
check "a failed check: 'the check failed to run', no exit code or line count" eval '[ "$(orun)" = 1 ] && grep -q "NOT CHECKED — the check failed to run$" "$W/store/notices" && ! grep -qiE "exit|line\(s\)" "$W/store/notices"'
reset; osheet; handoff "$(oline true)"
check "a silent check: 'the check printed nothing'" eval '[ "$(orun)" = 1 ] && grep -q "NOT CHECKED — the check printed nothing$" "$W/store/notices"'

reset; osheet "STATUS: building o/app#9 x 2026-11-24"; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
check "a sheet whose line 1 names another PR is never changed" eval '[ "$(orun)" = 0 ] && head -1 "$POST_LAND_TASKS/job5.md" | grep -qx "STATUS: building o/app#9 x 2026-11-24"'
reset; osheet; handoff "$(oline "$FOUR")
$F1"; export VERDICT_5="Outcome check (live): PASS — saw 4" VERDICT_1="Form proof (production): PASS — ok"
check "--now <form key> never runs an outcome check" eval '[ "$(orun --now o/site#1)" = 0 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md" && [ "$(calls)" = 1 ]'
if [ -x /usr/bin/sandbox-exec ]; then
  reset; osheet; probe="$HOME/.plc-sandbox-probe-$$"
  handoff "$(oline "awk 'BEGIN{print 1 > \"$probe\"}' && $FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
  check "the check runs in a file-write sandbox: a FILE write that passes the read-only gate (awk print > file) is refused, COULDNT, exit 1" eval '[ "$(POST_LAND_SANDBOX=on orun)" = 1 ] && [ ! -e "$probe" ] && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md"'
  [ ! -e "$probe" ] || unlink "$probe"
  reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
  check "…and a read-only check under the sandbox still counts (PASS)" eval '[ "$(POST_LAND_SANDBOX=on orun)" = 0 ] && grep -q "^- OUTCOME-CHECK DONE " "$W/HANDOFF.md"'
fi
# HER PAUSE (25 Nov 2026): a skip-until date in the future stops a scheduled run before any model call; DUE stays.
reset; osheet; handoff "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
echo 2999-01-01 > "$W/skip"
check "paused: a scheduled run before the skip date calls no model and leaves the line DUE" eval '[ "$(POST_LAND_SKIP="$W/skip" orun)" = 0 ] && [ "$(calls)" = 0 ] && grep -q "PAUSED by the owner" "$W/out" && grep -q "^- OUTCOME-CHECK DUE " "$W/HANDOFF.md"'
check "paused: land's --now form proof is paused too (no model call, DUE kept)" eval '[ "$(POST_LAND_SKIP="$W/skip" orun --now o/site#1)" = 0 ] && [ "$(calls)" = 0 ] && grep -q "PAUSED by the owner" "$W/out"'
check "…but land's --read-only-gate is never paused" eval '! POST_LAND_SKIP="$W/skip" "$PLC" --read-only-gate "echo hi" </dev/null 2>&1 | grep -q PAUSED'
check "…and POST_LAND_FORCE=1 runs one anyway" eval '! POST_LAND_FORCE=1 POST_LAND_SKIP="$W/skip" "$PLC" </dev/null 2>&1 | grep -q PAUSED'
echo 2000-01-01 > "$W/skip"
check "…an expired skip date runs the checks as usual" eval '[ "$(POST_LAND_SKIP="$W/skip" orun)" = 0 ] && ! grep -q "PAUSED" "$W/out" && grep -q "^- OUTCOME-CHECK DONE " "$W/HANDOFF.md"'
# USAGE SAVER (27 Nov 2026): every checker run is the cheap kind: Sonnet, no connectors, 15 minutes, 200 a day.
check "every checker run asks ai-run for Sonnet, no connectors and its caps" eval '[ -s "$PLC_STORE/ai-env" ] && ! grep -qv "^model=sonnet mcp=none secs=900 runs=200 ignore=1$" "$PLC_STORE/ai-env"'
rm -f "$W/skip"
unset POST_LAND_TASKS POST_LAND_SANDBOX POST_LAND_NOTICE POST_LAND_TODAY

echo "post-land-check: $passes ok, $fails failed"
[ "$fails" -eq 0 ]
