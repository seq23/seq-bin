#!/usr/bin/env bash
# brief-gate: every refusal and every pass, each proven (weekend post-mortem 22 Nov 2026).
set -u; cd "$(dirname "$0")/.." || exit 1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
mkdir -p "$T/tasks" "$T/s/subagents"
printf 'STATUS: FAIL seq23/boss-os#539 abc 2026-11-22\n' > "$T/tasks/job.md"
printf 'STATUS: PASS seq23/boss-os#540 abc 2026-11-22\n' > "$T/tasks/ok.md"
# PR bodies the claims check reads (BRIEF_GATE_PR_BODIES); a proven Self-review for the PRs the older cases name.
mkdir -p "$T/b"; good='## Self-review
| Check | Proof |
|---|---|
| runner pinned to main | `grep -n runner_ref .github/workflows/ci.yml` → no match |
- 3am journey shows the right screen: `node tap.mjs --journey night` → shot shows "Go back to sleep"
- money: n/a — this PR touches no prices
## Mutation proof'
for n in 539 540 5390; do printf '%s\n' "$good" > "$T/b/seq23_boss-os_$n.md"; done
body(){ printf '%s\n' "$2" > "$T/b/seq23_boss-os_$1.md"; }
rev(){ printf '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"review seq23/boss-os#%s"}}' "$1"; }
run(){ echo "$2" | TASK_SHEETS_DIR="$T/tasks" BRIEF_GATE_PR_BODIES="$T/b" node brief-gate.mjs >/dev/null 2>&1; got=$?; [ "$got" = "$1" ] || { echo "FAIL want $1 got $got: $3"; fail=1; }; }
full='THE REVIEW YOU WILL FACE HOW IT BREAKS SELF-PROOF HER WORDS ASKED FOR: “build noelle as she said” NOT ASKED FOR: none HER YES: “yes go” CLAUDE BECAUSE: needs the browser REVIEW CLASS: none — log wording only'
run 2 '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}' "general agent refused"
run 2 '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' "no type = general, refused"
run 0 '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","prompt":"x"}}' "read-only helper passes"
run 0 '{"tool_name":"Bash","tool_input":{}}' "not an Agent call"
run 2 '{"tool_name":"Agent","tool_input":{"subagent_type":"builder","prompt":"x"}}' "builder brief missing sections"
run 0 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$full\"}}" "full builder brief passes"
nocls='THE REVIEW YOU WILL FACE HOW IT BREAKS SELF-PROOF HER WORDS ASKED FOR: “build noelle as she said” NOT ASKED FOR: none HER YES: “yes go” CLAUDE BECAUSE: needs the browser'
run 2 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$nocls\"}}" "builder brief with no REVIEW CLASS line refused"
run 2 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$nocls REVIEW CLASS: maybe\"}}" "a REVIEW CLASS that is no class refused"
run 0 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$nocls Review class: money -- moves payouts\"}}" "a named class passes"
nomine="${nocls/ASKED FOR: “build noelle as she said” /}"
run 2 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$nomine REVIEW CLASS: none — x\"}}" "builder brief without her verbatim ASKED FOR refused"
noyes="${nocls/HER YES: “yes go” /}"
run 2 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$noyes REVIEW CLASS: none — x\"}}" "builder brief without HER YES to the preview refused"
noextra="${nocls/NOT ASKED FOR: none /}"
run 2 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$noextra REVIEW CLASS: none — x\"}}" "builder brief without NOT ASKED FOR refused"
nocodex="${nocls/CLAUDE BECAUSE: needs the browser/}"
run 2 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"$nocodex REVIEW CLASS: none — x\"}}" "Claude builder with no reason it cannot run on Codex refused"
run 2 '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"review seq23/boss-os#539"}}' "full review of a FAILed PR refused"
run 0 '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"RECHECK OF: F1 F2 on seq23/boss-os#539"}}' "re-check of a FAILed PR passes"
run 0 '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"review seq23/boss-os#540"}}' "review of a PASSed PR passes"
run 0 '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"review seq23/boss-os#5390"}}' "a different PR number is not matched"
for n in a b c d e f; do touch "$T/s/subagents/$n.jsonl"; done
run 0 "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"reviewer\",\"prompt\":\"x\"},\"transcript_path\":\"$T/s.jsonl\"}" "no limit on how many agents run"
# CLAIMS PROVEN (her order 24 Nov 2026): the exact shape of both 24 Nov fails is refused before a review starts.
body 601 '## Self-review
- runner is on @main now, PR body updated'
run 2 "$(rev 601)" "a bare claim with no command (the @main fail) refused"
body 602 '## Self-review
- writes are refused: checked in the code'
run 2 "$(rev 602)" "a claim with prose but no command and output (the refused fail) refused"
body 603 '## Self-review
- journey green: `node tap.mjs`'
run 2 "$(rev 603)" "a command with no output shown refused"
body 604 '## Self-review
- runner pinned: `grep -n runner_ref ci.yml` → no match
- also fine everywhere'
run 2 "$(rev 604)" "one unproven line among proven ones refused"
body 605 '## Summary
all good'
run 2 "$(rev 605)" "no Self-review section refused"
body 606 '## Self-review
## Mutation proof
- x'
run 2 "$(rev 606)" "an empty Self-review refused"
body 607 '## Self-review
- money: n/a — none'
run 2 "$(rev 607)" "an n/a with no real reason refused"
body 608 "$good"
run 0 "$(rev 608)" "a fully proven Self-review passes (table header skipped, arrows -> and → both count)"
body 609 '## Self-review
- a: `bash tests/x.sh` -> 12 pass'
run 0 "$(rev 609)" "-> counts like →"
run 2 "$(rev 610)" "a PR body that cannot be read refuses (never a review on nothing read)"
run 0 '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"hostile-review this brief file"}}' "a review naming no PR is not checked"
run 2 '{"tool_name":"Agent","tool_input":{"subagent_type":"reviewer","prompt":"RECHECK OF: F1 on seq23/boss-os#601"}}' "a re-check is checked too"
[ $fail = 0 ] && echo "brief-gate: 26/26 ok"; exit $fail
