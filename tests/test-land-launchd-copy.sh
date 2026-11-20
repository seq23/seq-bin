#!/bin/bash
# land's last step for seq-bin fast-forwards the launchd copy: the repo's MAIN checkout (~/bin), never
# the worktree land runs from (20 Nov 2026: from a ~/GitHub/.wt-* worktree it printed a false
# "STOPPED: ... is on <branch>, not main" after a good merge).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BLOCK="$(sed -n '/^# --- launchd begin/,/^# --- launchd end/p' "$HERE/../land")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the launchd block"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
g() { git -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/bin"; g -C "$T/bin" remote add origin "$T/origin.git"
echo one > "$T/bin/land.sh"; g -C "$T/bin" add -A; g -C "$T/bin" commit -q -m one; g -C "$T/bin" push -q origin main
g -C "$T/bin" worktree add -q "$T/.wt-fix" -b fix
echo two > "$T/.wt-fix/land.sh"; g -C "$T/.wt-fix" commit -q -am two; g -C "$T/.wt-fix" push -q origin fix:main
run() { (cd "$1" && git fetch -q origin main && NAME=bin DEPLOY="" SELF="is the launchd copy" PR=7 \
  bash -c 'say(){ echo "$*"; }; die(){ echo "STOPPED: $*"; exit 1; }; '"$BLOCK"' ; echo "FELL THROUGH"') 2>&1 || true; }

# 1. From a worktree on a branch: the main checkout is fast-forwarded and land says LANDED.
out="$(run "$T/.wt-fix")"
grep -q '^LANDED' <<<"$out" || { echo "FAIL: from a worktree, expected LANDED, got: $out"; exit 1; }
! grep -q STOPPED <<<"$out" || { echo "FAIL: false STOPPED from a worktree: $out"; exit 1; }
[ "$(cat "$T/bin/land.sh")" = two ] || { echo "FAIL: the launchd copy was not fast-forwarded"; exit 1; }
# 2. Already at origin/main: LANDED, nothing to do.
out="$(run "$T/bin")"; grep -q 'already at' <<<"$out" || { echo "FAIL: up-to-date copy not reported: $out"; exit 1; }
# 3. The launchd copy itself off main: a true STOPPED naming the main checkout.
g -C "$T/.wt-fix" checkout -q -b more; echo three > "$T/.wt-fix/land.sh"; g -C "$T/.wt-fix" commit -q -am three; g -C "$T/.wt-fix" push -q origin more:main
g -C "$T/bin" checkout -q -b side
out="$(run "$T/.wt-fix")"; grep -q "STOPPED: .*$T/bin is on side" <<<"$out" || { echo "FAIL: launchd copy off main not stopped: $out"; exit 1; }
# 4. Her uncommitted edit to a file the merge changes: STOPPED, her edit untouched.
g -C "$T/bin" checkout -q main; echo hers > "$T/bin/land.sh"
out="$(run "$T/.wt-fix")"; grep -q 'uncommitted local edits' <<<"$out" || { echo "FAIL: overlap not stopped: $out"; exit 1; }
[ "$(cat "$T/bin/land.sh")" = hers ] || { echo "FAIL: her uncommitted edit was touched"; exit 1; }
echo "test-land-launchd-copy: 4 cases passed — the launchd copy is the main checkout, wherever land runs"
