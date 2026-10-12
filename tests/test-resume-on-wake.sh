#!/bin/bash
# ci-sweep-resume-on-wake.sh (owner, 12 Oct 2026: "just pick up where it left off if I
# close the lid and then re-open") against a fake ledger, a fake lock and a fake sweep.
# What is under test is the script's OWN decision; the resumed run itself is exercised
# end to end in tests/test-sweep-daily.sh, scenario 8a.
#   · INTERRUPTED today, budget left, nothing running -> exec the sweep as a RESUME
#     (CI_SWEEP_RESUME_FROM / CI_SWEEP_LEDGER_ID / CI_SWEEP_STARTED_AT / prior awake)
#   · a sweep running (live lock holder)              -> refuse
#   · past the run's stop-by (or too little left)     -> refuse, left for the 09:00 retry
#   · the 240-awake-minute ceiling nearly spent       -> refuse
#   · today's latest row is KILLED / GREEN / none     -> refuse
#   · a row already resumed once (resumed-by=)        -> resumes from the LATEST attempt
#   · resume.log stays bounded
# RULE 0: zero assertions is not a pass. The holder refusal is proven negatively: with
# the holder check removed, the script resumes under a live sweep.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESUME="$ROOT/ci-sweep-resume-on-wake.sh"
[ -x "$RESUME" ] || { echo "NAMED STOP [MISSING] $RESUME"; exit 3; }
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^CI_SWEEP_')
unset XPC_SERVICE_NAME

TMP="$(mktemp -d)"
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$TMP"' EXIT
asserts=0; failed=0
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

LOGS="$TMP/logs"; LEDGER="$LOGS/state/outcomes.tsv"; LOCK="$LOGS/.lock"
# The fake sweep records the resume environment it was started with.
cat > "$TMP/sweep" <<'FAKE'
#!/bin/bash
echo "from=$CI_SWEEP_RESUME_FROM ledger=$CI_SWEEP_LEDGER_ID started=$CI_SWEEP_STARTED_AT prior=$CI_SWEEP_PRIOR_AWAKE_SECS" >> "$FAKE_RAN"
FAKE
chmod +x "$TMP/sweep"
export FAKE_RAN="$TMP/ran"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%s)"
hm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M; }
# run <id> <verdict> <stop-by epoch> [beats] [col5]: a ledger row, its log's stop-by line,
# and <beats> sentry heartbeats in its work dir
run() {
  local id="$1" verdict="$2" sb="$3" beats="${4:-30}" extra="${5:-}"
  printf '%s\t%s\t%s\t%s%s\n' "$NOW" "$TODAY" "$verdict" "$id" "${extra:+	$extra}" >> "$LEDGER"
  echo "[08:00:00] budget: 210 min (stop by $(hm "$sb")); rounds while progress" > "$LOGS/$id.log"
  mkdir -p "$LOGS/$id.d"; seq 1 "$beats" > "$LOGS/$id.d/heartbeats"
}
reset() { rm -rf "$LOGS" "$FAKE_RAN"; mkdir -p "$LOGS/state"; : > "$LEDGER"; }
resume() { env CI_SWEEP_LOG_DIR="$LOGS" CI_SWEEP_BIN="$TMP/sweep" "$@" "${RESUME_BIN:-$RESUME}" > "$TMP/out" 2>&1; }
ran() { cat "$FAKE_RAN" 2>/dev/null; }
hold() { mkdir -p "$LOCK"; echo r1 > "$LOCK/run-id"; ( sleep 30 ) & HOLDER=$!; echo "$HOLDER" > "$LOCK/pid"; }
unhold() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""; rm -rf "$LOCK"; }
LATER=$(( NOW + 2 * 3600 ))

echo "=== an INTERRUPTED run with budget left is resumed ==="
reset; run r1 MAIN-RED-INTERRUPTED "$LATER" 30; resume
check "the sweep was started" grep -q . "$FAKE_RAN"
check "…as a resume of r1, answering to r1's ledger row" grep -q '^from=r1 ledger=r1 ' "$FAKE_RAN"
started="$(ran | sed -n 's/.* started=\([0-9]*\) .*/\1/p')"
check "…with r1's stop-by kept (STARTED_AT = stop-by - 210 min, to the minute)" [ $(( (LATER - started - 210 * 60) / 60 )) -eq 0 ]
check "…with r1's awake time counted (30 beats x 20 s = 600 s)" grep -q 'prior=600$' "$FAKE_RAN"
check "…and the decision is logged" grep -q 'RESUMING r1 (attempt r1) after sleep' "$LOGS/resume.log"

