#!/bin/bash
# post-land-check against a fake gh (a comments store per PR) and a fake ai-run (posts the scenario's comment).
# Proves: a missing or unreadable list (post-land-checks.md) is exit 2; nothing due is 0; a form PASS turns its line DONE with the link; a form FAIL
# turns it FAIL, raises a banner and files an issue; no verdict comment (or one from another account, or one older
# than the run) leaves the line DUE and exits 1; every ENG-CHECK runs in ONE ai-run and each PR gets its own verdict;
# --now runs only that PR's FORM-PROOF; a held lock skips the line; ai-run never eats the remaining lines on stdin.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; PLC="${PLC_UNDER_TEST:-$HERE/post-land-check}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
[ "$(uname)" = Darwin ] || export OUTCOME_READ_NO_SANDBOX_OK=1   # Linux CI has no sandbox-exec; the Mac always uses it
mkdir -p "$W/bin" "$W/store"
cat > "$W/bin/gh" <<'GH'
#!/bin/bash
S="$PLC_STORE"
case "$1 $2" in
  "api user") echo "${FAKE_ME:-me}";;
  "api --paginate") f="$S/$(echo "$3" | tr '/' '_').json"; [ -f "$f" ] && cat "$f" || echo '[]';;
  "issue create") echo "$*" >> "$S/issues";;
  "pr view") printf 'A title\n\nPR body text\n';;
  "pr diff") printf 'THE DIFF LINE\n';;
  "pr comment") [ -z "${GH_COMMENT_FAIL:-}" ] || exit 1   # pr comment <n> --repo <r> --body-file <f>: appended to that PR's comments, as this account
    f="$S/$(echo "repos/$5/issues/$3/comments" | tr '/' '_').json"; [ -f "$f" ] || echo '[]' > "$f"
    jq --rawfile b "$7" --arg u "${FAKE_ME:-me}" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg url "https://github.com/$5/pull/$3#code" \
      '. + [{body: $b, user: {login: $u}, created_at: $t, html_url: $url}]' "$f" > "$f.t" && mv "$f.t" "$f"
    echo "https://github.com/$5/pull/$3#code";;
  *) echo "fake gh: $*" >&2; exit 1;;
esac
GH
cat > "$W/bin/ai-run" <<'AI'
#!/bin/bash
# A bare run (AI_RUN_BARE=1: no tools) answers in text into --out, as claude -p would; code posts the verdict.
# Any other run (form proofs, engineering checks) posts the scenario's verdict as a comment itself, as before.
S="$PLC_STORE"; echo x >> "$S/ai-calls"; n="$(wc -l < "$S/ai-calls" | tr -d ' ')"
echo "model=${AI_RUN_CLAUDE_MODEL:-} mcp=${AI_RUN_MCP:-} bare=${AI_RUN_BARE:-} secs=${AI_RUN_MAX_SECS:-} runs=${AI_RUN_MAX_RUNS:-} ignore=${AI_RUN_IGNORE_PAUSE:-}" >> "$S/ai-env"
prompt="${@: -1}"; printf '%s\n' "$prompt" > "$S/ai-prompt"; printf '%s\n' "$prompt" > "$S/ai-prompt-$n"
out=""; net=0; cwd=""; a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do case "${a[i]}" in --out) out="${a[i+1]}";; --network) net=1;; --cwd) cwd="${a[i+1]}";; esac; done
# Swallow stdin like claude -p would (bounded, so a mutation fails the test instead of hanging it).
timeout 5 cat >/dev/null 2>&1 || true
if [ -n "${AI_RUN_BARE:-}" ]; then
  echo "bare=${AI_RUN_BARE} network=$net cwd=$cwd" >> "$S/ai-how"
  pr="$(grep -oE '[a-z0-9-]+/[a-z0-9-]+#[0-9]+' <<<"$prompt" | head -1)"; pr="${pr##*#}"
  if grep -q "write ONE check" <<<"$prompt"; then vn="INFER_${pr}"; else vn="VERDICT_${pr}"; fi
  [ -z "${!vn:-}" ] || printf '%s\nevidence line\n' "${!vn}" >> "$out"
  exit 0
