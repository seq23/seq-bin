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
if used is None and d.get("transcript_path"):
    # Fallback (14 Nov 2026): a background-job session passes no context_window, so read the
    # newest assistant turn's usage from the transcript: input + cache read + cache write = context.
    try:
        with open(d["transcript_path"], "rb") as f:
            f.seek(0, 2); f.seek(max(0, f.tell() - 400_000))
            for line in reversed(f.read().decode("utf-8", "ignore").splitlines()):
                if '"usage"' not in line: continue
                u = (json.loads(line).get("message") or {}).get("usage") or {}
                t = (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
                if t:
                    size = size or 1_000_000; used = t; pct = used * 100 / size; break
    except Exception: pass
parts = [c(model, "1")]
if used is not None:
    k = f"{used//1000}K/{size//1000}K ({pct:.0f}%)"
    # 22 Nov 2026 (her ask, token review): yellow from 150K, red + HAND OFF at 200K.
    col = "31;1" if used >= 200_000 else "33" if used >= 150_000 else "32"
    tag = "  ← HAND OFF" if used >= 200_000 else ""
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