echo "=== refusals ==="
reset; run r1 MAIN-RED-INTERRUPTED "$LATER"; hold; resume
check "a sweep running (live lock holder): refuses" [ -z "$(ran)" ]
check "…and says so" grep -q 'no-op: a sweep is running' "$TMP/out"
unhold
reset; run r1 MAIN-RED-INTERRUPTED "$(( NOW - 60 ))"; resume
check "after stop-by: refuses" [ -z "$(ran)" ]
check "…left INTERRUPTED for the 09:00 retry" grep -q 'left INTERRUPTED; the 09:00 retry' "$TMP/out"
reset; run r1 MAIN-RED-INTERRUPTED "$(( NOW + 10 * 60 ))"; resume
check "10 min before stop-by (under the 20-min floor): refuses" [ -z "$(ran)" ]
reset; run r1 MAIN-RED-INTERRUPTED "$LATER" 690; resume
check "230 of 240 awake minutes spent: refuses (the hard kill is never extended)" [ -z "$(ran)" ]
check "…and says why" grep -q 'has spent 13800s awake' "$TMP/out"
reset; run r1 MAIN-RED-KILLED "$LATER"; resume
check "latest row KILLED (a signal, not a sleep): refuses" [ -z "$(ran)" ]
reset; run r1 MAIN-RED-INTERRUPTED "$LATER"; run r2 MAIN-GREEN "$LATER"; resume
check "the latest row is GREEN (an earlier INTERRUPTED one is history): refuses" [ -z "$(ran)" ]
reset; resume
check "no row today: refuses" [ -z "$(ran)" ]
check "…with one line" [ "$(grep -c . "$LOGS/resume.log")" -eq 1 ]

echo "=== a run already resumed once resumes from its LATEST attempt ==="
reset; run r1 MAIN-RED-INTERRUPTED "$LATER" 30 resumed-by=r2
mkdir -p "$LOGS/r2.d"; seq 1 10 > "$LOGS/r2.d/heartbeats"; echo 600 > "$LOGS/r2.d/prior-awake-secs"
echo "[09:00:00] budget: 210 min (stop by $(hm "$LATER"))" > "$LOGS/r2.log"
resume
check "resumes attempt r2, still answering to r1's row" grep -q '^from=r2 ledger=r1 ' "$FAKE_RAN"
check "…awake time accumulates across attempts (600 + 10 x 20 = 800 s)" grep -q 'prior=800$' "$FAKE_RAN"

echo "=== the dry run decides and starts nothing ==="
reset; run r1 MAIN-RED-INTERRUPTED "$LATER"; resume CI_SWEEP_RESUME_DRY_RUN=1
check "dry run: nothing started" [ -z "$(ran)" ]
check "…but says it would resume" grep -q 'dry-run: would resume r1' "$TMP/out"

echo "=== resume.log is bounded ==="
reset; for _ in 1 2 3 4 5 6; do resume CI_SWEEP_RESUME_LOG_KEEP=3; done
check "kept to the last 3 lines" [ "$(grep -c . "$LOGS/resume.log")" -eq 3 ]

echo "=== negative proof: without the holder check, it resumes under a live sweep ==="
sed 's/^if holder="\$(holder_pid)"; then$/if false; then/' "$RESUME" > "$TMP/noholder.sh"; chmod +x "$TMP/noholder.sh"
if cmp -s "$RESUME" "$TMP/noholder.sh"; then
  bad "SETUP BROKEN — could not remove the holder check, so the negative proof is void"
else
  reset; run r1 MAIN-RED-INTERRUPTED "$LATER"; hold; RESUME_BIN="$TMP/noholder.sh" resume
  if [ -n "$(ran)" ]; then ok "PROVEN   without it a resume starts under the live holder, so the refusal above reads the holder check"
  else bad "NO TEETH — the running-sweep refusal passed without the holder check"; fi
  unhold
fi

[ "$asserts" -eq 0 ] && { echo "RULE 0 [ASSERTED_NOTHING]"; exit 2; }
echo "=== $asserts assertion(s), $failed failed ==="
[ "$failed" -eq 0 ] || exit 1
echo "resume-on-wake resumes an INTERRUPTED run within its budget, as the same attempt, and refuses everything else."
