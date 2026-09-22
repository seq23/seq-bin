#!/bin/bash
# Notification hook: Claude Code is idle waiting for input or a permission. macOS banner with sound,
# so a "needs you" is seen even when the terminal is behind another window (added 19 Sep 2026).
INPUT="$(cat)"
MSG="$(printf '%s' "$INPUT" | jq -r '.message // "Claude needs you"' 2>/dev/null | head -c 120)"
osascript -e "display notification \"${MSG//\"/}\" with title \"Claude Code\" sound name \"Glass\"" >/dev/null 2>&1
exit 0
