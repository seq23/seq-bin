#!/usr/bin/env bash
# 27 Nov 2026: ai-run's 3600 s default stopped a tail at 1 h, under its 2 h watchdog, and the email was
# never looked at. The wrapper must give ai-run the watchdog budget less 5 min, and re-queue a capped
# email exactly once. Runs the real wrapper with a fake ai-run.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/state"
cat > "$d/ai-run" <<'FAKE'
#!/usr/bin/env bash
env > "$(dirname "$0")/env.seen"; exit "${FAKE_RC:-0}"
FAKE
chmod +x "$d/ai-run"
run() { mkdir -p "$d/lock"; echo prompt > "$d/prompt"; echo "<m1@x>" > "$d/lock/ids"; : > "$d/state/report.txt"
  HOME="$d" FAKE_RC="$1" SCOOTER_WATCH_FIX_CAP=7200 bash "$here/scooter-watch-run-fix.sh" "$d/prompt" "$d/state/tail.log" "$d/lock" "$d/ai-run" "" "" >/dev/null 2>&1; }
echo "<m1@x>" > "$d/state/tailed-message-ids.txt"
run 124
grep -qx 'AI_RUN_MAX_SECS=6900' "$d/env.seen" || { echo "FAIL: ai-run cap is not the watchdog budget less 5 min: $(grep AI_RUN_MAX_SECS "$d/env.seen")"; fail=1; }
grep -qxF '<m1@x>' "$d/state/tailed-message-ids.txt" && { echo "FAIL: a capped email stayed marked tailed (never retried)"; fail=1; }
echo "<m1@x>" >> "$d/state/tailed-message-ids.txt"
run 124
grep -qxF '<m1@x>' "$d/state/tailed-message-ids.txt" || { echo "FAIL: a second cap re-queued the email again (retry loop)"; fail=1; }
echo "<m2@x>" > "$d/state/tailed-message-ids.txt"; sed -i.bak 's/m1/m2/' "$d/state/retried-message-ids.txt" 2>/dev/null; : > "$d/state/retried-message-ids.txt"
mkdir -p "$d/lock"; echo prompt > "$d/prompt"; echo "<m2@x>" > "$d/lock/ids"
HOME="$d" FAKE_RC=0 bash "$here/scooter-watch-run-fix.sh" "$d/prompt" "$d/state/tail.log" "$d/lock" "$d/ai-run" "" "" >/dev/null 2>&1
grep -qxF '<m2@x>' "$d/state/tailed-message-ids.txt" || { echo "FAIL: a finished run re-queued its email"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-cap: OK (6900 s cap, one retry, no loop)"; exit $fail
