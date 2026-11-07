#!/bin/bash
# Behaviour test for disk-sweep.sh against fake temp, clone and GitHub folders (no network, no mail).
# Proves: old Chrome clones go but the newest stays even when old; fresh ones stay; old
# repair-fixture-* go, fresh stay; a merged clean worktree goes; dirty, unpushed and unmerged ones
# stay and are listed; --dry-run removes nothing; low space sends ONE alert a day; a refused alert
# is NAMED STOP exit 9; the last line is the OUTPUT census.
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/disk-sweep.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
G=(git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false)
fail=0; bad(){ echo "FAIL: $1"; fail=1; }
old(){ touch -t 202601010000 "$1"; }

setup() {
  rm -rf "$T/w"; mkdir -p "$T/w/temp" "$T/w/X/clones" "$T/w/gh" "$T/w/state"
  for c in a b c; do mkdir -p "$T/w/X/clones/code_sign_clone.$c/Chrome.app"; head -c 2048 /dev/zero >"$T/w/X/clones/code_sign_clone.$c/Chrome.app/bin"; done
  old "$T/w/X/clones/code_sign_clone.a"; touch -t 202601020000 "$T/w/X/clones/code_sign_clone.b"   # both old; b newest
  mkdir -p "$T/w/temp/repair-fixture-old/tree" "$T/w/temp/repair-fixture-new" "$T/w/temp/other-old"
  old "$T/w/temp/repair-fixture-old"; old "$T/w/temp/other-old"
  # A repo, its origin, and four worktrees.
  "${G[@]}" init -q --bare "$T/w/origin.git"
  "${G[@]}" clone -q "$T/w/origin.git" "$T/w/gh/repo" 2>/dev/null
  echo base >"$T/w/gh/repo/a"; "${G[@]}" -C "$T/w/gh/repo" add a; "${G[@]}" -C "$T/w/gh/repo" commit -qm base; "${G[@]}" -C "$T/w/gh/repo" push -q origin main
  for b in merged dirty unpushed unmerged; do "${G[@]}" -C "$T/w/gh/repo" worktree add -q "$T/w/gh/.wt-$b" -b "$b" origin/main 2>/dev/null; done
  echo x >"$T/w/gh/.wt-dirty/a"
  echo y >"$T/w/gh/.wt-unpushed/b"; "${G[@]}" -C "$T/w/gh/.wt-unpushed" add b; "${G[@]}" -C "$T/w/gh/.wt-unpushed" commit -qm local
  echo z >"$T/w/gh/.wt-unmerged/c"; "${G[@]}" -C "$T/w/gh/.wt-unmerged" add c; "${G[@]}" -C "$T/w/gh/.wt-unmerged" commit -qm pushed; "${G[@]}" -C "$T/w/gh/.wt-unmerged" push -q origin unmerged 2>/dev/null
  for b in merged dirty unpushed unmerged; do old "$("${G[@]}" -C "$T/w/gh/.wt-$b" rev-parse --path-format=absolute --git-path index)"; done
  printf '#!/bin/sh\nexit 0\n' >"$T/w/gh-stub"; chmod +x "$T/w/gh-stub"
  printf '#!/bin/sh\necho "$1" >>"%s/w/sent"\nexit "${NOTIFY_RC:-0}"\n' "$T" >"$T/w/notify-stub"; chmod +x "$T/w/notify-stub"
}
run() { DISK_SWEEP_TEMP="$T/w/temp" DISK_SWEEP_CLONES="$T/w/X/clones" DISK_SWEEP_GITHUB="$T/w/gh" \
  DISK_SWEEP_STATE="$T/w/state" DISK_SWEEP_DF_PATH="$T" DISK_SWEEP_GH="$T/w/gh-stub" \
  DISK_SWEEP_NOTIFY="$T/w/notify-stub" DISK_SWEEP_TODAY=2026-11-07 bash "$S" "$@" >"$T/out" 2>&1; echo $? >"$T/rc"; }

