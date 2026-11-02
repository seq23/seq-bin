#!/bin/zsh
# Nightly backup of Mac-only files to Google Drive (approved 1 Nov 2026: ~5G, no How We Know videos).
# rclone remote "gdrive" (scope drive.file: sees only what it created). Secrets never go up.
# Changed/deleted files are kept in Mac-Backup/_old/<date> for history.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
STATE=~/Library/Application\ Support/drive-backup; mkdir -p "$STATE"; SKIPF="$STATE/skip-tonight.txt"; : > "$SKIPF"
MAXSECS=${DRIVE_BACKUP_MAX_SECS:-3600}; START=$(date +%s); BIG=${DRIVE_BACKUP_BIG_FOLDER:-2000}
D=$(date +%Y-%m-%d); LOG=~/Library/Logs/drive-backup/$D.log; DEST=${DRIVE_BACKUP_DEST:-gdrive:Mac-Backup}
EXCL=(--exclude 'vault/**' --exclude '*token*' --exclude '*.env' --exclude '.env*' --exclude '*secret*'
      --exclude '*credential*' --exclude 't2r-test-accounts.txt' --exclude 'browser/**' --exclude 'kdp-profile/**'
      --exclude 'kdp/**' --exclude 'node_modules/**' --exclude '.git/**' --exclude '.DS_Store'
      --exclude '.venv*/**' --exclude 'venv/**' --exclude '__pycache__/**' --exclude 'site-packages/**' --exclude '*.pyc'
      --exclude-if-present pyvenv.cfg
      --exclude '/runtime/**' --exclude '/trailers/**' --exclude '/repo-change/**' --exclude '/tts/**' --exclude '.cache/**' --exclude '.next/**' --exclude '.turbo/**' --exclude 'DerivedData/**'
      --exclude 'Pods/**' --exclude '.pytest_cache/**' --exclude '.mypy_cache/**' --exclude '.parcel-cache/**')
# /runtime is the Boss OS code checkout (~/.boss-os/runtime), already on GitHub. Skipped by her ruling 1 Nov:
# ~/.boss-os/trailers (1.2G generated videos), ~/.boss-os/repo-change (job logs), ~/claude-work/tts (703M voice files).
# The rest are rebuildable caches.
# Rebuildable Python environments are skipped, whatever the folder is called (pyvenv.cfg marks one):
# 55k tiny files there took 4.5h on the first run (1 Nov). --delete-excluded removes anything already
# in Drive that a later exclude now covers, so a new exclude cleans up after itself.
fail=0
# Look before uploading: count files per folder (2 levels deep) on the Mac first. A folder that is new
# with more than $BIG files, or grew by more than $BIG since last night, is skipped tonight and flagged
# (DRIVE_BACKUP_BIG_FOLDER) instead of uploaded for hours. Approve it by adding it to big-folders-ok.txt.
flagged=(); slow=""
precheck() { local src=$1 name=$2 cur="$STATE/counts-${2//\//_}.txt" prev="$STATE/counts-${2//\//_}.prev"
  [ -f "$cur" ] && cp "$cur" "$prev"
  rclone lsf -R --files-only "$src" "${EXCL[@]}" 2>/dev/null | awk -F/ 'NF>1{k=$1; if(NF>2)k=k"/"$2; c[k]++} END{for(k in c)print c[k]"\t"k}' | sort -k2 > "$cur.new"
  if [ -f "$prev" ]; then
    while IFS=$'\t' read -r n k; do
      p=$(awk -F'\t' -v k="$k" '$2==k{print $1}' "$prev"); p=${p:-0}
      grep -qxF "$name/$k" "$STATE/big-folders-ok.txt" 2>/dev/null && continue
      if [ $((n - p)) -gt "$BIG" ]; then echo "/$k/**" >> "$SKIPF"; flagged+=("$name/$k (+$((n - p)) files)"); fi
    done < "$cur.new"
  fi
  mv "$cur.new" "$cur"; }
sync() { : > "$SKIPF"; precheck "$1" "$2"
  local left=$(( MAXSECS - ($(date +%s) - START) )); [ $left -lt 60 ] && { slow=${slow:-$2}; fail=1; return; }
  local ex=("${EXCL[@]}") del=(--delete-excluded); while read -r x; do [ -n "$x" ] && ex+=(--exclude "$x"); done < "$SKIPF"
  # A skipped big folder may already be partly in Drive: never delete it, just do not add to it tonight.
  [ -s "$SKIPF" ] && del=()
  rclone sync "$1" "$DEST/$2" "${ex[@]}" "${del[@]}" --backup-dir "$DEST/_old/$D/$2" --transfers 8 --checkers 16 --max-duration "${left}s" --log-file "$LOG" --log-level NOTICE
  local rc=$?; [ $rc -eq 10 ] && slow=${slow:-$2}; [ $rc -ne 0 ] && fail=1; }
sync ~/.boss-os            boss-os
sync ~/bin                 bin
sync ~/8raise-tools        8raise-tools
sync ~/Misc                Misc
sync "$HOME/Movies/Ask The Flowers" ask-the-flowers
sync ~/claude-work         claude-work
sync ~/codex-briefs        codex-briefs
sync ~/.claude/skills      claude/skills
sync ~/.claude/skills-archive claude/skills-archive
sync ~/.claude/memory-archive claude/memory-archive
for f in CLAUDE.md rules-history.md; do rclone copyto ~/.claude/$f "$DEST/claude/$f" --log-file "$LOG" || fail=1; done
# Only the latest handoff is kept (her call 1 Nov: no pile of dated copies).
rclone copyto ~/HANDOFF.md "$DEST/handoff/HANDOFF.md" --log-file "$LOG" || fail=1
rclone delete "$DEST/handoff" --include 'HANDOFF-*.md' --log-file "$LOG" 2>/dev/null || true
[ -d ~/Notes ] && sync ~/Notes Notes
# Old copies (_old/<date>) are kept 30 days, then removed so Drive does not fill up.
cut=$(date -v-30d +%Y-%m-%d)
rclone lsf --dirs-only "$DEST/_old" 2>/dev/null | tr -d / | while read -r d; do
  [[ "$d" == 20??-??-?? && "$d" < "$cut" ]] && { rclone purge "$DEST/_old/$d" --log-file "$LOG" || fail=1; }
done
find ~/Library/Logs/drive-backup -name '*.log' -mtime +30 -delete
if [ -n "$slow" ]; then echo "NAMED STOP: DRIVE_BACKUP_TOO_SLOW — the run hit its $((MAXSECS/60))-minute limit at $slow; see $LOG"; exit 3; fi
if [ ${#flagged[@]} -gt 0 ]; then printf '%s\n' "${flagged[@]}" > "$STATE/needs-decision.txt"; echo "NAMED STOP: DRIVE_BACKUP_BIG_FOLDER — skipped tonight, not uploaded: ${flagged[*]}. To back one up, add its name to $STATE/big-folders-ok.txt"; exit 4; fi
rm -f "$STATE/needs-decision.txt"
if [ $fail -ne 0 ]; then echo "NAMED STOP: DRIVE_BACKUP_FAILED — see $LOG (if 'token' or 'client_id' errors: reconnect with: rclone config reconnect gdrive:)"; exit 2; fi
echo "drive-backup OK $D"
