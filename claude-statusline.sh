#!/bin/bash
# Claude Code status line: model · context used · weekly usage. Reads the JSON Claude passes on stdin.
CLAUDE_STATUS_JSON="$(cat)" python3 - <<'PY'
import sys, json, datetime
import os
try: d = json.loads(os.environ.get("CLAUDE_STATUS_JSON") or "{}")
except Exception: print("claude"); sys.exit()
def c(s, col): return f"\033[{col}m{s}\033[0m"
model = (d.get("model") or {}).get("display_name", "?")
cw = d.get("context_window") or {}
size = cw.get("context_window_size") or 0
pct = cw.get("used_percentage")
used = int(size * pct / 100) if size and pct is not None else None
parts = [c(model, "1")]
if used is not None:
    k = f"{used//1000}K/{size//1000}K ({pct:.0f}%)"
    col = "31;1" if used >= 700_000 else "33" if used >= 450_000 else "32"
    tag = "  ← HAND OFF" if used >= 450_000 else ""
    parts.append("ctx " + c(k + tag, col))
rl = d.get("rate_limits") or {}
wk = rl.get("seven_day") or {}
if wk.get("used_percentage") is not None:
    p = wk["used_percentage"]
    reset = ""
    if wk.get("resets_at"):
        reset = " ↻ " + datetime.datetime.fromtimestamp(wk["resets_at"]).strftime("%a %H:%M")
    col = "31;1" if p >= 80 else "33" if p >= 60 else "32"
    parts.append("week " + c(f"{p:.0f}%{reset}", col))
fh = rl.get("five_hour") or {}
if fh.get("used_percentage") is not None:
    parts.append(f"5h {fh['used_percentage']:.0f}%")
print("  │  ".join(parts))
PY
