#!/bin/bash
# quiet-lib.sh — the ONE picker of "the first failing line" in a test or CI log, sourced by pr-watch,
# ci-status and test-quiet (28 Nov 2026, token cuts: agents read one line, never the whole log).
#
#   first_failing_line < log   -> the first line that names a failure, cleaned and cut to 220 characters;
#                                 prints nothing when the log names none (the caller says so in its own words).
# Structure only: a test runner's failure markers, never a guess at what a person meant.
first_failing_line() {
  local log line
  log="$(perl -pe 's/\e\[[0-9;]*[A-Za-z]//g')"
  line="$(grep -m1 -E 'not ok |FAIL[: ]|FAIL$|✗|✖|×|AssertionError|Error: |error TS|FAILED' <<<"$log" \
    || grep -m1 '##\[error\]' <<<"$log")"
  printf '%s' "$line" | sed -E 's/^[0-9T:.-]+Z //; s/^[[:space:]]+//' | cut -c1-220
}