fi
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
  POST_LAND_DUE_FILE="$W/post-land-checks.md" POST_LAND_LOCKS="$W/locks" POST_LAND_NOTIFY="$W/bin/notify" POST_LAND_TASKS="$W/tasks"
printf '#!/bin/bash\necho "$1" >> "%s/store/banners"\n' "$W" > "$W/bin/notify"; chmod +x "$W/bin/notify"
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); [ -z "${PLC_DEBUG:-}" ] || sed "s/^/    | /" "$W/out" 2>/dev/null | tail -8; fi; }
reset() { rm -rf "$W/store" "$W/locks" "$W/tasks"; mkdir -p "$W/store"; unset VERDICT_1 VERDICT_2 VERDICT_3 VERDICT_4 VERDICT_5 INFER_5 COMMENT_USER COMMENT_AT; }
# The list land writes (27 Nov 2026: ~/Work/tasks/post-land-checks.md; the lines used to sit in HANDOFF's Today).
due_list() { printf '# Post-land checks\n\n%s\n' "$1" > "$W/post-land-checks.md"; }
F1='- FORM-PROOF DUE o/site#1 abc123 — forms: contact form; deployed 23 Nov 2026 10:00 CT; a marked TEST submission on production proves each one'
E2='- ENG-CHECK DUE o/app#2 def456 — landed on green CI with no reviewer'"'"'s PASS (Fast PRs) 23 Nov 2026 10:00 CT; a fresh reviewer checks'
E3='- ENG-CHECK DUE o/app#3 0a0b0c — landed under her bypass 23 Nov 2026 11:00 CT; a fresh reviewer checks'
run() { "$PLC" "$@" </dev/null >/dev/null 2>&1; echo $?; }
# The nightly lessons step is a stub here (never her real lessons-pass or a model); tests/test-lessons-pass.sh proves it.
export POST_LAND_LESSONS="$W/bin/lessons"; printf '#!/bin/bash\nexit 0\n' > "$W/bin/lessons"; chmod +x "$W/bin/lessons"

reset; rm -f "$W/post-land-checks.md"
check "a missing list is exit 2" [ "$(run)" = 2 ]
check "…named, never a silent 'nothing due'" eval '"$PLC" </dev/null >"$W/out" 2>&1; grep -q "NAMED STOP \[DUE_FILE_UNREADABLE\]" "$W/out"'
mkdir "$W/post-land-checks.md"
check "a list that cannot be read (a folder in its place) is exit 2" [ "$(run)" = 2 ]
rmdir "$W/post-land-checks.md"
# The one place: a DUE line that is only in a HANDOFF.md (where they lived until 27 Nov 2026) is not read.
reset; due_list "- something else"; mkdir -p "$W/home"; printf '# H\n<!-- TODAY:START -->\n<!-- JOBS:END -->\n%s\n<!-- TODAY:END -->\n' '- FORM-PROOF DUE o/site#1 abc123 — forms: contact form' > "$W/home/HANDOFF.md"
check "a DUE line only in ~/HANDOFF.md is not read: exit 0, no model call" eval '[ "$(HOME="$W/home" run)" = 0 ] && [ ! -f "$W/store/ai-calls" ] && grep -q "^- FORM-PROOF DUE o/site#1 " "$W/home/HANDOFF.md"'
reset; due_list "- something else"
check "nothing due is exit 0" [ "$(run)" = 0 ]
check "nothing due calls no model" [ ! -f "$W/store/ai-calls" ]

reset; due_list "$F1"; export VERDICT_1="Form proof (production): PASS — contact form TEST 200, stored"
check "form PASS exits 0" [ "$(run)" = 0 ]
check "form PASS turns the line DONE with the link" grep -q '^- FORM-PROOF DONE o/site#1 abc123 .* → https://github.com/o/site/pull/1#c$' "$W/post-land-checks.md"

reset; due_list "$F1"; export VERDICT_1="**Form proof (production): FAIL — 500 from /api/contact**"
check "form FAIL is a result (exit 0)" [ "$(run)" = 0 ]
check "form FAIL turns the line FAIL" grep -q '^- FORM-PROOF FAIL o/site#1 ' "$W/post-land-checks.md"
check "form FAIL files an issue on that repo" grep -q 'issue create --repo o/site' "$W/store/issues"
check "form FAIL raises a banner" grep -q 'FAILED' "$W/store/banners"

