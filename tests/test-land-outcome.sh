#!/bin/bash
# land's Outcome and Not built gates (outcome_parse, gate_not_built, job_files: in the gates block, evaluated
# verbatim). Her order 24 Nov 2026, after Noelle (boss-os #557, #561) landed green and acted on 0 of 11 decisions:
# "i do not fucking undersrtand how we can do all that work we did yesterday and this shit still be fucked up and
# u said nothing yesterday". One case per path: the two accepted forms pass; no Outcome, no check, no floor, a
# floor of 0, a write in the check, a past or far by-day, two Outcome lines and placeholders are refused; "none" on
# a PR that touches a job (plist, scheduled workflow, wrangler cron, boss schedule manifest, outreach, scripts/ops,
# growth, a script a plist runs) is refused naming the file; the real #557 and #561 bodies and file lists are REFUSED.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAND="${LAND_UNDER_TEST:-$HERE/land}"
export LAND_DIR="${LAND_DIR_UNDER_TEST:-$HERE}"   # outcome_parse asks the read-only gate in the post-land-check beside land
BLOCK="$(sed -n '/^# --- gates begin/,/^# --- gates end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: no gates block in $LAND"; exit 1; }
eval "$(sed -n "/^JOB_PATH_RE=/p; /^job_files()/,/^}/p; /^outcome_parse()/,/^}/p; /^not_built_section()/,/^}/p; /^gate_not_built()/,/^}/p" <<<"$BLOCK")"
declare -F outcome_parse gate_not_built job_files not_built_section >/dev/null || { echo "FAIL: a gate function is not in land's gates block"; exit 1; }
fails=0; passes=0
ok() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi; }
T=2026-11-24
op() { OUT="$(outcome_parse 7 "$1" "${2:-}" "$T")"; RC=$?; }
# shellcheck disable=SC2034  # WANT is read inside the eval'd check
accept() { op "$1" "${3:-}"; WANT="$2"; ok "accepted: $1 -> $2 (got rc $RC: $OUT)" eval '[ "$RC" -eq 0 ] && [ "$OUT" = "$WANT" ]'; }
# shellcheck disable=SC2034  # WANT is read inside the eval'd check
refuse() { op "$1" "${3:-}"; WANT="$2"; ok "refused: $1 ($2) (got rc $RC: $OUT)" eval '[ "$RC" -eq 1 ] && grep -qiE "$WANT" <<<"$OUT" && [ "$(wc -l <<<"$OUT" | tr -d " ")" = 1 ]'; }

echo "=== outcome_parse ==="
accept "Outcome: none — docs only, nothing runs" none
accept "- **Outcome:** none — a test helper rename only" none
accept "Outcome: Noelle acts on her decisions — check: grep -c acted ~/noelle.log — expect: >= 3 — by: 2026-11-25" \
  $'2026-11-25\t3\tNoelle acts on her decisions\tgrep -c acted ~/noelle.log'
accept "Outcome: rows in the table — check: wrangler d1 execute x --remote --command 'select count(*) from t' — expect: ≥ 10" \
  $'2026-11-25\t10\trows in the table\twrangler d1 execute x --remote --command \'select count(*) from t\''
accept "Outcome: posts in the queue -- check: curl -s https://x/api/q | jq length -- expect: >= 2 -- by: 3 days" \
  $'2026-11-27\t2\tposts in the queue\tcurl -s https://x/api/q | jq length'
refuse "Fixes the bug." "says nothing about its outcome"
refuse "Outcome: none" "gives no reason"
refuse "Outcome: none — docs" "gives no reason"
refuse "Outcome: none — <why>" "says nothing about its outcome"
refuse "Outcome: <real output> — check: <cmd> — expect: >= <N>" "says nothing about its outcome"
refuse "Outcome: Noelle acts on her decisions" "no 'check:"
refuse "Outcome: Noelle acts — check: — expect: >= 3" "names no check command"
refuse "Outcome: Noelle acts — check: grep -c acted ~/noelle.log" "no 'expect: >= <N>'"
refuse "Outcome: Noelle acts — check: grep -c acted ~/noelle.log — expect: >= 0" "floor is at least 1"
refuse "Outcome: Noelle acts — check: grep -c x log — expect: >= 3 — by: 2026-11-20" "from today to 14 days"
refuse "Outcome: Noelle acts — check: grep -c x log — expect: >= 3 — by: 2027-01-30" "from today to 14 days"
refuse "Outcome: Noelle acts — check: grep -c x log — expect: >= 3 — by: someday" "from today to 14 days"

