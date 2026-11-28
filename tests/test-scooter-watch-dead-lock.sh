#!/usr/bin/env bash
# A tail lock whose wrapper died with no exit puts its emails back on the queue once, and says so
# (28 Nov 2026: tail 02:53Z died silently; the next dispatch removed its lock and Scooter's Productions reply was lost).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
st="$(mktemp -d)"; trap 'rm -rf "$st"' EXIT
lock="$st/.fix-lock"
# Never a real email from a test: a stub repo whose vault runner just records the call.
mkdir -p "$st/repo/scripts/vault"; printf 'import fs from "fs";const a=process.argv.slice(2);fs.appendFileSync(process.env.SENT_LOG,a.join(" ")+"\\n")\n' > "$st/repo/scripts/vault/vault.mjs"
export SCOOTER_WATCH_REPO="$st/repo" SENT_LOG="$st/sent.log"
setup() { rm -rf "$lock"; mkdir -p "$lock"; printf 'a@x\nb@x\nc@x\n' > "$st/tailed-message-ids.txt"; : > "$st/report.log"
  printf 'a@x\nb@x\n' > "$lock/ids"; echo 2026-11-28T02:53:56Z > "$lock/started_at"; }
# 1. dead wrapper: both ids re-queued, logged, lock gone, exit 10
setup; sh -c 'exit 0' & dead=$!; wait $dead; echo $dead > "$lock/pid"
"$here/scooter-watch-dead-lock.sh" "$lock" "$st" >/dev/null; rc=$?
[ $rc = 10 ] || { echo "FAIL: dead lock rc=$rc, want 10"; fail=1; }
[ "$(cat "$st/tailed-message-ids.txt")" = "c@x" ] || { echo "FAIL: ids not re-queued: $(paste -sd, "$st/tailed-message-ids.txt")"; fail=1; }
grep -q 'died with no exit or report — 2 of 2' "$st/report.log" || { echo "FAIL: no report.log line"; fail=1; }
[ -d "$lock" ] && { echo "FAIL: dead lock not removed"; fail=1; }
# 2. second death of the same emails: not re-queued again (one retry only)
setup; echo $dead > "$lock/pid"
"$here/scooter-watch-dead-lock.sh" "$lock" "$st" >/dev/null
grep -qx 'a@x' "$st/tailed-message-ids.txt" || { echo "FAIL: retried twice"; fail=1; }
grep -q '0 of 2' "$st/report.log" || { echo "FAIL: second death not logged"; fail=1; }
grep -q 'died twice' "$st/sent.log" 2>/dev/null || { echo "FAIL: second death did not email her"; fail=1; }
# 2b. wrapper dead but its agent still running: lock kept, nothing re-queued (no double tail)
setup; : > "$st/retried-message-ids.txt"; echo $dead > "$lock/pid"; sleep 30 & agent=$!; echo $agent > "$lock/claude_pid"
"$here/scooter-watch-dead-lock.sh" "$lock" "$st"; rc=$?; kill $agent 2>/dev/null; wait $agent 2>/dev/null
[ $rc = 0 ] && [ -d "$lock" ] && grep -qx 'a@x' "$st/tailed-message-ids.txt" || { echo "FAIL: a live agent's emails were re-queued (rc=$rc)"; fail=1; }
# 2c. the tailed list cannot be read: it is never wiped
setup; : > "$st/retried-message-ids.txt"; echo $dead > "$lock/pid"; chmod 000 "$st/tailed-message-ids.txt"
"$here/scooter-watch-dead-lock.sh" "$lock" "$st" >/dev/null; chmod 644 "$st/tailed-message-ids.txt"
[ "$(wc -l < "$st/tailed-message-ids.txt" | tr -d ' ')" = 3 ] || { echo "FAIL: a read error wiped the tailed list"; fail=1; }
# 3. live wrapper: nothing touched
setup; sleep 30 & live=$!; echo $live > "$lock/pid"
"$here/scooter-watch-dead-lock.sh" "$lock" "$st"; rc=$?; kill $live 2>/dev/null
[ $rc = 0 ] && [ -d "$lock" ] && [ ! -s "$st/report.log" ] || { echo "FAIL: live lock was touched (rc=$rc)"; fail=1; }
# 4. the watcher calls it before its dispatch branch can remove the lock
n_call="$(grep -n 'scooter-watch-dead-lock.sh' "$here/scooter-watch.sh" | head -1 | cut -d: -f1)"
n_rm="$(grep -n "^ *rm -rf \"\$FIXLOCK\"" "$here/scooter-watch.sh" | head -1 | cut -d: -f1)"
[ -n "$n_call" ] && [ "$n_call" -lt "$n_rm" ] || { echo "FAIL: watcher does not run the dead-lock check before removing the lock"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-dead-lock: OK (a dead tail's emails are re-queued once and logged)"; exit $fail