reset; due_list "$F1"
check "no verdict comment is exit 1" [ "$(run)" = 1 ]
check "no verdict leaves the line DUE" grep -q '^- FORM-PROOF DUE o/site#1 ' "$W/post-land-checks.md"

reset; due_list "$F1"; export VERDICT_1="Form proof (production): PASS — x" COMMENT_USER=someone-else
check "another account's comment never counts" [ "$(run)" = 1 ]
reset; due_list "$F1"; export VERDICT_1="Form proof (production): PASS — x" COMMENT_AT="2020-01-01T00:00:00Z"
check "a comment older than the run never counts" [ "$(run)" = 1 ]

F4='- FORM-PROOF DUE o/site#4 fff000 — forms: booking form; deployed 23 Nov 2026 10:05 CT; a marked TEST submission on production proves each one'
reset; due_list "$F1
$F4
$E2
$E3"; export VERDICT_4="Form proof (production): PASS — booking ok" VERDICT_1="Form proof (production): PASS — ok" VERDICT_2="Engineering check: PASS — read the diff" VERDICT_3="Engineering check: FAIL — fail 4: old path kept"
check "batch exits 0" [ "$(run)" = 0 ]
check "one run per form + ONE engineering run" [ "$(wc -l < "$W/store/ai-calls" | tr -d ' ')" = 3 ]
check "eng PASS is DONE" grep -q '^- ENG-CHECK DONE o/app#2 ' "$W/post-land-checks.md"
check "eng FAIL is FAIL" grep -q '^- ENG-CHECK FAIL o/app#3 ' "$W/post-land-checks.md"
check "the second form line, after an ai-run that reads stdin, was still checked" grep -q '^- FORM-PROOF DONE o/site#4 ' "$W/post-land-checks.md"
check "an eng FAIL files no issue" [ ! -f "$W/store/issues" ]
check "an eng FAIL writes its fix sheet: STATUS TODO with the verdict link" grep -q '^STATUS: TODO .*app PR 3.*https://github.com/o/app/pull/3#c$' "$W/tasks/engfix-app-3.md"
check "line 1 names no owner/repo#n, so land-after takes the FIX PR on this sheet" bash -c '! head -1 "$1" | grep -qE "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+"' _ "$W/tasks/engfix-app-3.md"
check "the fix sheet names the land that closes it" grep -q 'land-after <fix pr> --task engfix-app-3 --repo o/app' "$W/tasks/engfix-app-3.md"
check "an eng PASS writes no fix sheet" [ ! -e "$W/tasks/engfix-app-2.md" ]
check "the FAIL banner points at the fix sheet" grep -q 'fix sheet' "$W/store/banners"
echo "STATUS: TODO hand-edited" > "$W/tasks/engfix-app-3.md"
due_list "- ENG-CHECK DUE o/app#3 0a0b0c — again"; run >/dev/null
check "an existing fix sheet is never overwritten" grep -qx 'STATUS: TODO hand-edited' "$W/tasks/engfix-app-3.md"
rm -f "$W/store/banners"; due_list ""; run >/dev/null
check "a night with nothing due still banners the open fix" grep -q 'still open.*engfix-app-3' "$W/store/banners"
mkdir -p "$W/tasks/done"; mv "$W/tasks/engfix-app-3.md" "$W/tasks/done/"; rm -f "$W/store/banners"
due_list "- ENG-CHECK DUE o/app#3 0a0b0c — again"; run >/dev/null
check "a landed fix (sheet in done/) ends the banner" bash -c '! grep -q "still open" "$1" 2>/dev/null' _ "$W/store/banners"
check "…and a repeat FAIL never reopens a done fix" [ ! -e "$W/tasks/engfix-app-3.md" ]