echo "=== the check only reads (F1): outcome_parse asks post-land-check's one read-only gate, beside land ==="
# shellcheck disable=SC2034  # WANT is read inside the eval'd check
ro_refuse() { op "Outcome: rows — check: $1 — expect: >= 1 — by: 2026-11-25"; WANT="$2"
  ok "not read-only, NAMED (rc 3, one line, why): $1 (got rc $RC: $OUT)" eval '[ "$RC" -eq 3 ] && grep -q "is not read-only" <<<"$OUT" && grep -qiF -- "$WANT" <<<"$OUT" && [ "$(wc -l <<<"$OUT" | tr -d " ")" = 1 ]'; }
# shellcheck disable=SC2034  # WANT is read inside the eval'd check
ro_allow() { op "Outcome: rows — check: $1 — expect: >= 1 — by: 2026-11-25"; WANT="$1"
  ok "read-only, accepted: $1 (got rc $RC: $OUT)" eval '[ "$RC" -eq 0 ] && [ "$(cut -f4 <<<"$OUT")" = "$WANT" ]'; }
ro_refuse "curl -s -d x=1 https://e.x/api" "curl -d sends data"
ro_refuse "curl -X POST https://x/api/go" "curl -X POST is not GET or HEAD"
ro_refuse "curl -sXPOST https://x/api/go" "curl -X POST is not GET or HEAD"
ro_refuse "curl --request PUT https://x/api/go" "PUT is not GET or HEAD"
ro_refuse "curl --json '{}' https://x/api/go" "curl --json sends data"
ro_refuse "curl -F f=@x https://x/api/go" "curl -F sends data"
ro_refuse "curl -T f https://x/api/go" "curl -T sends data"
ro_refuse "curl --upload-file f https://x/api/go" "curl --upload-file sends data"
ro_refuse "curl --data-binary @f https://x/api/go" "curl --data-binary sends data"
ro_refuse "gh api repos/a/b/issues -f title=x" "graphql"
ro_refuse "gh api -X DELETE repos/a/b/git/refs/heads/x" "DELETE"
ro_refuse "gh api --method=PATCH repos/a/b" "PATCH"
ro_refuse "gh api --input body.json repos/a/b/issues" "--input"
ro_refuse "gh api graphql -f query='mutation{addStar(input:{starrableId:\"x\"}){clientMutationId}}'" "mutation"
ro_refuse "gh issue create --title x --body y" "gh issue create is not list"
ro_refuse "gh pr comment 5 --body hi" "gh pr comment is not list"
ro_refuse "gh pr merge 5 --squash" "gh pr merge is not list"
ro_refuse "npx wrangler d1 execute db --remote --command 'DELETE FROM t'" "SELECT or WITH"
ro_refuse "npx wrangler d1 execute db --remote --command 'SELECT 1; DELETE FROM t'" "statement"
ro_refuse "wrangler d1 execute db --remote --command 'WITH a AS (SELECT 1) DELETE FROM t'" "DELETE"
ro_refuse "wrangler d1 execute db --remote --file wipe.sql" "--file"
ro_refuse "wrangler kv key put k v --binding X" "wrangler"
ro_refuse "echo ok && curl -s -d x=1 https://e.x/api" "curl -d sends data"
ro_refuse "echo \$(curl -s -d x=1 https://e.x/api)" "curl -d sends data"
ro_refuse "echo \"\$(curl -s -d x=1 https://e.x/api)\" | wc -l" "curl -d sends data"
ro_refuse "true || gh issue create -t x" "gh issue create"
ro_refuse "grep -c x f; rm -rf ~/x" "rm"
ro_refuse "noelle-tool --count" "noelle-tool"
ro_refuse "curl \$(echo -d) x=1 https://e.x/api" "expansion"
ro_refuse "X=1 gh pr view 5" "variable"
ro_refuse "grep -c x f > ~/count" "file"
ro_refuse "bash -c 'curl -d x https://e.x'" "bash"
ro_refuse "ls | xargs rm" "xargs"
ro_refuse "sed -i s/a/b/ f" "sed -i"
ro_allow "curl -s https://x/api/q | jq length"
ro_allow "curl -sS -X GET https://x/api/q | jq '[.[] | select(.n < 3)] | length'"
ro_allow "curl -sI https://x/healthz | head -1"
ro_allow "gh api repos/a/b/pulls --jq length"
ro_allow "gh api -X GET repos/a/b/pulls --paginate --jq length"
ro_allow "gh pr view 5 --repo a/b --json comments --jq '.comments | length'"
ro_allow "gh api graphql -f query='{viewer{login}}' --jq .data.viewer.login"
ro_allow "npx wrangler d1 execute db --remote --command 'SELECT count(*) FROM t'"
ro_allow "wrangler d1 execute db --remote --json --command \"WITH a AS (SELECT 1) SELECT count(*) FROM a WHERE k = 'DELETE'\""
ro_allow "grep -c acted ~/noelle.log"
ro_allow "ls ~/.cache/post-land-check | grep -c '^notice-outcome'"
ro_allow "land-after --holds seq23/seq-bin 168"
GATELESS="$(LAND_DIR=/nonexistent outcome_parse 7 "Outcome: rows — check: grep -c a f — expect: >= 1" "" "$T")"; GRC=$?
# shellcheck disable=SC2034
ok "a gate that cannot be run refuses (rc 3): nothing proves the check only reads (got rc $GRC: $GATELESS)" eval '[ "$GRC" -eq 3 ] && grep -q "could not be run" <<<"$GATELESS"'