# Dry run: nothing removed, but it names what it would remove.
setup; DISK_SWEEP_LOW_GB=0 run --dry-run
[ "$(cat "$T/rc")" = 0 ] || bad "dry run exit $(cat "$T/rc"): $(tail -3 "$T/out")"
[ -d "$T/w/X/clones/code_sign_clone.a" ] && [ -d "$T/w/temp/repair-fixture-old" ] && [ -d "$T/w/gh/.wt-merged" ] || bad "dry run removed something"
grep -q "would remove (Chrome clone" "$T/out" || bad "dry run did not name the old clone"
tail -1 "$T/out" | grep -q '^OUTPUT freed .* GB, free .* GB.*DRY RUN' || bad "dry run last line is not the OUTPUT census: $(tail -1 "$T/out")"

# Real run, space fine.
setup; DISK_SWEEP_LOW_GB=0 run
[ "$(cat "$T/rc")" = 0 ] || bad "real run exit $(cat "$T/rc"): $(tail -3 "$T/out")"
[ ! -d "$T/w/X/clones/code_sign_clone.a" ] || bad "old non-newest clone a was kept"
[ -d "$T/w/X/clones/code_sign_clone.c" ] || bad "the newest clone (c) was removed"
[ ! -d "$T/w/X/clones/code_sign_clone.b" ] || bad "old non-newest clone b was kept"
[ ! -d "$T/w/temp/repair-fixture-old" ] || bad "old repair-fixture folder was kept"
[ -d "$T/w/temp/repair-fixture-new" ] || bad "fresh repair-fixture folder was removed"
[ -d "$T/w/temp/other-old" ] || bad "an unrelated temp folder was removed"
[ ! -d "$T/w/gh/.wt-merged" ] || bad "merged clean worktree was kept"
for b in dirty unpushed unmerged; do
  [ -d "$T/w/gh/.wt-$b" ] || bad "$b worktree was removed"
  grep -q "left alone: .wt-$b (" "$T/out" || bad "$b worktree not listed"
  if grep -q "left alone: .wt-$b (used" "$T/out"; then bad "$b worktree was kept only for being recent, so its own rule went untested"; fi
done
[ ! -s "$T/w/sent" ] || bad "an alert was sent while space was fine"
tail -1 "$T/out" | grep -q '^OUTPUT freed .* GB, free .* GB (clones 2, fixtures 1, worktrees 1 removed; 3 left alone)$' || bad "census wrong: $(tail -1 "$T/out")"

# A merged worktree an agent touched recently stays.
setup; touch "$("${G[@]}" -C "$T/w/gh/.wt-merged" rev-parse --path-format=absolute --git-path index)"; DISK_SWEEP_LOW_GB=0 run
[ -d "$T/w/gh/.wt-merged" ] && grep -q "left alone: .wt-merged (used" "$T/out" || bad "a merged worktree used minutes ago was removed"

# Newest clone survives even when it is old.
setup; old "$T/w/X/clones/code_sign_clone.c"; touch -t 202601030000 "$T/w/X/clones/code_sign_clone.c"; DISK_SWEEP_LOW_GB=0 run
[ -d "$T/w/X/clones/code_sign_clone.c" ] || bad "the newest clone was removed because it was old"

# Low space: one alert, then none the same day; a refused alert is exit 9.
setup; DISK_SWEEP_LOW_GB=999999 run
[ "$(cat "$T/rc")" = 0 ] && [ "$(wc -l <"$T/w/sent")" -eq 1 ] || bad "low space did not send exactly one alert (rc $(cat "$T/rc"))"
DISK_SWEEP_LOW_GB=999999 run
[ "$(wc -l <"$T/w/sent")" -eq 1 ] || bad "a second alert was sent the same day"
setup; NOTIFY_RC=5 DISK_SWEEP_LOW_GB=999999 run
[ "$(cat "$T/rc")" = 9 ] && grep -q "NAMED STOP \[UPDATE_REFUSED\]" "$T/out" || bad "a refused alert was not NAMED STOP exit 9 (rc $(cat "$T/rc"))"

# No temp folder: named stop, never a green run.
DISK_SWEEP_TEMP="$T/nope" bash "$S" >"$T/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q "NAMED STOP \[NO_TEMP_DIR\]" "$T/out" || bad "missing temp dir was not NAMED STOP exit 2 (rc $rc)"

[ "$fail" = 0 ] && echo "PASS: disk-sweep.sh behaviour (dry run, clones, fixtures, worktrees, alert once, refused alert)"
exit "$fail"
