#!/bin/bash
# land names the repo from its GitHub remote, not its folder (4 Nov 2026: boss-os's main checkout is
# ~/.boss-os/runtime, so a worktree off it was named "runtime" and land stopped with "no deploy
# route"). A path remote (local or test repos) leaves the folder name in charge.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BLOCK="$(sed -n '/^# --- name begin/,/^# --- name end/p' "$HERE/../land")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the name block"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
name_in() { (cd "$1" && eval "$BLOCK" && printf '%s' "$NAME"); }
git init -q "$T/runtime"; git -C "$T/runtime" remote add origin https://github.com/seq23/boss-os.git
git -C "$T/runtime" commit -q --allow-empty -m x
git -C "$T/runtime" worktree add -q "$T/.wt-job" -b job
[ "$(name_in "$T/runtime")" = boss-os ] || { echo "FAIL: runtime checkout not named boss-os"; exit 1; }
[ "$(name_in "$T/.wt-job")" = boss-os ] || { echo "FAIL: worktree off runtime not named boss-os"; exit 1; }
git init -q "$T/west-peek-os"; git -C "$T/west-peek-os" remote add origin "$T/remote.git"
[ "$(name_in "$T/west-peek-os")" = west-peek-os ] || { echo "FAIL: a path remote renamed the repo"; exit 1; }
git -C "$T/runtime" remote set-url origin git@github.com:seq23/boss-os.git
[ "$(name_in "$T/runtime")" = boss-os ] || { echo "FAIL: ssh remote not read"; exit 1; }
echo "test-land-name: 4 cases passed — the GitHub remote names the repo; a path remote leaves the folder name"