echo "=== placeholders (N4): only <placeholder>-shaped text marks one; a real < in a check does not ==="
accept "Outcome: few open PRs — check: gh pr list --json number --jq '[.[] | select(.number < 300)] | length' — expect: >= 1 — by: 2026-11-25" \
  $'2026-11-25\t1\tfew open PRs\tgh pr list --json number --jq \'[.[] | select(.number < 300)] | length\''
accept "Outcome: the page is live — check: curl -s https://x/ | grep -c '<title>' — expect: >= 1 — by: 2026-11-25" \
  $'2026-11-25\t1\tthe page is live\tcurl -s https://x/ | grep -c \'<title>\''
refuse "Outcome: <the real output> — check: grep -c x f — expect: >= 1" "says nothing about its outcome"
refuse "Outcome: rows — check: <a read-only shell command> — expect: >= 1" "says nothing about its outcome"
refuse "Outcome: A — check: grep -c a l — expect: >= 1
Outcome: B — check: grep -c b l — expect: >= 1" "keep ONE"
refuse "Outcome: none — docs only, nothing runs" "changes a scheduled job.*launchd/com.seq.noelle.plist" "launchd/com.seq.noelle.plist"

echo "=== gate_not_built ==="
nb() { OUT="$(gate_not_built 7 "$1")"; RC=$?; }
nb $'Body\n## Not built\n- the job-target lever (G1)\n- G19, the sales reader\n\n## Self-review\nx'
ok "a listed section passes, word for word, stopping at the next heading" eval '[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf -- "- the job-target lever (G1)\n- G19, the sales reader")" ]'
nb $'## Not built\nNothing cut.'; ok "'Nothing cut.' passes" eval '[ "$RC" -eq 0 ] && [ "$OUT" = "Nothing cut." ]'
nb $'### not built:\n- G19 sales reader'; ok "any heading level and case, a trailing colon" eval '[ "$RC" -eq 0 ]'
for b in "No section at all." $'## Not built\n' $'## Not built\n- \n-\n## Next' $'## Not built\n<the items>' $'## Not built\n- <item>\n- <item>' $'## Not built\nNothing'; do
  nb "$b"; ok "refused: [${b//$'\n'/\\n}]" eval '[ "$RC" -eq 1 ] && grep -q "Nothing cut." <<<"$OUT"'