reset; due_list "$F1
$E2"; export VERDICT_1="Form proof (production): PASS — ok" VERDICT_2="Engineering check: PASS — x"
check "--now exits 0" [ "$(run --now o/site#1)" = 0 ]
check "--now runs only that form" [ "$(wc -l < "$W/store/ai-calls" | tr -d ' ')" = 1 ]
check "--now leaves the engineering line DUE" grep -q '^- ENG-CHECK DUE o/app#2 ' "$W/post-land-checks.md"

reset; due_list "$F1"; export VERDICT_1="Form proof (production): PASS — ok"; mkdir -p "$W/locks/o_site_1.lock"
run >/dev/null
check "a held lock skips the line (no model run)" [ ! -f "$W/store/ai-calls" ]
check "a held lock leaves the line DUE" grep -q '^- FORM-PROOF DUE o/site#1 ' "$W/post-land-checks.md"

reset; due_list "$F1"; export VERDICT_1="Form proof (production): PASS — ok"
"$PLC" --dry-run </dev/null >/dev/null 2>&1
check "--dry-run runs no model" [ ! -f "$W/store/ai-calls" ]

echo "=== OUTCOME-CHECK (rebuilt 27 Nov 2026): no shell, no logins; code reads, a model with NO tools judges, code posts ==="
export POST_LAND_NOTICE="$W/bin/notice" POST_LAND_TODAY=2026-11-25
printf '#!/bin/bash\n[ -z "${NOTICE_FAIL:-}" ] || exit 1\nprintf "%%s\\t%%s\\n" "$1" "$2" >> "%s/store/notices"\n' "$W" > "$W/bin/notice"; chmod +x "$W/bin/notice"
cat > "$W/bin/ai-run-down" <<'AI'
#!/bin/bash
echo x >> "$PLC_STORE/ai-calls"; echo "Claude usage limit reached" >&2; exit 1
AI
chmod +x "$W/bin/ai-run-down"
# The checks read files under a fake home, through the REAL outcome-read (outcome-read's own suite covers the web reads).
H="$W/home"; mkdir -p "$H/Work/tasks" "$H/.config/gh"
printf 'acted 1\nacted 2\nacted 3\nacted 4\n' > "$H/Work/tasks/acted.log"; printf 'one row\n' > "$H/Work/tasks/one.log"; : > "$H/Work/tasks/empty.log"
printf 'oauth_token: gho_FAKE\n' > "$H/.config/gh/hosts.yml"
oline() { printf -- '- OUTCOME-CHECK DUE o/app#5 aaa111 — task:job5 by:%s expect:%s — outcome: Noelle acts on her decisions — check: %s' "${3:-2026-11-25}" "${2:->=3}" "$1"; }
osheet() { export POST_LAND_TASKS; POST_LAND_TASKS="$(mktemp -d "$W/tasks.XXXXXX")"; printf '%s\n## Not built (PR #5, from land)\nNothing cut.\n## End Not built\nGoal: g\n' "${1:-STATUS: LANDED-UNCHECKED o/app#5 aaa111 2026-11-24 — landed, not yet proven: outcome check due 2026-11-25}" > "$POST_LAND_TASKS/job5.md"; }
FOUR='grep -c acted ~/Work/tasks/acted.log'
CJ="$W/store/repos_o_app_issues_5_comments.json"
comments() { jq length "$CJ" 2>/dev/null || echo 0; }
first() { jq -r ".[-1].body" "$CJ" | head -1; }
notices() { if [ -f "$W/store/notices" ]; then wc -l < "$W/store/notices" | tr -d ' '; else echo 0; fi; }
# shellcheck disable=SC2120  # a case may pass flags
orun() { HOME="$H" "$PLC" "$@" </dev/null >"$W/out" 2>&1; echo $?; }
calls() { if [ -f "$W/store/ai-calls" ]; then wc -l < "$W/store/ai-calls" | tr -d ' '; else echo 0; fi; }

reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4 of 4 decisions acted on. all from today"
check "outcome PASS: exit 0" [ "$(orun)" = 0 ]
check "…ONE model run judged it" [ "$(calls)" = 1 ]
check "…that model had NO tools: ai-run asked for a bare run, no --network, started in the lock folder (not her home)" eval 'grep -qx "bare=1 network=0 cwd=$W/locks" "$W/store/ai-how"'
check "…it was handed the check's real output, the count, and the PR's text" eval 'grep -qx "4" "$W/store/ai-prompt" && grep -q "It counted 4" "$W/store/ai-prompt" && grep -q "PR body text" "$W/store/ai-prompt"'
check "…CODE posted the model's verdict as the PR comment (first line exact)" eval '[ "$(comments)" = 1 ] && [ "$(first)" = "Outcome check (live): PASS — saw 4 of 4 decisions acted on; all from today" ]'
check "…the line in the list is DONE with the comment's link" grep -q '^- OUTCOME-CHECK DONE o/app#5 aaa111 — task:job5 .* → https://github.com/o/app/pull/5#code$' "$W/post-land-checks.md"
check "…the task sheet's line 1 is DONE and it moved to done/" eval 'head -1 "$POST_LAND_TASKS/done/job5.md" | grep -q "^STATUS: DONE o/app#5 aaa111 2026-11-25 — outcome checked live: saw 4 of 4" && [ ! -e "$POST_LAND_TASKS/job5.md" ]'
check "…the Notices line: '<repo> #<pr> <outcome>: working — <seen>', one sentence" \
  grep -qx $'outcome:o/app#5:working\tapp #5 Noelle acts on her decisions: working — saw 4 of 4 decisions acted on; all from today' "$W/store/notices"
check "…no banner on a PASS" [ ! -f "$W/store/banners" ]
check "…the check's raw output went to the local log only" grep -q '^4$' "$W/log"
check "replay: a second run tonight posts no second comment and no second Notices line" eval '[ "$(orun)" = 0 ] && [ "$(calls)" = 1 ] && [ "$(notices)" = 1 ] && [ "$(comments)" = 1 ]'

reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): FAIL — saw 0 of 11 decisions acted on; the 4 lines are log headers"
check "outcome model FAIL (count met, meaning wrong): a result, exit 0" [ "$(orun)" = 0 ]
check "…the line is FAIL" grep -q '^- OUTCOME-CHECK FAIL o/app#5 ' "$W/post-land-checks.md"
check "…the sheet's line 1 is FAIL and it stays open" eval 'head -1 "$POST_LAND_TASKS/job5.md" | grep -q "^STATUS: FAIL o/app#5 aaa111 2026-11-25 — outcome NOT WORKING: saw 0 of 11"'
check "…the banner says NOT WORKING: expected, saw, look" grep -q '^NOT WORKING: app #5 Noelle acts on her decisions — expected at least 3; saw 0 of 11 decisions acted on; the 4 lines are log headers; look: https://github.com/o/app/pull/5#code$' "$W/store/banners"
check "…the Notices line says NOT WORKING" grep -qx $'outcome:o/app#5:not-working\tapp #5 Noelle acts on her decisions: NOT WORKING — expected at least 3; saw 0 of 11 decisions acted on; the 4 lines are log headers; look: https://github.com/o/app/pull/5#code' "$W/store/notices"

reset; osheet; due_list "$(oline 'cat ~/Work/tasks/one.log')"; export VERDICT_5="Outcome check (live): PASS — fine"
check "below the floor (1 < 3): FAIL by code, exit 0" [ "$(orun)" = 0 ]
check "…no model ran, so no model PASS could count" [ "$(calls)" = 0 ]
check "…code posted the FAIL comment itself, naming the count" eval '[ "$(first)" = "Outcome check (live): FAIL — saw 1, needed at least 3" ]'
check "…the line is FAIL and the Notices line says NOT WORKING" eval 'grep -q "^- OUTCOME-CHECK FAIL o/app#5 " "$W/post-land-checks.md" && grep -q "NOT WORKING — expected at least 3; saw 1, needed at least 3" "$W/store/notices"'
reset; osheet; due_list "$(oline 'grep -c nomatch ~/Work/tasks/acted.log')"; export VERDICT_5="Outcome check (live): PASS — fine"
check "grep -c finding nothing (the Noelle case: 0 acted on) is NOT WORKING by code, never 'could not check'" eval '[ "$(orun)" = 0 ] && grep -q "^- OUTCOME-CHECK FAIL " "$W/post-land-checks.md" && grep -q "NOT WORKING — expected at least 3; saw 0, needed at least 3" "$W/store/notices" && [ "$(calls)" = 0 ]'

