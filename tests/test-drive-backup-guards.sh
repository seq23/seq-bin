#!/bin/zsh
# Behaviour test for drive-backup.sh guards, against a fake HOME and a local destination (no Drive).
set -u
S=$(cd "$(dirname "$0")/.." && pwd)/drive-backup.sh
T=$(mktemp -d); export HOME=$T DRIVE_BACKUP_DEST=$T/dest DRIVE_BACKUP_BIG_FOLDER=20
mkdir -p $T/8raise-tools "$T/Movies/Ask The Flowers" $T/codex-briefs $T/.claude/skills-archive $T/.claude/memory-archive $T/.boss-os/jobs $T/.boss-os/runtime $T/.boss-os/trailers $T/bin $T/Misc/proj/lib $T/claude-work/tts $T/.claude/skills $T/Library/Logs/drive-backup
touch $T/.boss-os/jobs/a.txt $T/.boss-os/runtime/code.ts $T/.boss-os/trailers/t.mp4 $T/claude-work/tts/v.wav $T/Misc/proj/keep.txt $T/HANDOFF.md
touch $T/Misc/proj/lib/pyvenv.cfg $T/Misc/proj/lib/x.py
for f in CLAUDE.md rules-history.md; do touch $T/.claude/$f; done
ok=0; bad(){ echo "FAIL: $1"; ok=1; }
zsh "$S" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] || bad "baseline run exit $rc"
[ -f $T/dest/boss-os/jobs/a.txt ] || bad "normal file not backed up"
[ -e $T/dest/boss-os/runtime/code.ts ] && bad "runtime backed up"
[ -e $T/dest/boss-os/trailers/t.mp4 ] && bad "trailers backed up"
[ -e $T/dest/claude-work/tts/v.wav ] && bad "tts backed up"
[ -e $T/dest/Misc/proj/lib/x.py ] && bad "python env (pyvenv.cfg) backed up"
# a new folder with 30 files appears: skipped and flagged, not uploaded
mkdir -p $T/Misc/dump/stuff; for i in $(seq 1 30); do touch $T/Misc/dump/stuff/f$i; done
out=$(zsh "$S" 2>&1); rc=$?
[ $rc -eq 4 ] || bad "big new folder exit $rc (want 4)"
print -r -- "$out" | grep -q DRIVE_BACKUP_BIG_FOLDER || bad "no named stop for big folder"
[ -e $T/dest/Misc/dump/stuff/f1 ] && bad "big folder uploaded"
[ -f $T/dest/Misc/proj/keep.txt ] || bad "existing file deleted while a folder was skipped"
# she approves it: next run uploads it
echo "Misc/dump/stuff" > "$T/Library/Application Support/drive-backup/big-folders-ok.txt"
zsh "$S" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] || bad "approved folder run exit $rc"
[ -f $T/dest/Misc/dump/stuff/f1 ] || bad "approved folder not uploaded"
# time limit: no time left -> named stop
out=$(DRIVE_BACKUP_MAX_SECS=0 zsh "$S" 2>&1); rc=$?
[ $rc -eq 3 ] || bad "time limit exit $rc (want 3)"
print -r -- "$out" | grep -q DRIVE_BACKUP_TOO_SLOW || bad "no named stop for time limit"
rm -rf "$T"; [ $ok -eq 0 ] && echo "test-drive-backup-guards: ok"; exit $ok
