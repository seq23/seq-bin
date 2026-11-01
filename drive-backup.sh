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
      --exclude '.venv*/**' --exclude 'venv/**' --exclude '__pycache__/**' --exclude 'site-packages/**' --exclude '*.pyc')
# Rebuildable Python environments are skipped: 55k tiny files there took 4.5h on the first run (1 Nov).
fail=0
sync() { rclone sync "$1" "$DEST/$2" "${EXCL[@]}" --backup-dir "$DEST/_old/$D/$2" --transfers 8 --checkers 16 --log-file "$LOG" --log-level NOTICE || fail=1; }
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
find ~/Library/Logs/drive-backup -name '*.log' -mtime +30 -delete
if [ $fail -ne 0 ]; then echo "NAMED STOP: DRIVE_BACKUP_FAILED — see $LOG (if 'token' or 'client_id' errors: reconnect with: rclone config reconnect gdrive:)"; exit 2; fi
echo "drive-backup OK $D"
