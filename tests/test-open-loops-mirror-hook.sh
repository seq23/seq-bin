#!/bin/bash
# open-loops-mirror-hook.sh (PostToolUse): rebuilds the Open Loops page only after a command that touches the
# Open Loops API, tells the session to republish when it CHANGED, and never stays silent on an outage.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; HOOK="${HOOK_UNDER_TEST:-$HERE/../open-loops-mirror-hook.sh}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/GitHub/boss-os" "$W/bin" "$W/scripts"
cat > "$W/bin/npm" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE/npm.calls"
cat "$FAKE/npm.out" 2>/dev/null; exit "$(cat "$FAKE/npm.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$W/bin/npm"
printf 'await fetch(base + "/api/boss/open-loops/42", {method:"PATCH"});\n' > "$W/scripts/close-loop.mjs"
printf 'console.log("hello")\n' > "$W/scripts/other.mjs"
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then echo "  ok   $label"; passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi; }
run() { # $1 command the session ran  $2 mirror output  [$3 mirror rc]
  : > "$W/npm.calls"; printf '%s\n' "$2" > "$W/npm.out"; echo "${3:-0}" > "$W/npm.rc"
  OUT="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | (cd "$W/scripts" && HOME="$W/home" FAKE="$W" PATH="$W/bin:$PATH" bash "$HOOK"))"; RC=$?
}
calls() { [ -s "$W/npm.calls" ]; }
ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' <<<"$OUT" 2>/dev/null; }

run "git status" "CHANGED /x/index.html (3 open)"
check "an unrelated command: no rebuild, no output" eval '[ "$RC" -eq 0 ] && ! calls && [ -z "$OUT" ]'
run "curl -s https://boss/api/boss/open-loops" "CHANGED /x/index.html (3 open)"
check "an Open Loops API call that changed the page: rebuilt, told to republish" eval 'calls && grep -q "open-loops-mirror.mjs" "$W/npm.calls" && ctx | grep -q "^Open Loops changed. Republish the mirror now"'
run "curl -s https://boss/api/boss/open-loops" "UNCHANGED 3 open"
check "an Open Loops call that changed nothing: rebuilt, silent" eval '[ "$RC" -eq 0 ] && calls && [ -z "$OUT" ]'
run "node close-loop.mjs 42" "CHANGED /x/index.html (2 open)"
check "a script that calls the Open Loops API counts too" eval 'calls && ctx | grep -q "^Open Loops changed"'
run "node other.mjs" "CHANGED /x/index.html (2 open)"
check "a script that never touches Open Loops: no rebuild" eval '! calls && [ -z "$OUT" ]'
run "node ~/bin/open-loops-mirror.mjs" "CHANGED /x/index.html (2 open)"
check "the mirror itself: no rebuild (no loop)" eval '! calls && [ -z "$OUT" ]'
run "curl -s https://boss/api/boss/open-loops" "NAMED STOP [LOOPS_UNREADABLE] HTTP 503" 2
check "Boss OS unreadable: the named stop reaches the session" eval 'ctx | grep -q "could not read Boss OS: NAMED STOP \[LOOPS_UNREADABLE\] HTTP 503"'
run "curl -s https://boss/api/boss/open-loops" "TypeError: fetch failed" 1
check "outage (vault, network or node crash): told the page may be stale, never silent" eval 'ctx | grep -q "could not be rebuilt, so the published page may be stale: TypeError: fetch failed"'
run "curl -s https://boss/api/boss/open-loops" "" 1
check "outage with no output at all: still told" eval 'ctx | grep -q "may be stale: no output"'
check "…and the hook still exits 0, so it never blocks the session's command" [ "$RC" -eq 0 ]

[ $((passes+fails)) -ge 10 ] || { echo "FAIL: only $((passes+fails)) checks ran"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-open-loops-mirror-hook: $fails failure(s), $passes passed"; exit 1; }
echo "test-open-loops-mirror-hook: $passes checks passed — the Open Loops page is rebuilt after Open Loops changes only, and an outage is never silent"
