#!/bin/bash
# The fixture run of mac-snapshot.sh (macOS only: it needs hdiutil). A fake home, a stub Keychain holding a
# test passphrase and a fake vault key, and a local folder standing in for sequoialtaylor's Drive.
# Proves: the two one-time stops name her exact line; a tampered staging is caught by the verify step and
# nothing is uploaded (so removing the verify step fails this test); the image does not open with a wrong
# passphrase and restores byte-identical with the right one; the upload is confirmed and only the newest 2
# are kept; the key and the passphrase never appear in the log or stdout.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mac-snapshot.sh"
command -v hdiutil >/dev/null || { echo "NAMED STOP [NO_HDIUTIL] this test needs macOS"; exit 3; }
command -v rclone >/dev/null || { echo "NAMED STOP [NO_RCLONE] rclone is not installed"; exit 3; }
T=$(mktemp -d); MNT=""
trap '[ -n "$MNT" ] && hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1; rm -rf "$T"' EXIT
ok=0; bad() { echo "FAIL: $1"; ok=1; }
PASS="test-pass-$RANDOM-Zq7"; KEY="vaultkey-$RANDOM$RANDOM-base64=="
F=$T/home; mkdir -p "$F"/.west-peek-os/vault "$F"/.claude/projects/p/memory "$F"/.claude/skills/s "$F"/.boss-os/deck \
  "$F"/.boss-os/trailers/x/music "$F"/.boss-os/asmr-voice/venv "$F"/.boss-os/runtime "$F"/bin/launchd "$F"/Library/LaunchAgents \
  "$F/Documents/My Folder" "$F"/.codex/sessions "$F"/claude-work/tts "$F"/Misc/node_modules/m
echo enc > "$F"/.west-peek-os/vault/OPENAI.enc; echo rule > "$F"/.claude/CLAUDE.md; echo mem > "$F"/.claude/projects/p/memory/m.md
echo chat > "$F"/.claude/projects/p/chat.jsonl; echo skill > "$F"/.claude/skills/s/SKILL.md; echo deck > "$F"/.boss-os/deck/d.md
head -c 50000 /dev/urandom > "$F"/.boss-os/trailers/x/music/score.mp3; echo render > "$F"/.boss-os/trailers/x/out.mp4
head -c 20000 /dev/urandom > "$F"/.boss-os/asmr-voice/whisper-sample.m4a; touch "$F"/.boss-os/asmr-voice/venv/pyvenv.cfg "$F"/.boss-os/asmr-voice/venv/lib.so
echo code > "$F"/.boss-os/runtime/x.ts; echo '#!/bin/sh' > "$F"/bin/job.sh; echo '<plist/>' > "$F"/Library/LaunchAgents/com.seq.job.plist
echo '<plist/>' > "$F"/Library/LaunchAgents/com.other.plist; echo doc > "$F/Documents/My Folder/a b.txt"
echo 'model = "x"' > "$F"/.codex/config.toml; echo sess > "$F"/.codex/sessions/s.jsonl
echo model > "$F"/claude-work/tts/kokoro-v1.0.onnx; echo py > "$F"/claude-work/tts/render.py; echo dep > "$F"/Misc/node_modules/m/i.js
echo h > "$F"/HANDOFF.md
# The stub Keychain. The secrets live in files, never in its arguments.
printf '%s\n' "$PASS" > "$T/pass"; printf '%s\n' "$KEY" > "$T/key"
cat > "$T/security" <<EOF
#!/bin/bash
svc=""; w=0; while [ \$# -gt 0 ]; do case "\$1" in -s) svc=\$2; shift ;; -w) w=1 ;; esac; shift; done
case "\$svc" in
  mac-snapshot) [ -f "$T/no-pass" ] && exit 44; [ \$w = 1 ] && cat "$T/pass"; exit 0 ;;
  test-vault) [ \$w = 1 ] && cat "$T/key"; exit 0 ;;
esac; exit 44
EOF
chmod +x "$T/security"
mkdir -p "$T/drive/Mac-Snapshots" "$T/tmp"
printf '[gdrive-sl]\ntype = alias\nremote = %s/drive\n' "$T" > "$T/rclone.conf"
export MAC_SNAPSHOT_HOME=$F MAC_SNAPSHOT_SECURITY=$T/security MAC_SNAPSHOT_KEYCHAIN_VAULT=test-vault \
  MAC_SNAPSHOT_NO_NOTIFY=1 MAC_SNAPSHOT_LOGDIR=$T/logs RCLONE_CONFIG=$T/rclone.conf TMPDIR=$T/tmp
run() { bash "$S" --now >> "$T/stdout" 2>&1; }
D=$(date +%Y-%m-%d); IMG=$T/drive/Mac-Snapshots/mac-snapshot-$D.dmg

