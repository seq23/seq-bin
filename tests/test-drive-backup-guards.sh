#!/bin/zsh
# Behaviour test for drive-backup.sh guards, against a fake HOME and a local destination (no Drive).
set -u
S=$(cd "$(dirname "$0")/.." && pwd)/drive-backup.sh
T=$(mktemp -d); export HOME=$T DRIVE_BACKUP_DEST=$T/dest DRIVE_BACKUP_BIG_FOLDER=20
mkdir -p $T/Work/8raise-tools "$T/Movies/Ask The Flowers" $T/Work/codex-briefs $T/.claude/skills-archive $T/.claude/memory-archive $T/.boss-os/deck $T/.boss-os/capital $T/.boss-os/asmr-voice/venv $T/.boss-os/runtime $T/Library/LaunchAgents $T/.claude/projects/p1/memory $T/Work/proj/node_modules/m $T/Work/proj/venv $T/.boss-os/trailers $T/bin $T/Work/Misc/proj/lib $T/Work/claude-work/tts $T/.claude/skills $T/Library/Logs/drive-backup
touch $T/.boss-os/deck/a.txt $T/.boss-os/capital/private.txt $T/.boss-os/asmr-voice/whisper-sample.m4a $T/.boss-os/asmr-voice/venv/pyvenv.cfg $T/.boss-os/asmr-voice/venv/big.so "$T/Movies/Ask The Flowers/v1.mp4" $T/Library/LaunchAgents/com.seq.x.plist $T/.claude/projects/p1/memory/m.md $T/.claude/projects/p1/chat.jsonl $T/.boss-os/runtime/code.ts $T/.boss-os/trailers/t.mp4 $T/Work/claude-work/tts/v.wav $T/Work/claude-work/notes.md $T/Work/Misc/proj/keep.txt $T/HANDOFF.md
touch $T/Work/proj/a.txt $T/Work/proj/node_modules/m/i.js $T/Work/proj/venv/pyvenv.cfg $T/Work/proj/venv/lib.so
touch $T/Work/Misc/proj/lib/pyvenv.cfg $T/Work/Misc/proj/lib/x.py
for f in CLAUDE.md rules-history.md; do touch $T/.claude/$f; done
ok=0; bad(){ echo "FAIL: $1"; ok=1; }
# Folders an earlier version uploaded, which the 8 Nov split no longer covers: they must leave Drive.
mkdir -p $T/dest/boss-os/capital $T/dest/ask-the-flowers $T/dest/_old/2099-01-01/boss-os/capital $T/dest/claude-work $T/dest/Misc $T/dest/8raise-tools $T/dest/codex-briefs
touch $T/dest/claude-work/o $T/dest/Misc/o $T/dest/8raise-tools/o $T/dest/codex-briefs/o
touch $T/dest/boss-os/capital/old.txt $T/dest/ask-the-flowers/v0.mp4 $T/dest/_old/2099-01-01/boss-os/capital/old.txt
zsh "$S" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] || bad "baseline run exit $rc"
[ -f $T/dest/boss-os/deck/a.txt ] || bad "Boss OS working file not backed up"
[ -f $T/dest/boss-os/asmr-voice/whisper-sample.m4a ] || bad "voice sample not backed up"
[ -e $T/dest/boss-os/asmr-voice/venv/big.so ] && bad "asmr-voice venv backed up"
[ -e $T/dest/boss-os/capital/private.txt ] && bad "capital (private) backed up"
[ -e $T/dest/boss-os/capital ] && bad "capital left on Drive"
[ -e $T/dest/_old/2099-01-01/boss-os/capital ] && bad "capital left in _old"
[ -e $T/dest/ask-the-flowers ] && bad "Ask The Flowers left on Drive"
[ -f $T/dest/Work/proj/a.txt ] || bad "Work not backed up"
[ -e $T/dest/Work/proj/node_modules/m/i.js ] && bad "Work node_modules backed up"
[ -e $T/dest/Work/proj/venv/lib.so ] && bad "Work venv backed up"
[ -f $T/dest/LaunchAgents/com.seq.x.plist ] || bad "launchd plist not backed up"
[ -f $T/dest/claude/memory/p1/memory/m.md ] || bad "Claude memory file not backed up"
[ -e $T/dest/claude/memory/p1/chat.jsonl ] && bad "chat history backed up"
[ -e $T/dest/boss-os/runtime/code.ts ] && bad "runtime backed up"
[ -e $T/dest/boss-os/trailers/t.mp4 ] && bad "trailers backed up"
[ -e $T/dest/Work/claude-work/tts/v.wav ] && bad "tts backed up"
[ -e $T/dest/Work/claude-work/tts ] && bad "tts folder on Drive"
[ -f $T/dest/Work/claude-work/notes.md ] || bad "claude-work (now under Work) not backed up"
[ -f $T/dest/Work/Misc/proj/keep.txt ] || bad "Misc (now under Work) not backed up"
[ -e $T/dest/Work/Misc/proj/lib/x.py ] && bad "python env (pyvenv.cfg) backed up"
for d in claude-work Misc 8raise-tools codex-briefs; do [ -e $T/dest/$d ] && bad "old top-level $d left on Drive"; done
# a new folder with 30 files appears: skipped and flagged, not uploaded
mkdir -p $T/Work/Misc/dump/stuff; for i in $(seq 1 30); do touch $T/Work/Misc/dump/stuff/f$i; done
out=$(zsh "$S" 2>&1); rc=$?
[ $rc -eq 4 ] || bad "big new folder exit $rc (want 4)"
print -r -- "$out" | grep -q DRIVE_BACKUP_BIG_FOLDER || bad "no named stop for big folder"
[ -e $T/dest/Work/Misc/dump/stuff/f1 ] && bad "big folder uploaded"
[ -f $T/dest/Work/Misc/proj/keep.txt ] || bad "existing file deleted while a folder was skipped"
# she approves it: next run uploads it
echo "Work/Misc/dump" > "$T/Library/Application Support/drive-backup/big-folders-ok.txt"
zsh "$S" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] || bad "approved folder run exit $rc"
[ -f $T/dest/Work/Misc/dump/stuff/f1 ] || bad "approved folder not uploaded"
# The move into ~/Work: a folder that was already backed up on its own (last count 25 files as
# codex-briefs/archive) is not a big new folder; its old count is used once, then dropped.
ST="$T/Library/Application Support/drive-backup"
printf '25\tarchive\n' > "$ST/counts-codex-briefs.txt"
mkdir -p $T/Work/codex-briefs/archive; for i in $(seq 1 25); do touch $T/Work/codex-briefs/archive/b$i; done
zsh "$S" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] || bad "moved folder taken for a big new folder (exit $rc)"
[ -f $T/dest/Work/codex-briefs/archive/b1 ] || bad "moved folder not uploaded"
[ -e "$ST/counts-codex-briefs.txt" ] && bad "old count of a moved folder kept"
# ...but a big folder that is really new under a moved one is still held back
mkdir -p $T/Work/claude-work/new/x; for i in $(seq 1 30); do touch $T/Work/claude-work/new/x/n$i; done
zsh "$S" >/dev/null 2>&1; rc=$?
[ $rc -eq 4 ] || bad "big new folder under a moved one exit $rc (want 4)"
[ -e $T/dest/Work/claude-work/new/x/n1 ] && bad "big new folder under a moved one uploaded"
rm -rf $T/Work/claude-work/new
# time limit: no time left -> named stop
out=$(DRIVE_BACKUP_MAX_SECS=0 zsh "$S" 2>&1); rc=$?
[ $rc -eq 3 ] || bad "time limit exit $rc (want 3)"
print -r -- "$out" | grep -q DRIVE_BACKUP_TOO_SLOW || bad "no named stop for time limit"
rm -rf "$T"; [ $ok -eq 0 ] && echo "test-drive-backup-guards: ok"; exit $ok
