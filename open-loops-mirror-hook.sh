#!/bin/bash
# PostToolUse hook (Bash): after any command that touches the Boss OS Open Loops API, rebuild the
# read-only Open Loops page and, if it changed, tell the session to republish the artifact.
# Why: 21 Nov 2026 the page sat 6 hours stale while a session changed loops all day; she caught it.
input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
case "$cmd" in *open-loops-mirror*) exit 0 ;; esac
# Reading files about loops changes nothing (28 Nov 2026: it fired on every grep/sed of the scripts).
case "$cmd" in cat\ *|sed\ *|grep\ *|head\ *|tail\ *|wc\ *|ls\ *|git\ *|cd\ ~/bin\ \&\&\ git*) exit 0 ;; esac
# Only commands that call the API, or run a script that does.
if ! printf '%s' "$cmd" | grep -q "open-loops"; then
  hit=0
  for f in $(printf '%s' "$cmd" | grep -oE '[^ ;&|]+\.mjs'); do
    [ -f "$f" ] && grep -q "api/boss/open-loops" "$f" && hit=1 && break
  done
  [ "$hit" = 1 ] || exit 0
fi
out=$(cd "$HOME/GitHub/boss-os" && npm run -s vault:run -- node "$HOME/bin/open-loops-mirror.mjs" 2>&1 | tail -1)
case "$out" in
  CHANGED*) msg="Open Loops changed. Republish: copy ~/.boss-os/open-loops-mirror/index.html into the scratchpad and publish it with the Artifact tool to url https://claude.ai/artifact/QhkCPRzzuNm9Kd1ystTuDd. Nothing else." ;;
  UNCHANGED*) exit 0 ;;
  NAMED*) msg="Open Loops mirror could not read Boss OS: $out" ;;
  # Anything else (vault, network or node failure) is an outage, never "nothing changed": the page may be stale.
  *) msg="Open Loops mirror could not be rebuilt, so the published page may be stale: ${out:-no output}. Run: cd ~/GitHub/boss-os && npm run -s vault:run -- node ~/bin/open-loops-mirror.mjs" ;;
esac
/usr/bin/python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":sys.argv[1]}}))' "$msg"