done

echo "=== job_files: what touches a scheduled job, pipeline or agent ==="
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
git -C "$R" init -q -b main
mkdir -p "$R/launchd" "$R/.github/workflows" "$R/scripts/ops" "$R/worker"
printf '<plist><string>/bin/zsh</string><string>-lc</string><string>/Users/x/bin/post-land-check</string></plist>\n' > "$R/launchd/com.seq.post-land-check.plist"
printf 'on:\n  schedule:\n    - cron: "0 3 * * *"\n' > "$R/.github/workflows/nightly.yml"
printf 'on:\n  pull_request:\n' > "$R/.github/workflows/ci.yml"
printf '[triggers]\ncrons = ["0 * * * *"]\n' > "$R/worker/wrangler.toml"
printf 'name = "x"\n' > "$R/wrangler.toml"
echo x > "$R/post-land-check"; echo x > "$R/post-land-check-helper"; echo x > "$R/land"
git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm base
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
jf() { (cd "$R" && printf '%s\n' "$@" | job_files "$HEAD_SHA" "$HEAD_SHA"); }
for f in launchd/com.seq.noelle.plist Library/LaunchAgents/com.seq.x.plist com.boss.mac-job.plist .github/workflows/nightly.yml worker/wrangler.toml \
         src/shared/boss/schedule/manifest.json src/worker/boss/outreach/send.ts scripts/ops/noelle.mjs src/shared/boss/growth/noelle.mjs \
         src/worker/boss/growth/run.ts post-land-check; do
  ok "touches a job: $f" eval '[ "$(jf "$f")" = "$f" ]'
done
for f in README.md .github/workflows/ci.yml wrangler.toml land post-land-check-helper src/client/boss/pages/Home.tsx scripts/validate/x.mjs tests/x.test.ts; do
  ok "not a job: $f" eval '[ -z "$(jf "$f")" ]'
done
ok "a workflow unreadable at both ends counts as a job (fail closed)" eval '[ "$(jf .github/workflows/gone.yml)" = ".github/workflows/gone.yml (unread)" ]'
ok "job_files exits 0 when the last path is not a job" eval '(cd "$R" && printf "README.md\n" | job_files "$HEAD_SHA" "$HEAD_SHA" >/dev/null)'

echo "=== the real PRs that started this (boss-os #557, #561): both REFUSED ==="
for n in 557 561; do
  fx="$HERE/tests/fixtures/outcome/boss-os-$n.json"
  body="$(jq -r '.body' "$fx")"; jobs="$(cd "$R" && jq -r '.files[].path' "$fx" | job_files "$HEAD_SHA" "$HEAD_SHA")"
  op "$body" "$jobs"; ok "#$n: no Outcome, refused by OUTCOME_UNDECLARED's words" eval '[ "$RC" -eq 1 ] && grep -q "says nothing about its outcome" <<<"$OUT"'
  ok "#$n: its file list touches a job (so 'Outcome: none' could not pass either)" eval '[ -n "$jobs" ]'
  op "$body
Outcome: none — a small change that runs nothing new" "$jobs"; ok "#$n: with 'Outcome: none' added, refused naming a job file" eval '[ "$RC" -eq 1 ] && grep -qE "changes a scheduled job.*(scripts/ops/|growth/)" <<<"$OUT"'
  nb "$body"; ok "#$n: no Not built section, refused (the 'levers: the follow-up PR' cut was never listed)" eval '[ "$RC" -eq 1 ]'
done

echo "test-land-outcome: $passes ok, $fails failed"
[ "$passes" -gt 40 ] || { echo "FAIL: too few checks ran ($passes)"; exit 1; }
[ "$fails" -eq 0 ]
