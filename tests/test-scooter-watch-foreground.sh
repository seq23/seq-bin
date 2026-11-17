#!/usr/bin/env bash
# The headless tail agent runs with background tasks off, so a wait can never end its turn and idle it
# to the 2h cap (17 Nov 2026, west-peek-os#494). Runs the real wrapper with a fake ai-run that records its env.
set -u
here="$(dirname "$0")/.."; fail=0
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/state" "$d/lock"; echo "prompt" > "$d/prompt"
cat > "$d/ai-run" <<'FAKE'
#!/usr/bin/env bash
env > "$(dirname "$0")/env.seen"
FAKE
chmod +x "$d/ai-run"
HOME="$d" bash "$here/scooter-watch-run-fix.sh" "$d/prompt" "$d/state/tail.log" "$d/lock" "$d/ai-run" "" "" >/dev/null 2>&1
[ -f "$d/env.seen" ] || { echo "FAIL: the wrapper never launched the agent"; exit 1; }
grep -qx 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1' "$d/env.seen" || { echo "FAIL: the tail agent runs with background tasks on"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-foreground: OK (background tasks off)"; exit $fail
