#!/bin/bash
# Prove ci-sweep-stream.py leaves a readable, line-by-line round log — and that
# the sentinel the sweep greps for survives the filter.
#
# WHY THIS EXISTS
# On 2026-09-20 both sweep rounds hit their caps and both round logs were empty,
# because `claude -p` in text mode prints nothing until it finishes. The sweep
# then misread an empty log as a dead resume handle and spent a second cap on a
# fresh session. ci-sweep-stream.py flattens stream-json to text as it arrives.
# This test feeds it a fixture stream and requires: assistant text kept, tool
# calls named, the sentinel intact, non-JSON passed through, and — the negative
# control — that a stream with NO sentinel yields a log with NO sentinel, so the
# filter cannot manufacture a completion.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FILTER="$ROOT/ci-sweep-stream.py"
[ -f "$FILTER" ] || { echo "NAMED STOP [NO_FILTER] $FILTER is missing."; exit 3; }

asserts=0
failed=0
check() { asserts=$((asserts + 1)); if ! eval "$1"; then echo "  FAIL: $2"; failed=$((failed + 1)); else echo "  ok:   $2"; fi; }

FIXTURE='{"type":"system","subtype":"init","session_id":"abc","cwd":"/x"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Probing main now."},{"type":"tool_use","name":"Bash","input":{"command":"gh run list --branch main"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"RED sprylabs-hpc-site Spry Content Release\nsecond line ignored"}]}}
not json at all: a crash trace line
{"type":"rate_limit_event","x":1}
{"type":"assistant","message":{"content":[{"type":"text","text":"CI-SWEEP-COMPLETE: fixed — one PR landed"}]}}
{"type":"result","subtype":"success","result":"CI-SWEEP-COMPLETE: fixed — one PR landed"}'

OUT="$(printf '%s\n' "$FIXTURE" | python3 "$FILTER")"
echo "--- filtered output ---"; echo "$OUT"; echo "-----------------------"

check '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" -ge 6 ]' "one text line per event, not one blob at the end"
check 'printf "%s\n" "$OUT" | grep -q "^Probing main now\.$"' "assistant text is kept verbatim"
check 'printf "%s\n" "$OUT" | grep -q "^\[tool\] Bash .*gh run list"' "a tool call is named with its argument digest"
check 'printf "%s\n" "$OUT" | grep -q "^\[result\] RED sprylabs-hpc-site"' "a tool result keeps its first line"
check '! printf "%s\n" "$OUT" | grep -q "second line ignored"' "a tool result keeps ONLY its first line"
check 'printf "%s\n" "$OUT" | grep -q "^not json at all: a crash trace line$"' "a non-JSON line passes through verbatim, never dropped"
check '! printf "%s\n" "$OUT" | grep -q "rate_limit_event"' "bookkeeping events are dropped"
check '[ "$(printf "%s\n" "$OUT" | grep -o "CI-SWEEP-COMPLETE:.*" | tail -1)" = "CI-SWEEP-COMPLETE: fixed — one PR landed" ]' "the sentinel survives the filter exactly as the sweep greps it"

# --- negative control: a stream that never completed must not read as complete
PARTIAL="$(printf '%s\n' "$FIXTURE" | head -3)"
OUT2="$(printf '%s\n' "$PARTIAL" | python3 "$FILTER")"
echo "--- filtered output of a capped stream ---"; echo "$OUT2"; echo "-----------------------"
check '! printf "%s\n" "$OUT2" | grep -q "CI-SWEEP-COMPLETE:"' "a capped stream yields a log with no sentinel — the filter cannot manufacture completion"
check '[ -n "$OUT2" ]' "a capped stream still leaves a transcript of what ran"

# --- Rule 0 on this test ---
[ "$asserts" -ge 10 ] || { echo "NAMED STOP [TOO_FEW_ASSERTIONS] $asserts"; exit 3; }
if [ "$failed" -ne 0 ]; then echo "test-stream-filter: $failed of $asserts assertion(s) FAILED"; exit 1; fi
echo "test-stream-filter: $asserts assertion(s) passed"
