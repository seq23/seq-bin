#!/bin/bash
# Fortnightly housekeeping. Reclaims cache and log space and prunes finished git
# state. Touches nothing that is not regenerable: no source, no secrets, no
# uncommitted work, no branch that is not already merged into main.
#
# Written 17 Sep 2026, after a day when ~/.npm/_cacache reached 5.4 GB and
# ~/.wrangler held 87,792 log files. Disk was never the problem that day —
# memory was — but both grow without limit and nothing else trims them.
set -u
LOG=~/Library/Logs/dev-housekeeping.log
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M') ==="
before=$(df -k / | tail -1 | awk '{print $4}')

# Old wrangler logs. One file per invocation, kept forever otherwise.
find ~/.wrangler/logs -type f -mtime +14 -delete 2>/dev/null

# npm's content-addressable cache. Fully regenerable; npm refetches on demand.
npm cache clean --force 2>/dev/null

# Finished git state, per repo. `-d` refuses anything not merged, so unmerged
# work is safe by construction. Worktrees are pruned only when already gone.
for repo in ~/GitHub/*/; do
  [ -d "$repo/.git" ] || continue
  git -C "$repo" worktree prune 2>/dev/null
  git -C "$repo" branch --merged main 2>/dev/null \
    | grep -vE '^\*|^\s*(main|master)$' \
    | xargs -r -n1 git -C "$repo" branch -d 2>/dev/null
done

# Empty per-session scratchpad directories left by finished Claude sessions.
find /private/tmp/claude-501 -maxdepth 2 -type d -empty -delete 2>/dev/null

after=$(df -k / | tail -1 | awk '{print $4}')
echo "reclaimed $(( (after - before) / 1024 )) MB; $(df -h / | tail -1 | awk '{print $4}') free"
