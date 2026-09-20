#!/usr/bin/env python3
"""Turn `claude -p --output-format stream-json --verbose` into a plain-text
round log, LINE BY LINE AS IT HAPPENS, so a round the cap kills still leaves
a transcript of what it tried.

WHY THIS EXISTS. On 2026-09-20 both rounds of the 10:07 sweep hit their caps.
Both round logs were 0 bytes: `claude -p` in its default text mode prints only
the final result, and a process killed by `timeout` has no final result. The
sweep then read the empty log as "the resume died immediately" and burned a
second 25-minute cap on a fresh session that could not see round 1's agent -
while the real state (PR #99 landed, a second root cause exposed at 16:22Z,
a decision needed) was visible only in ~/.claude/projects/*/<session>.jsonl.
"Its silence is not evidence of anything" was true, and the silence was
manufactured by the invocation mode.

The filter keeps: assistant text, every tool call (name + a short argument
digest), every tool result's first line, and the final result. Everything is
flushed per line. The CI-SWEEP-COMPLETE sentinel appears in assistant text, so
the sweep's grep on the round log keeps working unchanged. A line that is not
JSON (a crash trace, a warning) is passed through verbatim - never dropped.
"""
import json
import sys


def digest(value, limit=160):
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    text = text.replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def emit(line):
    sys.stdout.write(line.rstrip("\n") + "\n")
    sys.stdout.flush()


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except ValueError:
            emit(raw)
            continue
        kind = event.get("type")
        if kind == "system":
            # Only the init event says something a reader needs (which session,
            # which cwd); task/thinking bookkeeping is noise in a round log.
            if event.get("subtype") == "init":
                emit(f"[system] init session={event.get('session_id', '')} cwd={event.get('cwd', '')}")
        elif kind == "assistant":
            for block in event.get("message", {}).get("content", []) or []:
                if block.get("type") == "text" and block.get("text", "").strip():
                    emit(block["text"].strip())
                elif block.get("type") == "tool_use":
                    emit(f"[tool] {block.get('name', '?')} {digest(block.get('input', {}))}")
        elif kind == "user":
            for block in event.get("message", {}).get("content", []) or []:
                if block.get("type") == "tool_result":
                    content = block.get("content")
                    if isinstance(content, list):
                        content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
                    first = str(content or "").strip().split("\n", 1)[0]
                    if first:
                        emit(f"[result] {digest(first)}")
        elif kind == "result":
            emit(f"[result:{event.get('subtype', '')}] {digest(event.get('result', ''), 2000)}")
        # rate_limit_event and other bookkeeping carry nothing a reader needs.


if __name__ == "__main__":
    main()
