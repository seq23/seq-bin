#!/bin/bash
# Puts ~/bin (and so ~/bin/gh, the shared GitHub allowance) first on PATH in LOGIN shells too.
#
# WHY (22 Nov 2026, measured). ~/bin/gh only shares the allowance for callers that find it first, and only
# her interactive zsh did (~/.zshrc). Every launchd job runs `bash -lc` / `zsh -lc` (mac-window, the
# one-offs), and Codex runs each command in `zsh -lc`: macOS's path_helper (/etc/profile, /etc/zprofile)
# rebuilds PATH with /opt/homebrew/bin ahead of ~/bin, and ~/.zprofile's `brew shellenv` puts it first
# again. So the repo lane, the grid and audit scripts, alarm/outside-locks watchers and every `land` they
# started reached Homebrew's gh directly: uncounted, unshared, never held at the floor, and `gh run watch`
# at its own 3 s poll. That is the ~4,700 REST calls an hour that went around the wrapper.
#
# The fix is one marked line at the END of ~/.zprofile (zsh login) and ~/.bash_profile (bash login), the
# files those shells read after path_helper and brew. Idempotent: a file that already has the line is left
# alone; everything else in it is kept.
#
#   ~/bin/install-gh-share.sh           # add the line where it is missing
#   ~/bin/install-gh-share.sh --check   # change nothing; exit 1 (and say which) if a login shell misses ~/bin/gh
#
# GH_SHARE_HOME exists for tests/test-gh-share.sh only.
set -euo pipefail
H="${GH_SHARE_HOME:-$HOME}"
MARK='# gh-share: ~/bin first in login shells (seq-bin install-gh-share.sh)'
LINE='export PATH="$HOME/bin:$PATH"'
missing=0
for f in "$H/.zprofile" "$H/.bash_profile"; do
  if [ -f "$f" ] && grep -qF "$MARK" "$f"; then continue; fi
  if [ "${1:-}" = --check ]; then echo "MISSING: $f has no gh-share PATH line (run ~/bin/install-gh-share.sh)"; missing=1; continue; fi
  printf '\n%s\n%s\n' "$MARK" "$LINE" >> "$f"
  echo "added the gh-share PATH line to $f"
done
# the proof: a clean login shell of each kind finds the wrapper, not Homebrew's gh
for sh in /bin/bash /bin/zsh; do
  got="$(env -i HOME="$H" PATH=/usr/bin:/bin "$sh" -lc 'command -v gh' 2>/dev/null || true)"
  if [ "$got" != "$H/bin/gh" ]; then echo "MISSING: $sh -lc finds '${got:-no gh}', not $H/bin/gh"; missing=1; fi
done
[ "$missing" = 0 ] && echo "OUTPUT gh-share: login shells (bash, zsh) find $H/bin/gh first"
exit "$missing"
