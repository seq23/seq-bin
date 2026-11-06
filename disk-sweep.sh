#!/bin/bash
# disk-sweep.sh — remove the two known disk leaks and finished worktrees, then check free space.
#
# WHY (6 Nov 2026, ~17:45 CT). Her 228 GB data disk had 1.2 GB free. Two leaks:
#   · Chrome code-sign clones: /var/folders/<..>/X/com.google.Chrome.code_sign_clone held 15 copies of
#     ~1.4 GB (21 GB), one per Chrome launch that day; Chrome leaves them after force-quits.
#   · repair-fixture-* scratch worktrees (~500 MB each) from killed sprylabs-hpc-site validator runs
#     (fixed at source in sprylabs-hpc-site #221; this catches anything older or anything else).
# Boss OS's Kendra duty (boss-os scripts/ops/mac-cleanup.mjs, 09:00 CT) cleans caches and old
# renders; this runs earlier (07:15 CT) and owns only what is listed below.
#
# What it removes, and only this:
#   · code_sign_clone folders older than 24 h, never the newest one (a running Chrome uses it);
#   · $TMPDIR/repair-fixture-* folders older than 24 h (then `git worktree prune` in sprylabs-hpc-site);
#   · ~/GitHub/.wt-* worktrees whose `git status --short` is empty, nothing is unpushed and the branch
#     is merged (HEAD on origin/main, or a merged PR whose head is exactly HEAD), and whose git index
#     has not changed in 6 h (a running agent may still be in it). Anything else is LISTED and left alone.
# Never: how-we-know renders/audio, ~/.cache/huggingface, ~/.colima, Documents, Desktop, Downloads,
# Pictures, Photos, Movies, ~/.Trash. `allowed()` refuses any path outside the three classes above.
#
# Under 15 GB free after the sweep: ONE email a day through Boss OS's existing push
# (`npm run notify` in boss-os, from Simone; the same path mac-cleanup uses). A refused send is
# NAMED STOP [SEND_REFUSED], exit 9.
#
#   ~/bin/disk-sweep.sh            # sweep, check, alert if low
#   ~/bin/disk-sweep.sh --dry-run  # say what it would remove; remove and send nothing
#
# Last line, always: `OUTPUT freed <X> GB, free <Y> GB …` (floor 0: a clean disk needs nothing done).
# Env overrides exist for tests/test-disk-sweep.sh only.
set -uo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
DAY_MIN=1440
IN_USE_MIN="${DISK_SWEEP_IN_USE_MIN:-360}" # a worktree whose git index changed in the last 6 h may belong to a running agent
LOW_GB="${DISK_SWEEP_LOW_GB:-15}"
GITHUB="${DISK_SWEEP_GITHUB:-$HOME/GitHub}"
STATE="${DISK_SWEEP_STATE:-$HOME/.boss-os/disk-sweep}"
DF_PATH="${DISK_SWEEP_DF_PATH:-/System/Volumes/Data}"
GH="${DISK_SWEEP_GH:-gh}"
TODAY="${DISK_SWEEP_TODAY:-$(TZ=America/Chicago date +%F)}"

if [ -n "${DISK_SWEEP_TEMP:-}" ]; then TEMP="$DISK_SWEEP_TEMP"
else TEMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; TEMP="${TEMP%/}"; fi
if [ -n "${DISK_SWEEP_CLONES:-}" ]; then CLONES="$DISK_SWEEP_CLONES"
else CLONES="$(dirname "$TEMP")/X/com.google.Chrome.code_sign_clone"; fi
[ -n "$TEMP" ] && [ -d "$TEMP" ] || { echo "NAMED STOP [NO_TEMP_DIR] the per-user temp folder could not be found ('$TEMP'); nothing swept. Run getconf DARWIN_USER_TEMP_DIR." >&2; exit 2; }

free_kb() { df -Pk "$DF_PATH" 2>/dev/null | awk 'NR==2 {print $4}'; }
gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }
size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }

allowed() {
  local p="$1"
  case "$p" in
    "$CLONES"/*|"$TEMP"/repair-fixture-*|"$GITHUB"/.wt-*) ;;
    *) return 1 ;;
  esac
  case "$p" in
    *how-we-know/renders*|*how-we-know/audio*|*/.cache/huggingface*|*/.colima*|*/Documents*|*/Desktop*|*/Downloads*|*/Pictures*|*/Photos*|*/Movies*|*/.Trash*) return 1 ;;
  esac
  return 0
}

before_kb="$(free_kb)"
[ -n "$before_kb" ] || { echo "NAMED STOP [DF_UNREADABLE] could not read free space on $DF_PATH; nothing swept." >&2; exit 2; }

freed_kb=0; n_clones=0; n_fix=0; n_wt=0; kept=()
remove() { # path label
  local p="$1" k
  allowed "$p" || { echo "REFUSED (outside the sweep's paths): $p" >&2; return 1; }
  k="$(size_kb "$p")"; k="${k:-0}"
  if [ "$DRY" = 1 ]; then echo "would remove ($2, $(gb "$k") GB): $p"
  else rm -rf "$p" && echo "removed ($2, $(gb "$k") GB): $p"; fi
  freed_kb=$((freed_kb + k))
}

