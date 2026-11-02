#!/bin/bash
# Install every launchd job versioned in ~/bin/launchd, at the CENTRAL times written in each file.
#
# WHY (1 Nov 2026, the approved weekly schedule). Her Mac runs on Eastern and launchd reads a plist's
# Hour in the Mac's own zone. These files were copied in as written, so the CI sweep "Monday and
# Friday 08:00 CT" really fired at 07:00 Central, and every other job here an hour early. Boss OS's
# installer had already fixed this for its own jobs (26 Oct 2026): it writes Central hours and moves
# each one to the Mac's zone just before loading. This routes ~/bin through the SAME mechanism,
# boss-os scripts/ops/plist-central.mjs, so there is one rule and one implementation.
#
#   ~/bin/install-launchd.sh            # install all (copy, move to the Mac's zone, lint, reload)
#   ~/bin/install-launchd.sh <label>…   # just these
#
# Every file is parsed by plutil before it is loaded; a file that will not parse is a NAMED STOP.
# When her Mac changes zone, tz-watch.sh (com.seq.tz-watch) runs this again for every label but its own.
# LAUNCHD_SRC / LAUNCH_AGENTS_DIR / LAUNCHCTL exist for tests/test-tz-watch.sh only.
# Boss OS's Schedule page (☰ More → Schedule) lists each job; `npm run schedule:check` in boss-os
# fails if one fires at another time.
set -euo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LAUNCHD_SRC:-$BIN/launchd}"
AGENTS="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LCTL="${LAUNCHCTL:-launchctl}"
# The mover from main: Boss OS's runtime checkout (synced to main every 10 min), else her checkout.
BOSS="${BOSS_OS_REPO:-$HOME/.boss-os/runtime}"
[ -f "$BOSS/scripts/ops/plist-central.mjs" ] || BOSS="$HOME/GitHub/boss-os"
CENTRAL="$BOSS/scripts/ops/plist-central.mjs"
[ -f "$CENTRAL" ] || { echo "NAMED STOP [NO_PLIST_CENTRAL] $CENTRAL not found: the Central-time mover lives in boss-os. Nothing installed." >&2; exit 2; }
labels=("$@")
if [ ${#labels[@]} -eq 0 ]; then
  for f in "$SRC"/*.plist; do labels+=("$(basename "$f" .plist)"); done
fi
[ ${#labels[@]} -gt 0 ] || { echo "NAMED STOP [NOTHING_TO_INSTALL] no plist in $SRC" >&2; exit 2; }
mkdir -p "$AGENTS"
for label in "${labels[@]}"; do
  src="$SRC/$label.plist"
  [ -f "$src" ] || { echo "NAMED STOP [NO_SUCH_JOB] $src" >&2; exit 2; }
  dst="$AGENTS/$label.plist"
  cp "$src" "$dst"
  node "$CENTRAL" "$dst"
  plutil -lint "$dst" >/dev/null || { echo "NAMED STOP [PLIST_MALFORMED] $dst; not loaded." >&2; exit 1; }
  "$LCTL" bootout "gui/$(id -u)/$label" 2>/dev/null || true
  "$LCTL" bootstrap "gui/$(id -u)" "$dst"
  echo "installed $label"
done
"$LCTL" list | grep -E "$(IFS='|'; echo "${labels[*]}")" || { echo "NAMED STOP [NOT_LOADED] none of the jobs is listed by launchctl" >&2; exit 1; }
