#!/usr/bin/env bash
# brief-gate: every refusal and every pass, each proven (weekend post-mortem 22 Nov 2026).
set -u; cd "$(dirname "$0")/.." || exit 1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
mkdir -p "$T/tasks" "$T/s/subagents"
printf 'STATUS: FAIL seq23/boss-os#539 abc 2026-11-22\n' > "$T/tasks/job.md"
printf 'STATUS: PASS seq23/boss-os#540 abc 2026-11-22\n' > "$T/tasks/ok.md"
run(){ echo "$2" | TASK_SHEETS_DIR="$T/tasks" node brief-gate.mjs >/dev/null 2>&1; got=$?; [ "$got" = "$1" ] || { echo "FAIL want $1 got $got: $3"; fail=1; }; }
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
[ $fail = 0 ] && echo "brief-gate: 14/14 ok"; exit $fail