# 1. Chrome code-sign clones: keep the newest, remove the rest that are over 24 h old.
if [ -d "$CLONES" ]; then
  newest="$(ls -1td "$CLONES"/*/ 2>/dev/null | head -1)"; newest="${newest%/}"
  while IFS= read -r d; do
    [ -n "$d" ] && [ "$d" != "$newest" ] || continue
    remove "$d" "Chrome clone" && n_clones=$((n_clones + 1))
  done < <(find "$CLONES" -mindepth 1 -maxdepth 1 -type d -mmin +"$DAY_MIN" 2>/dev/null)
fi

# 2. Leaked repair-fixture scratch worktrees.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  remove "$d" "repair fixture" && n_fix=$((n_fix + 1))
done < <(find "$TEMP" -mindepth 1 -maxdepth 1 -type d -name 'repair-fixture-*' -mmin +"$DAY_MIN" 2>/dev/null)
if [ "$n_fix" -gt 0 ] && [ "$DRY" = 0 ] && [ -d "$GITHUB/sprylabs-hpc-site/.git" ]; then
  git -C "$GITHUB/sprylabs-hpc-site" worktree prune 2>/dev/null || true
fi

# 3. Finished worktrees.
merged() { # worktree path; HEAD on origin/main, or a merged PR whose head is exactly HEAD
  local wt="$1" head branch repo
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  git -C "$wt" merge-base --is-ancestor "$head" origin/main 2>/dev/null && return 0
  branch="$(git -C "$wt" symbolic-ref --short -q HEAD)" || return 1
  repo="$(git -C "$wt" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$("$GH" pr list -R "$repo" --head "$branch" --state merged --json headRefOid -q ".[] | select(.headRefOid == \"$head\") | .headRefOid" 2>/dev/null)" ]
}
for wt in "$GITHUB"/.wt-*; do
  [ -d "$wt" ] || continue
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then kept+=("$(basename "$wt") (not a git worktree)"); continue; fi
  # Read before `git status`, which itself rewrites the index.
  idx="$(cd "$wt" && git rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  if [ -n "$idx" ] && [ -n "$(find "$idx" -mmin -"$IN_USE_MIN" 2>/dev/null)" ]; then kept+=("$(basename "$wt") (used in the last $((IN_USE_MIN / 60)) h)"); continue; fi
  git -C "$wt" fetch -q origin 2>/dev/null || true
  if [ -n "$(git -C "$wt" status --short 2>/dev/null)" ]; then kept+=("$(basename "$wt") (uncommitted changes)"); continue; fi
  if ! merged "$wt"; then kept+=("$(basename "$wt") (not merged, or commits not pushed)"); continue; fi
  common="$(cd "$wt" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  k="$(size_kb "$wt")"; k="${k:-0}"
  if [ "$DRY" = 1 ]; then echo "would remove (merged worktree, $(gb "$k") GB): $wt"; freed_kb=$((freed_kb + k)); n_wt=$((n_wt + 1))
  elif git --git-dir="$common" worktree remove "$wt" 2>/dev/null; then echo "removed (merged worktree, $(gb "$k") GB): $wt"; freed_kb=$((freed_kb + k)); n_wt=$((n_wt + 1))
  else kept+=("$(basename "$wt") (git worktree remove refused)"); fi
done
for k in ${kept[@]+"${kept[@]}"}; do echo "left alone: $k"; done

# 4. Free space, and one alert a day when low.
after_kb="$(free_kb)"; [ -n "$after_kb" ] || after_kb="$before_kb"
free_gb="$(gb "$after_kb")"
low=0; awk -v f="$free_gb" -v l="$LOW_GB" 'BEGIN { exit !(f < l) }' && low=1
note=""
if [ "$low" = 1 ]; then
  mkdir -p "$STATE"
  if [ "$DRY" = 1 ]; then note=" · LOW (dry run: no alert sent)"
  elif [ "$(cat "$STATE/alerted-on" 2>/dev/null)" = "$TODAY" ]; then note=" · LOW (already alerted today)"
  else
    body="Your Mac has ${free_gb} GB free after the daily disk sweep, which removed $(gb "$freed_kb") GB of leftover files. Below ${LOW_GB} GB the Mac slows down and scheduled jobs start failing. Nothing to do right now; if this email comes again tomorrow, the space is going somewhere new and Claude should look for it."
    if [ -n "${DISK_SWEEP_NOTIFY:-}" ]; then "$DISK_SWEEP_NOTIFY" "Mac disk: ${free_gb} GB free" "$body"; rc=$?
    else
      BOSS="$HOME/.boss-os/runtime"; [ -f "$BOSS/scripts/ops/notify.mjs" ] || BOSS="$GITHUB/boss-os"
      (cd "$BOSS" && npm run -s notify -- --from Simone --subject "Mac disk: ${free_gb} GB free" --body "$body"); rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      echo "OUTPUT freed $(gb "$freed_kb") GB, free ${free_gb} GB (clones $n_clones, fixtures $n_fix, worktrees $n_wt removed; ${#kept[@]} left alone)"
      echo "NAMED STOP [SEND_REFUSED] free space is ${free_gb} GB (< ${LOW_GB}) and the alert was not sent (exit $rc). Run it by hand from boss-os: npm run notify -- --from Simone --subject 'Mac disk' --body '...'" >&2
      exit 9
    fi
    echo "$TODAY" >"$STATE/alerted-on"; note=" · LOW: alert sent"
  fi
fi
[ "$DRY" = 1 ] && note="${note} · DRY RUN"
echo "OUTPUT freed $(gb "$freed_kb") GB, free ${free_gb} GB (clones $n_clones, fixtures $n_fix, worktrees $n_wt removed; ${#kept[@]} left alone)${note}"