for o in "no reader:READER_GONE" "missing file:grep -c acted ~/Work/tasks/gone.log" "empty output:cat ~/Work/tasks/empty.log"; do
  c="${o#*:}"; reset; osheet; due_list "$(oline "$c")"; export VERDICT_5="Outcome check (live): PASS — fine"
  if [ "$c" = READER_GONE ]; then due_list "$(oline "$FOUR")"; export POST_LAND_OUTCOME_READ="$W/nonexistent"; fi
  check "outage (${o%%:*}): exit 1, never PASS" [ "$(orun)" = 1 ]
  check "…(${o%%:*}) the line stays DUE, no model ran, the sheet's line 1 unchanged" eval 'grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/post-land-checks.md" && [ "$(calls)" = 0 ] && head -1 "$POST_LAND_TASKS/job5.md" | grep -q "^STATUS: LANDED-UNCHECKED"'
  check "…(${o%%:*}) the comment says COULDNT-CHECK and the Notices line NOT CHECKED, in plain words" eval 'first | grep -q "^Outcome check (live): COULDNT-CHECK — " && grep -qE "^outcome:o/app#5:not-checked:2026-11-25	app #5 Noelle acts on her decisions: NOT CHECKED — the check never gave a reading: the check (could not read the live system|printed nothing); look: https://github.com/o/app/pull/5#code$" "$W/store/notices"'
  unset POST_LAND_OUTCOME_READ
done
check "replay of a COULDNT night: a second run posts no second comment or Notices line, and still exits 1" eval '[ "$(orun)" = 1 ] && [ "$(comments)" = 1 ] && [ "$(notices)" = 1 ]'
export POST_LAND_TODAY=2026-11-27
check "the next night it is tried again (a new day): exit 1, a new NOT CHECKED line for that day" eval '[ "$(orun)" = 1 ] && grep -q "^outcome:o/app#5:not-checked:2026-11-27" "$W/store/notices"'
check "…2 days past the by-day, NOT CHECKED also raises a banner" grep -q '^NOT CHECKED for 2 days: app #5' "$W/store/banners"
export POST_LAND_TODAY=2026-11-25

reset; osheet; due_list "$(oline "$FOUR")"; unset VERDICT_5
check "Rule 0, the model answered with no verdict line: exit 1" [ "$(orun)" = 1 ]
check "…the line stays DUE and the Notices line says NOT CHECKED" eval 'grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/post-land-checks.md" && grep -q "NOT CHECKED — the check never gave a reading: the checker gave no verdict" "$W/store/notices"'
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="I think it is probably fine. PASS"
check "…a PASS that is not on the verdict line never counts: exit 1, DUE" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md"'
reset; osheet; due_list "$(oline "$FOUR")"
check "Rule 0, ai-run down or a usage limit: exit 1, line DUE, NOT CHECKED" eval '[ "$(POST_LAND_AI_RUN="$W/bin/ai-run-down" orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/post-land-checks.md" && grep -q "NOT CHECKED — the check never gave a reading: the checker gave no verdict (it was down, out of its usage limit, or answered nothing)" "$W/store/notices" && ! grep -qi "exit" "$W/store/notices"'
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): COULDNT-CHECK — the output does not say which day"
check "the model says COULDNT-CHECK: exit 1, line DUE, NOT CHECKED with its words" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md" && grep -q "NOT CHECKED — the check never gave a reading: the output does not say which day" "$W/store/notices"'
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4" GH_COMMENT_FAIL=1
check "a PASS whose comment cannot be posted is never DONE: exit 1, DUE" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md" && grep -q "NOT CHECKED — the check never gave a reading: the verdict could not be posted" "$W/store/notices"'
unset GH_COMMENT_FAIL

reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4" POST_LAND_TODAY=2026-11-24
check "before its by-day: exit 0, nothing run, nothing written" eval '[ "$(orun)" = 0 ] && [ "$(calls)" = 0 ] && [ "$(notices)" = 0 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md"'
export POST_LAND_TODAY=2026-11-25

