#!/bin/bash
# ci-sweep-retry-if-red.sh, the 09:00 gate (08:00 until 2 Oct 2026, when the cadence went Mon+Fri), against a fake ledger, a fake lock and a
# fake sweep. What is under test is the gate's OWN decision:
#   · no row today, nothing in flight        -> run the sweep
#   · a MAIN-GREEN row today                  -> do nothing
#   · a PAUSED row today (owner's pause-until, 26 Sep 2026) -> do nothing: terminal
#   · one non-green row today                 -> run the sweep (the one retry)
#   · two rows today                          -> do nothing
#   · no row today, a sweep IN FLIGHT         -> wait for it, then decide from ITS row
#     (26 Sep 2026, then daily 07:00/08:00: the 07:00 run was in round 2 at 08:00; the gate ran the sweep, the
#     lock no-oped it, and the day could never get its retry)
#   · in flight past its ceiling              -> hand it to the sweep (whose lock reclaims)
#   · in flight, then gone with no row        -> run the sweep
# RULE 0: zero assertions is not a pass. The wait is proven negatively: with the wait
# removed, the gate runs the sweep while the holder is still alive.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GATE="$ROOT/ci-sweep-retry-if-red.sh"
[ -x "$GATE" ] || { echo "NAMED STOP [MISSING] $GATE"; exit 3; }
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^CI_SWEEP_')

TMP="$(mktemp -d)"
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$TMP"' EXIT
asserts=0; failed=0
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

LOGS="$TMP/logs"; LEDGER="$LOGS/state/outcomes.tsv"; LOCK="$LOGS/.lock"
# The fake sweep records that it ran, and whether the lock holder was still alive then.
cat > "$TMP/sweep" <<'SH'
#!/bin/bash
p="$(cat "$CI_SWEEP_LOG_DIR/.lock/pid" 2>/dev/null)"
if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "ran-while-holder-alive" >> "$FAKE_RAN"; else echo "ran" >> "$FAKE_RAN"; fi
SH
chmod +x "$TMP/sweep"
export FAKE_RAN="$TMP/ran"
TODAY="$(date +%Y-%m-%d)"
row() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$TODAY" "$1" "$2" >> "$LEDGER"; }
reset() { rm -rf "$LOGS" "$FAKE_RAN"; mkdir -p "$LOGS/state"; : > "$LEDGER"; }
gate() { env CI_SWEEP_LOG_DIR="$LOGS" CI_SWEEP_BIN="$TMP/sweep" CI_SWEEP_RETRY_POLL_SECS=1 "$@" "${GATE_BIN:-$GATE}" > "$TMP/gate.out" 2>&1; }
ran() { cat "$FAKE_RAN" 2>/dev/null; }
# hold <secs> [row-verdict]: a live lock holder that ends after <secs>, writing a row if given
hold() {
  local secs="$1" verdict="${2:-}"
  mkdir -p "$LOCK"; date +%s > "$LOCK/started"; echo run-0700 > "$LOCK/run-id"
  ( sleep "$secs"; [ -n "$verdict" ] && row "$verdict" run-0700; rm -rf "$LOCK" ) &
  HOLDER=$!; echo "$HOLDER" > "$LOCK/pid"
}

echo "=== the ledger decides ==="
reset; gate
check "no row, nothing in flight: runs" [ "$(ran)" = "ran" ]
reset; row MAIN-GREEN r1; gate
check "a green row today: does nothing" [ -z "$(ran)" ]
reset; row MAIN-RED-STUCK r1; gate
check "one non-green row: the one retry runs" [ "$(ran)" = "ran" ]
reset; row MAIN-RED-STUCK r1; row MAIN-RED-STUCK r2; gate
check "two rows: does nothing" [ -z "$(ran)" ]
reset; row PAUSED r1; gate
check "a PAUSED row today (the owner's pause-until): terminal, does nothing" [ -z "$(ran)" ]
check "…and says why" grep -q 'PAUSED by the owner (state/pause-until) — terminal for the day, no retry' "$TMP/gate.out"

echo "=== negative proof: without the PAUSED test, a paused day gets a retry ==="
sed 's/\$3=="PAUSED"/$3=="NEVER-THIS"/' "$GATE" > "$TMP/nopause.sh"; chmod +x "$TMP/nopause.sh"
if cmp -s "$GATE" "$TMP/nopause.sh"; then
  bad "SETUP BROKEN — could not remove the PAUSED test, so the negative proof is void"
else
  reset; row PAUSED r1; GATE_BIN="$TMP/nopause.sh" gate
  if [ "$(ran)" = "ran" ]; then ok "PROVEN   without it the PAUSED day is retried, so the section above reads the PAUSED test"
  else bad "NO TEETH — the PAUSED section passed without the PAUSED test ($(ran))"; fi
fi

echo "=== a sweep in flight is waited for, then decided from its own row ==="
reset; hold 3 MAIN-RED-UNFINISHED; gate
check "waited for the in-flight run, then ran the one retry" [ "$(ran)" = "ran" ]
check "…and said it was waiting" grep -q 'is in flight — waiting for its verdict' "$TMP/gate.out"
reset; hold 3 MAIN-GREEN; gate
check "an in-flight run that ends green: nothing to retry" [ -z "$(ran)" ]
reset; hold 3; gate
check "an in-flight run that ends with no row: runs (the sweep records the dead run)" [ "$(ran)" = "ran" ]
reset; hold 30; gate CI_SWEEP_RETRY_WAIT_UNTIL="$(( $(date +%s) + 2 ))"
check "a holder past its ceiling is handed to the sweep's reclaim" [ "$(ran)" = "ran-while-holder-alive" ]
check "…and the gate says so" grep -q 'still running past its ceiling' "$TMP/gate.out"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""

echo "=== negative proof: without the wait, the gate runs the sweep under a live holder ==="
sed 's/^if \[ "\$count" -eq 0 \] && holder="\$(holder_pid)"; then$/if false; then/' "$GATE" > "$TMP/nowait.sh"; chmod +x "$TMP/nowait.sh"
if cmp -s "$GATE" "$TMP/nowait.sh"; then
  bad "SETUP BROKEN — could not remove the wait, so the negative proof is void"
else
  reset; hold 3 MAIN-RED-UNFINISHED; GATE_BIN="$TMP/nowait.sh" gate
  if [ "$(ran)" = "ran-while-holder-alive" ]; then ok "PROVEN   without the wait the sweep runs under the live holder, so the section above reads the wait"
  else bad "NO TEETH — the in-flight section passed without the wait ($(ran))"; fi
  wait "$HOLDER" 2>/dev/null; HOLDER=""
fi

[ "$asserts" -eq 0 ] && { echo "RULE 0 [ASSERTED_NOTHING]"; exit 2; }
echo "=== $asserts assertion(s), $failed failed ==="
[ "$failed" -eq 0 ] || exit 1
echo "the 09:00 gate waits for an in-flight run, decides from its row, and never loses the day's retry."
