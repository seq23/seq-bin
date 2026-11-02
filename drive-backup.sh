#!/bin/zsh
# Nightly backup of Mac-only files to Google Drive (approved 1 Nov 2026: ~5G, no How We Know videos).
# rclone remote "gdrive" (scope drive.file: sees only what it created). Secrets never go up.
# Changed/deleted files are kept in Mac-Backup/_old/<date> for history.
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
D=$(date +%Y-%m-%d); LOG=~/Library/Logs/drive-backup/$D.log; DEST=gdrive:Mac-Backup
EXCL=(--exclude 'vault/**' --exclude '*token*' --exclude '*.env' --exclude '.env*' --exclude '*secret*'
      --exclude '*credential*' --exclude 't2r-test-accounts.txt' --exclude 'browser/**' --exclude 'kdp-profile/**'
      --exclude 'kdp/**' --exclude 'node_modules/**' --exclude '.git/**' --exclude '.DS_Store'
      --exclude '.venv*/**' --exclude 'venv/**' --exclude '__pycache__/**' --exclude 'site-packages/**' --exclude '*.pyc'
      --exclude-if-present pyvenv.cfg)
# Rebuildable Python environments are skipped, whatever the folder is called (pyvenv.cfg marks one):
# 55k tiny files there took 4.5h on the first run (1 Nov). --delete-excluded removes anything already
# in Drive that a later exclude now covers, so a new exclude cleans up after itself.
fail=0
sync() { rclone sync "$1" "$DEST/$2" "${EXCL[@]}" --delete-excluded --backup-dir "$DEST/_old/$D/$2" --transfers 8 --checkers 16 --log-file "$LOG" --log-level NOTICE || fail=1; }
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
rclone copyto ~/HANDOFF.md "$DEST/handoff/HANDOFF-$D.md" --log-file "$LOG" || fail=1
[ -d ~/Notes ] && sync ~/Notes Notes
# Old copies (_old/<date>) are kept 30 days, then removed so Drive does not fill up.
cut=$(date -v-30d +%Y-%m-%d)
rclone lsf --dirs-only "$DEST/_old" 2>/dev/null | tr -d / | while read -r d; do
  [[ "$d" == 20??-??-?? && "$d" < "$cut" ]] && { rclone purge "$DEST/_old/$d" --log-file "$LOG" || fail=1; }
done
find ~/Library/Logs/drive-backup -name '*.log' -mtime +30 -delete
if [ $fail -ne 0 ]; then echo "NAMED STOP: DRIVE_BACKUP_FAILED — see $LOG (if 'token' or 'client_id' errors: reconnect with: rclone config reconnect gdrive:)"; exit 2; fi
echo "drive-backup OK $D"