echo "=== her bypass (expect:infer): the no-tools model WRITES a check; code runs it with the same reader ==="
reset; osheet; due_list "$(oline infer infer)"; export INFER_5="Outcome: decisions acted on
Check: grep -c acted ~/Work/tasks/acted.log
Expect: >= 2" VERDICT_5="Outcome check (live): PASS — saw 4 decisions acted on"
check "infer: the model writes a check, code runs it, the judge passes it: DONE, exit 0" eval '[ "$(orun)" = 0 ] && grep -q "^- OUTCOME-CHECK DONE " "$W/post-land-checks.md" && [ "$(calls)" = 2 ]'
check "…the writer saw the PR's diff and the allowed tools" eval 'grep -q "THE DIFF LINE" "$W/store/ai-prompt-1" && grep -q "No shell runs it" "$W/store/ai-prompt-1"'
check "…the comment names the check code ran" eval 'jq -r ".[-1].body" "$CJ" | grep -qF "Ran: \`grep -c acted ~/Work/tasks/acted.log\`"'
reset; osheet; due_list "$(oline infer infer)"; export INFER_5="Outcome: decisions acted on
Check: grep -c acted ~/Work/tasks/acted.log
Expect: >= 9" VERDICT_5="Outcome check (live): PASS — fine"
check "infer: the model's own floor holds (4 < 9): FAIL by code, the judge never runs" eval '[ "$(orun)" = 0 ] && grep -q "^- OUTCOME-CHECK FAIL " "$W/post-land-checks.md" && [ "$(calls)" = 1 ]'
reset; osheet; due_list "$(oline infer infer)"; export INFER_5="Check: none — the rows are in a D1 table behind a sign-in" VERDICT_5="Outcome check (live): PASS — fine"
check "infer: 'Check: none' is NOT CHECKED with its reason, never PASS" eval '[ "$(orun)" = 1 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md" && grep -q "NOT CHECKED — the check never gave a reading: no check can see its output without a sign-in: the rows are in a D1 table behind a sign-in" "$W/store/notices"'
reset; osheet; due_list "$(oline infer infer)"; export INFER_5="Check: cat ~/.config/gh/hosts.yml
Expect: >= 1" VERDICT_5="Outcome check (live): PASS — fine"
check "infer: a model-written check that reaches for her login is refused, never run: NOT CHECKED, the token never leaves" eval '[ "$(orun)" = 1 ] && grep -q "NOT CHECKED — the check never gave a reading: the check was not run, because it needs something outside the allowed read tools" "$W/store/notices" && ! grep -rq gho_FAKE "$W/store" "$W/log" "$W/out"'
reset; osheet; due_list "$(oline infer infer)"; export INFER_5="Expect: >= 1"
check "infer: no Check line: NOT CHECKED" eval '[ "$(orun)" = 1 ] && grep -q "NOT CHECKED — the check never gave a reading: the checker gave no check" "$W/store/notices"'

