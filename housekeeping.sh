#!/bin/bash
# Nightly Mac housekeeping (launchd com.seq.housekeeping, daily 03:30 Central, after the 01:40 CT
# drive backup). Approved 1 Nov 2026. The checks and the posts live in housekeeping.mjs; this wrapper
# injects BOSS_OPEN_LOOPS_TOKEN from the Boss OS vault at run time (never echoed, one vault read) and
# turns any failure into a named stop the log shows.
#
#   ~/bin/housekeeping.sh                         # the nightly run (posts to Boss OS Open Loops)
#   HOUSEKEEPING_DRY_RUN=1 ~/bin/housekeeping.sh  # print the payloads, post nothing, no vault
#
# It never commits, stashes or discards anything. Log: ~/Library/Logs/housekeeping.log (launchd).
set -u
BIN="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
echo "=== housekeeping $(date '+%Y-%m-%d %H:%M %Z') ==="
if [ "${HOUSEKEEPING_DRY_RUN:-}" = 1 ] || [ "${HOUSEKEEPING_NO_VAULT:-}" = 1 ]; then
  node "$BIN/housekeeping.mjs"; rc=$?
else
  REPO="${BOSS_OS_REPO:-$HOME/.boss-os/runtime}"
  [ -f "$REPO/scripts/vault/vault.mjs" ] || REPO="$HOME/GitHub/boss-os"
  if [ ! -f "$REPO/scripts/vault/vault.mjs" ]; then
    echo "NAMED STOP [NO_VAULT_RUNNER] the Boss OS vault runner was not found in ~/.boss-os/runtime or ~/GitHub/boss-os; nothing was checked or posted." >&2
    exit 3
  fi
  (cd "$REPO" && npm run -s vault:run -- node "$BIN/housekeeping.mjs"); rc=$?
fi
if [ "$rc" -ne 0 ]; then
  echo "NAMED STOP [HOUSEKEEPING_INCOMPLETE] exit $rc; the line above says why. Nothing was committed, stashed or discarded." >&2
fi
exit "$rc"
