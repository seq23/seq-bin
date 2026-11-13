#!/bin/bash
# A tail watchdog only ever stops the agent it was started for. 13 Nov 2026: a watchdog whose own
# agent had finished woke at its cap, found the next agent's lock and killed that agent mid-work.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; A=""; B=""; trap 'kill $A $B 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/bin/bash\nexit 0\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" SCOOTER_WATCH_OSASCRIPT=true SCOOTER_WATCH_WATCHDOG_GRACE=0 SCOOTER_WATCH_GH_REPO=example/none
fail() { echo "FAIL: $1"; exit 1; }

# 1. A stale watchdog (started for wrapper 111) meets a later agent's lock (wrapper 222).
L="$T/lock1"; mkdir -p "$L"; sleep 60 & A=$!
echo 222 > "$L/pid"; echo $A > "$L/claude_pid"
"$HERE/scooter-watch-watchdog.sh" 111 1 "$L" "$T/fix1.md" "$T/tail1.log" "$T/report1.txt" "old subject"
kill -0 $A 2>/dev/null || fail "a stale watchdog killed a later agent"
[ -d "$L" ] || fail "a stale watchdog removed a later agent's lock"
[ ! -s "$T/fix1.md" ] || fail "a stale watchdog logged INCOMPLETE for a later agent"
[ ! -s "$T/report1.txt" ] || fail "a stale watchdog wrote a later agent's report"

# 2. The agent's own watchdog still stops it at the cap and says so.
L="$T/lock2"; mkdir -p "$L"; sleep 60 & B=$!
echo 99999999 > "$L/pid"; echo $B > "$L/claude_pid"
"$HERE/scooter-watch-watchdog.sh" 99999999 1 "$L" "$T/fix2.md" "$T/tail2.log" "$T/report2.txt" "its subject"
kill -0 $B 2>/dev/null && fail "the agent's own watchdog did not stop it at the cap"
grep -q "INCOMPLETE" "$T/fix2.md" || fail "the cap kill was not logged"
grep -q "FRICTION_FIXED: 0" "$T/report2.txt" || fail "the cap kill wrote no report"
[ ! -d "$L" ] || fail "its own lock was left behind after the wrapper was gone"
echo "OUTPUT test-scooter-watch-watchdog: 2 cases ok"