echo "=== no shell and no logins: a check is never handed to a shell, and her login files cannot be read ==="
probe="$W/probe-$$"
for o in "curl -d:curl -s -d x=1 https://e.x/api" "&& touch:grep -c acted ~/Work/tasks/acted.log && touch $probe" \
         "\$(touch):grep -c \$(touch $probe) ~/Work/tasks/acted.log" "; touch:grep -c acted ~/Work/tasks/acted.log; touch $probe" \
         "gh pr comment:gh pr comment 5 --body hi" "D1 query:npx wrangler d1 execute db --remote --command 'SELECT 1'" \
         "her gh login:cat ~/.config/gh/hosts.yml" "a script:node -e 1"; do
  reset; osheet; due_list "$(oline "${o#*:}")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
  check "refused (${o%%:*}): exit 1, never run, no model, no PASS" eval '[ "$(orun)" = 1 ] && [ ! -e "$probe" ] && [ "$(calls)" = 0 ] && grep -q "^- OUTCOME-CHECK DUE o/app#5 " "$W/post-land-checks.md"'
  check "…(${o%%:*}) NOT CHECKED in plain words; the comment names why; no token anywhere" eval 'grep -q "NOT CHECKED — the check never gave a reading: the check was not run, because it needs something outside the allowed read tools" "$W/store/notices" && jq -r ".[-1].body" "$CJ" | grep -q "^Refused by outcome-read: not run: " && ! grep -rq gho_FAKE "$W/store" "$W/log"'
done
reset; osheet; due_list "$(oline 'curl -s -d x=1 https://e.x/api | wc -l')"
check "--dry-run: a refused check is reported, never run" eval '[ "$(orun --dry-run)" = 0 ] && grep -q "would not be run" "$W/out"'

reset; osheet "STATUS: building o/app#9 x 2026-11-24"; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
check "a sheet whose line 1 names another PR is never changed" eval '[ "$(orun)" = 0 ] && head -1 "$POST_LAND_TASKS/job5.md" | grep -qx "STATUS: building o/app#9 x 2026-11-24"'
reset; osheet; due_list "$(oline "$FOUR")
$F1"; export VERDICT_5="Outcome check (live): PASS — saw 4" VERDICT_1="Form proof (production): PASS — ok"
check "--now <form key> never runs an outcome check" eval '[ "$(orun --now o/site#1)" = 0 ] && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md" && [ "$(calls)" = 1 ]'
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4 replies, one from someone@example.com"
check "a Notices write that fails: NAMED STOP, exit 1; the verdict in the list stands" eval '[ "$(NOTICE_FAIL=1 orun)" = 1 ] && grep -q "NOTICE_UNWRITTEN" "$W/out" && grep -q "^- OUTCOME-CHECK DONE " "$W/post-land-checks.md"'
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4 replies, one from someone@example.com"
check "private data: an address the model wrote is masked in the comment, the Notices line and the sheet" eval '[ "$(orun)" = 0 ] && grep -q "one from \[email\]" "$W/store/notices" && ! grep -q "@example.com" "$W/store/notices" "$POST_LAND_TASKS/done/job5.md" "$CJ"'

# HER PAUSE (25 Nov 2026): a skip-until date in the future stops a scheduled run before any model call; DUE stays.
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
echo 2999-01-01 > "$W/skip"
check "paused: a scheduled run before the skip date calls no model and leaves the line DUE" eval '[ "$(POST_LAND_SKIP="$W/skip" orun)" = 0 ] && [ "$(calls)" = 0 ] && grep -q "PAUSED by the owner" "$W/out" && grep -q "^- OUTCOME-CHECK DUE " "$W/post-land-checks.md"'
check "paused: land's --now form proof is paused too (no model call, DUE kept)" eval '[ "$(POST_LAND_SKIP="$W/skip" orun --now o/site#1)" = 0 ] && [ "$(calls)" = 0 ] && grep -q "PAUSED by the owner" "$W/out"'
check "…and POST_LAND_FORCE=1 runs one anyway" eval '! POST_LAND_FORCE=1 POST_LAND_SKIP="$W/skip" HOME="$H" "$PLC" </dev/null 2>&1 | grep -q PAUSED'
echo 2000-01-01 > "$W/skip"
reset; osheet; due_list "$(oline "$FOUR")"; export VERDICT_5="Outcome check (live): PASS — saw 4"
check "…an expired skip date runs the checks as usual" eval '[ "$(POST_LAND_SKIP="$W/skip" orun)" = 0 ] && ! grep -q "PAUSED" "$W/out" && grep -q "^- OUTCOME-CHECK DONE " "$W/post-land-checks.md"'
# USAGE SAVER (27 Nov 2026): every checker run is the cheap kind: Sonnet, 15 minutes, 200 a day; no connectors, or no tools at all.
check "every checker run asks ai-run for Sonnet, its caps, and no connectors (or no tools)" eval '[ -s "$PLC_STORE/ai-env" ] && ! grep -vE "^model=sonnet (mcp=none bare=|mcp= bare=1) secs=900 runs=200 ignore=1$" "$PLC_STORE/ai-env" | grep -q .'
rm -f "$W/skip"
unset POST_LAND_TASKS POST_LAND_NOTICE POST_LAND_TODAY

echo "post-land-check: $passes ok, $fails failed"
[ "$fails" -eq 0 ]