# 1. No passphrase in the Keychain: her one-time line, nothing built.
touch "$T/no-pass"; run; rc=$?; rm "$T/no-pass"
[ $rc -eq 3 ] || bad "missing passphrase exit $rc (want 3)"
grep -q 'SNAPSHOT_PASSPHRASE_MISSING.*security add-generic-password -s mac-snapshot -a sequoia -w' "$T/stdout" || bad "no passphrase stop with her line"
# 2. Drive not connected: her one-time line.
RCLONE_CONFIG=$T/none.conf bash "$S" --now >> "$T/stdout" 2>&1; rc=$?
[ $rc -eq 3 ] || bad "missing remote exit $rc (want 3)"
grep -q 'SNAPSHOT_DRIVE_NOT_CONNECTED.*rclone config create gdrive-sl drive scope drive.file' "$T/stdout" || bad "no drive stop with her line"
# 3. Staging changed after the image was built: the verify step must refuse it, and nothing goes up.
MAC_SNAPSHOT_TEST_TAMPER=1 run; rc=$?
[ $rc -ne 0 ] || bad "tampered image passed (is the verify step still there?)"
grep -q SNAPSHOT_VERIFY_FAILED "$T/stdout" || bad "no SNAPSHOT_VERIFY_FAILED stop"
[ -e "$IMG" ] && bad "a tampered image was uploaded"
# 4. The real run, with two older snapshots on "Drive": newest 2 kept.
echo old > "$T/drive/Mac-Snapshots/mac-snapshot-2001-01-01.dmg"; echo old > "$T/drive/Mac-Snapshots/mac-snapshot-2001-02-01.dmg"
run; rc=$?
[ $rc -eq 0 ] || bad "fixture run exit $rc"
grep -q "OUTPUT .* files, .* GB staged, image .* GB, uploaded mac-snapshot-$D.dmg" "$T/stdout" || bad "no OUTPUT census line"
grep -q "^.* VERIFIED " "$T/logs/$D.log" || bad "verify step did not run"
[ -s "$IMG" ] || bad "image not uploaded"
[ -e "$T/drive/Mac-Snapshots/mac-snapshot-2001-01-01.dmg" ] && bad "third-newest snapshot kept"
[ -e "$T/drive/Mac-Snapshots/mac-snapshot-2001-02-01.dmg" ] || bad "second-newest snapshot deleted"
grep -q 'NOTIFY .*Mac snapshot done: .* GB, kept 2' "$T/stdout" || bad "no success line for her"
# 5. Without the passphrase the image does not open.
mkdir -p "$T/m1" "$T/m2"
if printf '%s' "wrong-$PASS" | hdiutil attach -stdinpass -readonly -nobrowse -mountpoint "$T/m1" "$IMG" >/dev/null 2>&1; then
  MNT=$T/m1; bad "image opened with a wrong passphrase"; hdiutil detach "$T/m1" -quiet -force; MNT=""
fi
# 6. With it (typed as in Finder: no newline) it restores byte-identical.
if printf '%s' "$PASS" | hdiutil attach -stdinpass -readonly -nobrowse -mountpoint "$T/m2" "$IMG" >/dev/null 2>&1; then
  MNT=$T/m2; R=$T/m2
  for f in .west-peek-os/vault/OPENAI.enc .claude/CLAUDE.md .claude/projects/p/memory/m.md .claude/skills/s/SKILL.md .boss-os/deck/d.md \
           .boss-os/trailers/x/music/score.mp3 .boss-os/asmr-voice/whisper-sample.m4a bin/job.sh Library/LaunchAgents/com.seq.job.plist \
           "Documents/My Folder/a b.txt" .codex/config.toml claude-work/tts/render.py HANDOFF.md; do
    cmp -s "$F/$f" "$R/$f" || bad "not restored byte-identical: $f"
  done
  for f in .claude/projects/p/chat.jsonl .boss-os/trailers/x/out.mp4 .boss-os/asmr-voice/venv/lib.so .boss-os/runtime/x.ts \
           Library/LaunchAgents/com.other.plist .codex/sessions/s.jsonl claude-work/tts/kokoro-v1.0.onnx Misc/node_modules/m/i.js; do
    [ -e "$R/$f" ] && bad "should not be in the snapshot: $f"
  done
  [ "$(cat "$R/_vault-key/test-vault.master-key")" = "$KEY" ] || bad "vault key not in the image"
  [ "$(stat -f %Lp "$R/_vault-key/test-vault.master-key")" = 600 ] || bad "vault key file is not 0600"
  grep -q 'kokoro-onnx/releases' "$R/README-RESTORE.txt" || bad "README has no model source"
  hdiutil detach "$T/m2" -quiet -force; MNT=""
else bad "image did not open with the passphrase"; fi
# 7. No secret in the log or stdout.
grep -rqF "$PASS" "$T/logs" "$T/stdout" && bad "passphrase appears in the log or stdout"
grep -rqF "$KEY" "$T/logs" "$T/stdout" && bad "vault key appears in the log or stdout"
[ $ok -eq 0 ] && echo "test-mac-snapshot: ok"; exit $ok
