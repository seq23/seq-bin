#!/usr/bin/env bash
# land's bounded run wait: a GitHub read that fails (rate limit, auth, network) is UNKNOWN, never
# "still running" and never "cancelled". 22 Nov 2026: every read 403'd, the wait hit its ceiling, the
# cancel failed too, and land reported a deploy that had finished green in 3.5 min as "ran past 14 min
# and was cancelled". This evals the wait_run block out of `land` verbatim with a stub gh.
set -u
# shellcheck disable=SC2329  # the gh stubs are called from the eval-ed block
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- wait_run begin/,/^# --- wait_run end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the wait_run block"; exit 1; }
eval "$BLOCK"
FAILS=0
export LAND_WAIT_POLL_SECS=0
expect() { # $1 label $2 want $3 got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; FAILS=$((FAILS + 1)); fi
}

# Every read refused, cancel refused: unknown, and nothing claimed cancelled.
gh() { case "$1 $2" in "run view") echo "HTTP 403: API rate limit exceeded" >&2; return 1 ;; "run cancel") return 1 ;; esac; }
got="$(wait_run_bounded 1 0)"; expect "rate-limited reads -> unread" unread "$got"
# Same, but with the cancel endpoint "working": still never cancels a run it could not see.
gh() { case "$1 $2" in "run view") return 1 ;; "run cancel") echo cancelled > "$TMPC"; return 0 ;; esac; }
TMPC="$(mktemp)"; : > "$TMPC"; got="$(wait_run_bounded 1 0)"; expect "unread run is never cancelled" unread "$got"; expect "no cancel sent" "" "$(cat "$TMPC")"

# Read fine and finished green: its conclusion, at once.
gh() { [ "$1 $2" = "run view" ] && printf 'completed\tsuccess\n'; }
got="$(wait_run_bounded 1 600)"; expect "completed success read" success "$got"
# Read still going at the ceiling, cancel goes through: cancelled-at-ceiling.
gh() { case "$1 $2" in "run view") printf 'in_progress\t\n' ;; "run cancel") return 0 ;; esac; }
got="$(wait_run_bounded 1 0)"; expect "seen running at ceiling, cancelled" cancelled-at-ceiling "$got"
# Read still going, cancel refused: not claimed cancelled.
gh() { case "$1 $2" in "run view") printf 'in_progress\t\n' ;; "run cancel") return 1 ;; esac; }
got="$(wait_run_bounded 1 0)"; expect "cancel refused -> unread, not cancelled" unread "$got"

rm -f "$TMPC"
if [ "$FAILS" -eq 0 ]; then echo "PASS test-land-wait-run"; else echo "FAILED $FAILS"; exit 1; fi
