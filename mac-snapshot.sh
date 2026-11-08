#!/bin/bash
# Twice-monthly ENCRYPTED full snapshot of what lives only on this Mac (her rulings 8 Nov 2026):
# one AES-256 disk image, uploaded to sequoialtaylor@gmail.com's Drive (rclone remote "gdrive-sl",
# scope drive.file), folder Mac-Snapshots, newest 2 kept. launchd com.seq.mac-snapshot, 1st and 15th
# at 10:00 Central. Unlike the nightly drive-backup.sh (seq.taylor's Drive), this one carries the Boss OS
# vault AND its master key, which otherwise exists only in this Mac's login Keychain.
#
#   ~/bin/mac-snapshot.sh --now        # a run now (the scheduled run is the same thing)
#   ~/bin/mac-snapshot.sh --measure    # how big the snapshot would be (staging bytes, no image, no upload)
#   ~/bin/mac-snapshot.sh --set-passphrase  # hidden pop-up (twice), saved to the Keychain item mac-snapshot/sequoia
#   ~/bin/mac-snapshot.sh --own-client # gdrive-sl uses the same own Google OAuth client as gdrive, then sign in
#   tests/test-mac-snapshot.sh         # the fixture run: tiny image, test passphrase, local "Drive"
#
# Media rule (her call 8 Nov 2026): only irreplaceable sources (recorded voice samples, reference audio,
# original footage). Never rendered videos, Python environments or downloadable models: the README inside
# the image says where the models come from. ~/Movies/Ask The Flowers is left out: checked 8 Nov 2026, it
# holds only rendered exports (trailer v1-v5, _review renders, contact sheets) made from the sources in
# ~/.boss-os/trailers/ask-the-flowers (build.sh, music, voice, frames), which are in.
#
# Secrets: the vault key and the passphrase go from `security … -w` straight into a 0600 file in staging
# or a pipe into hdiutil -stdinpass. Neither is ever an argument, an environment variable or a log line.
# Rule 0: exit 0 only after an image was built, opened read-only with the passphrase, matched staging file
# for file and byte for byte, uploaded, and its size on Drive confirmed. Anything else is a NAMED STOP.
#
# Test-only overrides: MAC_SNAPSHOT_HOME (sources), MAC_SNAPSHOT_SECURITY (a stub for /usr/bin/security),
# MAC_SNAPSHOT_REMOTE, MAC_SNAPSHOT_NO_NOTIFY=1, MAC_SNAPSHOT_TEST_TAMPER=1 (adds a file after the image
# is built, so the verify step must catch it), MAC_SNAPSHOT_KEYCHAIN_VAULT (service name).
set -uo pipefail
umask 077
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:---now}"
case "$MODE" in --now|--measure|--set-passphrase|--own-client) ;; *) echo "usage: mac-snapshot.sh [--now|--measure|--set-passphrase|--own-client]" >&2; exit 64 ;; esac
H="${MAC_SNAPSHOT_HOME:-$HOME}"
SECURITY="${MAC_SNAPSHOT_SECURITY:-/usr/bin/security}"
REMOTE="${MAC_SNAPSHOT_REMOTE:-gdrive-sl}"
DEST="$REMOTE:Mac-Snapshots"
KEEP=2
VAULT_SERVICE="${MAC_SNAPSHOT_KEYCHAIN_VAULT:-west-peek-os-vault}"   # boss-os scripts/vault/vault.mjs
MAXSECS="${MAC_SNAPSHOT_MAX_SECS:-10800}"
START=$(date +%s)
D=$(date +%Y-%m-%d); NAME="mac-snapshot-$D.dmg"
LOGDIR="${MAC_SNAPSHOT_LOGDIR:-$HOME/Library/Logs/mac-snapshot}"; mkdir -p "$LOGDIR"; LOG="$LOGDIR/$D.log"
# A bare `security add-generic-password … -w` run from a `!` prompt saved a BLANK passphrase (8 Nov 2026):
# the pop-up below is the only route offered.
# shellcheck disable=SC2088  # shown to her as text, not expanded
PASS_LINE='~/bin/mac-snapshot.sh --set-passphrase'
DRIVE_LINE='rclone config create gdrive-sl drive scope drive.file'

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

# The one channel ~/bin jobs reach her by: a Boss OS Open Loops row (open-loops.mjs, token from the vault,
# as tz-watch.sh does), plus a macOS banner. One row, stop MAC_SNAPSHOT: a failure opens it, success closes it.
notify() {  # $1 = ok|stop  $2 = one line  $3 = what to do (stop only)  $4 = owner
  local body
  if [ "$1" = ok ]; then
    body=$(node -e 'console.log(JSON.stringify({repo:"seq23/seq-bin",business:"personal",owner:"claude",stop:"MAC_SNAPSHOT",cleared:true,title:process.argv[1],finish_line:"a verified encrypted snapshot is on sequoialtaylor'"'"'s Drive"}))' "$2")
  else
    body=$(node -e 'console.log(JSON.stringify({repo:"seq23/seq-bin",business:"personal",owner:process.argv[3],stop:"MAC_SNAPSHOT",title:process.argv[1],next_step:process.argv[2].slice(0,400),finish_line:"a verified encrypted snapshot is on sequoialtaylor'"'"'s Drive"}))' "$2" "$3" "$4")
  fi
  if [ "${MAC_SNAPSHOT_NO_NOTIFY:-}" = 1 ]; then log "NOTIFY (test, not sent) $body"; return 0; fi
  osascript -e "display notification \"${2//\"/}\" with title \"Mac snapshot\"" >/dev/null 2>&1 || true
  local vr="$HOME/.boss-os/runtime"; [ -f "$vr/scripts/vault/vault.mjs" ] || vr="$HOME/GitHub/boss-os"
  if ! (cd "$vr" && npm run -s vault:run -- node "$BIN/open-loops.mjs" "$body") >>"$LOG" 2>&1; then
    log "NAMED STOP [SNAPSHOT_NOTIFY_FAILED] the Open Loops row could not be posted; the banner was shown."
  fi
}

stop() {  # $1 = code  $2 = one line  $3 = what to do  $4 = owner (default claude)  $5 = exit code
  log "NAMED STOP [$1] $2 — $3"
  notify stop "Mac snapshot stopped: $2" "[$1] $3 Log: $LOG" "${4:-claude}"
  exit "${5:-2}"
}

left() { echo $(( MAXSECS - ($(date +%s) - START) )); }
# Bounded step: perl's alarm kills the step when the run's time is up (macOS has no timeout(1)).
bounded() {
  local l; l=$(left); [ "$l" -gt 30 ] || return 142
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$l" "$@"
}

STAGE=""; MNT=""
cleanup() {
  if [ -n "$MNT" ] && mount | grep -qF " on $MNT "; then hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 || true; fi
  [ -n "$STAGE" ] && rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'stop SNAPSHOT_INTERRUPTED "the run was interrupted" "Run it again: ~/bin/mac-snapshot.sh --now" claude 130' INT TERM

# The passphrase never leaves a pipe. -w prints it with a trailing newline; Finder's prompt has none.
passphrase() { "$SECURITY" find-generic-password -s mac-snapshot -a sequoia -w 2>/dev/null | tr -d '\n'; }

# ─── What goes in ──────────────────────────────────────────────────────────────────────────────────────
# Rebuildable everywhere: dependency folders, caches, Python environments, compiled files.
COMMON=(--exclude node_modules/ --exclude '.venv*/' --exclude venv/ --exclude site-packages/
        --exclude __pycache__/ --exclude '*.pyc' --exclude .cache/ --exclude .next/ --exclude .turbo/
        --exclude DerivedData/ --exclude Pods/ --exclude .pytest_cache/ --exclude .mypy_cache/
        --exclude .parcel-cache/ --exclude .DS_Store)
# source (relative to home) | extra rsync excludes, ";"-separated
SOURCES=(
  ".west-peek-os/vault|"
  ".claude|*.jsonl;/sessions/;/file-history/;/paste-cache/;/cache/;/shell-snapshots/;/session-env/;/telemetry/;/chrome/;/statsig/;/todos/;/plugins/cache/"
  ".boss-os|/runtime/;/browser/;/kdp-profile/;/repo-change/;/trailers/**.mp4;/trailers/**.MP4"
  # Work holds 8raise-tools, Misc, claude-work and codex-briefs (moved there 8 Nov 2026): listed once.
  "Work|/claude-work/tts/*.onnx;/claude-work/tts/voices-*.bin"
  "Notes|"
  "bin|"
  "Library/Application Support/tz-watch|"
  "Library/Application Support/drive-backup|"
  "Desktop|"
  "Documents|"
  "Downloads|"
  "HANDOFF.md|"
)
CODEX_FILES=(config.toml AGENTS.md)   # ~/.codex config only, never its sessions

stage() {  # $1 = staging root
  local root=$1 spec src extra ex x venv
  for spec in "${SOURCES[@]}"; do
    src=${spec%%|*}; extra=${spec#*|}
    [ -e "$H/$src" ] || { log "not on this Mac, skipped: ~/$src"; continue; }
    ex=("${COMMON[@]}")
    IFS=';' read -r -a xs <<< "$extra"
    for x in "${xs[@]+"${xs[@]}"}"; do [ -n "$x" ] && ex+=(--exclude "$x"); done
    if [ -d "$H/$src" ]; then
      # A Python environment is skipped whatever it is called (pyvenv.cfg marks one).
      while IFS= read -r venv; do ex+=(--exclude "/${venv#"$H/$src/"}/"); done < <(
        find "$H/$src" \( -name node_modules -o -name .git \) -prune -o -name pyvenv.cfg -print 2>/dev/null | sed 's#/pyvenv.cfg$##')
      mkdir -p "$root/$src"
      # A file that vanishes mid-copy (moved or deleted while we read) is noted, not fatal; any other error is.
      if ! bounded rsync -a "${ex[@]}" "$H/$src/" "$root/$src/" 2>"$root/../rsync.err"; then
        cat "$root/../rsync.err" >> "$LOG"
        grep -v 'No such file or directory' "$root/../rsync.err" | grep -q . && return 1
        log "$src: $(grep -c . "$root/../rsync.err") files vanished while being copied (moved during the run)"
      fi
    else
      mkdir -p "$root/$(dirname "$src")"; cp -p "$H/$src" "$root/$src" || return 1
    fi
  done
  mkdir -p "$root/Library/LaunchAgents" "$root/.codex"
  for x in "$H"/Library/LaunchAgents/com.seq.*.plist; do [ -f "$x" ] && cp -p "$x" "$root/Library/LaunchAgents/"; done
  for x in "${CODEX_FILES[@]}"; do [ -f "$H/.codex/$x" ] && cp -p "$H/.codex/$x" "$root/.codex/"; done
  if [ -d "$H/.codex/skills" ]; then rsync -a "${COMMON[@]}" "$H/.codex/skills/" "$root/.codex/skills/" || return 1; fi
  cat > "$root/README-RESTORE.txt" <<'EOF'
Mac snapshot — how to restore (built by ~/bin/mac-snapshot.sh, seq23/seq-bin)

New Mac, step by step:
1. Download the newest mac-snapshot-YYYY-MM-DD.dmg from sequoialtaylor@gmail.com's Drive, folder
   Mac-Snapshots. Double-click it and type the snapshot passphrase (in your password manager).
2. Copy the folders back to your home folder (~). Each sits here at its own place under ~
   (.boss-os, .claude, bin, Desktop, Documents, Downloads, Library/LaunchAgents, ...).
3. Vault and key back. Copy .west-peek-os/vault to ~/.west-peek-os/vault, then run this in Terminal
   and, when it asks for the password, paste the one line in _vault-key/west-peek-os-vault.master-key:
     security add-generic-password -s west-peek-os-vault -a master-key -A -w
   Check it: cd ~/GitHub/boss-os && npm run -s vault:status
4. Sign in again: Google (rclone config reconnect gdrive: and gdrive-sl:), GitHub (gh auth login),
   Claude Code, Codex (codex login), the browser and KDP profiles, the Snapshot passphrase item
   (security add-generic-password -s mac-snapshot -a sequoia -w).
5. git clone the repos into ~/GitHub (gh repo list seq23), including seq23/boss-os, whose runtime
   checkout is ~/.boss-os/runtime. Then ~/bin/install-launchd.sh puts the scheduled jobs back.

Not in the snapshot on purpose (rebuildable or downloadable):
- Python environments (venv, .venv): python3 -m venv venv && pip install the project's packages.
- node_modules: npm install in the project.
- ~/Work/claude-work/tts models (Kokoro TTS, used by kokoro_onnx in render.py): kokoro-v1.0.onnx and
  voices-v1.0.bin from https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0
- Rendered videos: the .mp4 files in ~/.boss-os/trailers (made again by its build.sh from the music,
  voice and frames kept here) and ~/Movies/Ask The Flowers (rendered exports only).
- ~/.boss-os/runtime (seq23/boss-os on GitHub), ~/.boss-os/repo-change (job logs), browser and KDP
  sign-in profiles, Claude and Codex chat history.
EOF
}

census() {  # $1 = dir -> "files bytes" (regular files only; the volume's own housekeeping is not ours)
  find "$1" \( -path "$1/.fseventsd" -o -path "$1/.Spotlight-V100" -o -path "$1/.Trashes" -o -path "$1/.TemporaryItems" \) -prune \
    -o -type f -print0 | xargs -0 stat -f %z 2>/dev/null | awk '{n++; s+=$1} END {printf "%d %.0f\n", n, s}'
}

# Hidden pop-up, asked twice; stored through `security -i` on stdin, so it is never an argument any
# process list can show. A blank or short answer is refused.
if [ "$MODE" = --set-passphrase ]; then
  ask() { osascript -e "text returned of (display dialog \"$1\" default answer \"\" with hidden answer with title \"Mac snapshot\")" 2>/dev/null; }
  p1=$(ask "Snapshot passphrase (at least 12 characters). Save it in your password manager too: without it the backup cannot be opened.") || { echo "cancelled; nothing saved" >&2; exit 1; }
  p2=$(ask "Type the same passphrase again.") || { echo "cancelled; nothing saved" >&2; exit 1; }
  [ "$p1" = "$p2" ] || { echo "NAMED STOP [SNAPSHOT_PASSPHRASE_MISMATCH] the two did not match; nothing saved. Run it again." >&2; exit 1; }
  [ ${#p1} -ge 12 ] || { echo "NAMED STOP [SNAPSHOT_PASSPHRASE_SHORT] under 12 characters; nothing saved." >&2; exit 1; }
  case "$p1" in *'"'*|*\\*) echo "NAMED STOP [SNAPSHOT_PASSPHRASE_CHARS] please avoid \" and \\ in it; nothing saved." >&2; exit 1 ;; esac
  printf 'add-generic-password -U -s mac-snapshot -a sequoia -w "%s"\n' "$p1" | "$SECURITY" -i >/dev/null 2>&1
  unset p1 p2
  n=$(passphrase | wc -c | tr -d ' ')
  [ "$n" -ge 12 ] || { echo "NAMED STOP [SNAPSHOT_PASSPHRASE_NOT_SAVED] the Keychain did not keep it; run it again." >&2; exit 1; }
  echo "Saved: the Keychain item mac-snapshot/sequoia holds a $n-character passphrase."; exit 0
fi
# rclone's shared Google client is being retired during 2026. gdrive already has her own OAuth client;
# this copies its client_id/secret into gdrive-sl (file to file, never an argument) and signs in again.
if [ "$MODE" = --own-client ]; then
  conf=$(rclone config file | tail -1)
  node - "$conf" <<'JS' || exit 1
const fs = require("fs"); const f = process.argv[2]; const t = fs.readFileSync(f, "utf8");
const sec = (n) => (t.match(new RegExp(`^\\[${n}\\]\\n([\\s\\S]*?)(?=^\\[|(?![\\s\\S]))`, "m")) || [])[1] || "";
const val = (body, k) => (body.match(new RegExp(`^${k}[ \\t]*=[ \\t]*(.*)$`, "m")) || [])[1]?.trim() || "";
const g = sec("gdrive"), id = val(g, "client_id"), secret = val(g, "client_secret");
if (!id || !secret) { console.error("NAMED STOP [NO_OWN_CLIENT] gdrive has no client_id/client_secret to copy: make one first (see ~/bin/README.md, Google OAuth client for rclone)."); process.exit(1); }
if (!/^\[gdrive-sl\]$/m.test(t)) { console.error("NAMED STOP [SNAPSHOT_DRIVE_NOT_CONNECTED] there is no gdrive-sl remote."); process.exit(1); }
let s = sec("gdrive-sl").replace(/^client_(id|secret)[ \t]*=.*\n/gm, "");
s = `client_id = ${id}\nclient_secret = ${secret}\n` + s;
fs.writeFileSync(f, t.replace(sec("gdrive-sl"), s), { mode: 0o600 });
console.log("gdrive-sl now uses your own Google OAuth client.");
JS
  echo "A browser opens: sign in as sequoialtaylor@gmail.com and allow access."
  rclone config reconnect gdrive-sl: && rclone about gdrive-sl: | head -3; exit $?
fi

log "=== mac-snapshot $MODE $(date '+%Y-%m-%d %H:%M %Z') ==="
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mac-snapshot.XXXXXX") || stop SNAPSHOT_NO_STAGING "no temp folder" "Check the disk."
chmod 700 "$STAGE"; mkdir -p "$STAGE/root"

if [ "$MODE" = --measure ]; then
  stage "$STAGE/root" || stop SNAPSHOT_STAGE_FAILED "copying the files failed" "Read the log." claude 2
  read -r n b < <(census "$STAGE/root")
  log "OUTPUT measure $n files $(awk -v b="$b" 'BEGIN{printf "%.2f", b/1e9}') GB staged (no image built, nothing uploaded)"
  exit 0
fi

# ─── Preconditions (before any copying) ────────────────────────────────────────────────────────────────
# Present AND not blank (a blank item was saved once, 8 Nov 2026). Only the length is ever looked at.
plen=$(passphrase | wc -c | tr -d ' ')
[ "${plen:-0}" -ge 8 ] ||
  stop SNAPSHOT_PASSPHRASE_MISSING "the snapshot passphrase is not set (or is blank)" "Run this once in Terminal; a hidden pop-up asks for it twice. Save the same passphrase in your password manager: $PASS_LINE" sequoia 3
rclone listremotes 2>/dev/null | grep -qx "$REMOTE:" ||
  stop SNAPSHOT_DRIVE_NOT_CONNECTED "sequoialtaylor's Drive is not connected" "Run this once in Terminal and sign in as sequoialtaylor@gmail.com: $DRIVE_LINE" sequoia 3

# ─── Stage ─────────────────────────────────────────────────────────────────────────────────────────────
stage "$STAGE/root" || stop SNAPSHOT_STAGE_FAILED "copying the files into staging failed or ran out of time" "Read the log for the rsync error."
mkdir -p "$STAGE/root/_vault-key"
( umask 077; "$SECURITY" find-generic-password -s "$VAULT_SERVICE" -a master-key -w > "$STAGE/root/_vault-key/$VAULT_SERVICE.master-key" 2>/dev/null )
[ -s "$STAGE/root/_vault-key/$VAULT_SERVICE.master-key" ] ||
  stop SNAPSHOT_VAULT_KEY_UNREADABLE "the vault master key could not be read from the Keychain" "Unlock the login Keychain (or allow the prompt) and run ~/bin/mac-snapshot.sh --now."
chmod 600 "$STAGE/root/_vault-key/$VAULT_SERVICE.master-key"
read -r SN SB < <(census "$STAGE/root")
[ "${SN:-0}" -gt 0 ] || stop SNAPSHOT_EMPTY "staging holds 0 files" "Read the log: every source was missing."
GB=$(awk -v b="$SB" 'BEGIN{printf "%.1f", b/1e9}')
log "staged $SN files, $SB bytes"

# ─── Disk check: the image needs room next to staging ─────────────────────────────────────────────────
free_kb=$(df -k "$STAGE" | awk 'NR==2{print $4}')
[ "$free_kb" -gt $(( SB / 1024 + 1048576 )) ] || stop SNAPSHOT_DISK_LOW "the Mac has $((free_kb/1048576)) GB free, the image needs about $GB GB" "Free disk space on the Mac and run ~/bin/mac-snapshot.sh --now."

# ─── Image ─────────────────────────────────────────────────────────────────────────────────────────────
IMG="$STAGE/$NAME"
passphrase | bounded hdiutil create -quiet -encryption AES-256 -stdinpass -format UDZO -fs HFS+ \
  -volname "Mac Snapshot $D" -srcfolder "$STAGE/root" "$IMG" >>"$LOG" 2>&1
[ -s "$IMG" ] || stop SNAPSHOT_IMAGE_FAILED "the encrypted image could not be built" "Read the log for the hdiutil error."
[ "${MAC_SNAPSHOT_TEST_TAMPER:-}" = 1 ] && echo tamper > "$STAGE/root/tamper.txt"

# ─── Verify: open it read-only with the passphrase and match staging ──────────────────────────────────
verify() {
  MNT="$STAGE/mnt"; mkdir -p "$MNT"
  passphrase | bounded hdiutil attach -stdinpass -readonly -nobrowse -noverify -mountpoint "$MNT" "$IMG" >>"$LOG" 2>&1 || return 1
  local in_n in_b st_n st_b
  read -r in_n in_b < <(census "$MNT"); read -r st_n st_b < <(census "$STAGE/root")
  hdiutil detach "$MNT" -quiet >>"$LOG" 2>&1 || hdiutil detach "$MNT" -quiet -force >>"$LOG" 2>&1
  MNT=""
  log "verify: image $in_n files $in_b bytes, staging $st_n files $st_b bytes"
  [ "$in_n" = "$st_n" ] && [ "$in_b" = "$st_b" ] || return 1
  log "VERIFIED $in_n files $in_b bytes"
}
verify || stop SNAPSHOT_VERIFY_FAILED "the image did not open, or did not match the files" "Nothing was uploaded. Read the log and run ~/bin/mac-snapshot.sh --now."
SIZE=$(stat -f %z "$IMG"); IGB=$(awk -v b="$SIZE" 'BEGIN{printf "%.1f", b/1e9}')

# ─── Room on Drive, before anything is deleted ────────────────────────────────────────────────────────
free=$(rclone about "$REMOTE:" --json 2>>"$LOG" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.free??"")}catch{console.log("")}})')
[ -n "$free" ] || stop SNAPSHOT_DRIVE_UNREADABLE "could not read the free space on sequoialtaylor's Drive" "If the log says token or invalid_grant, reconnect once: rclone config reconnect gdrive-sl:" sequoia
# The same day's earlier copy is replaced, so its bytes count as free.
same=$(rclone lsjson "$DEST/$NAME" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s)[0]?.Size??0)}catch{console.log(0)}})')
[ $(( free + same )) -gt "$SIZE" ] ||
  stop SNAPSHOT_DRIVE_FULL "sequoialtaylor's Drive has $(awk -v b="$free" 'BEGIN{printf "%.1f", b/1e9}') GB free, the new image is $IGB GB" "Nothing was deleted. Free space in sequoialtaylor's Drive (Gmail or Drive files, then empty its trash), then run ~/bin/mac-snapshot.sh --now." sequoia

# ─── Upload and confirm ───────────────────────────────────────────────────────────────────────────────
bounded rclone copyto "$IMG" "$DEST/$NAME" --log-file "$LOG" --log-level NOTICE ||
  stop SNAPSHOT_UPLOAD_FAILED "the upload to sequoialtaylor's Drive failed or ran out of time" "Read the log; run ~/bin/mac-snapshot.sh --now. Older snapshots were not touched."
rsize=$(rclone lsjson "$DEST/$NAME" 2>>"$LOG" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s)[0]?.Size??-1)}catch{console.log(-1)}})')
[ "$rsize" = "$SIZE" ] || stop SNAPSHOT_UPLOAD_MISMATCH "Drive holds $rsize bytes, the image is $SIZE" "Run ~/bin/mac-snapshot.sh --now. Older snapshots were not touched."

# ─── Keep the newest $KEEP (names sort by date); deleted for good, so the space is really freed ──────
kept=0
while IFS= read -r f; do
  kept=$((kept + 1)); [ "$kept" -le "$KEEP" ] && continue
  rclone deletefile "$DEST/$f" --drive-use-trash=false --log-file "$LOG" && log "removed old snapshot $f"
done < <(rclone lsf --files-only --include 'mac-snapshot-????-??-??.dmg' "$DEST" 2>>"$LOG" | sort -r)
[ "$kept" -gt "$KEEP" ] && kept=$KEEP

log "OUTPUT $SN files, $GB GB staged, image $IGB GB, uploaded $NAME to $DEST, kept $kept"
notify ok "Mac snapshot done: $IGB GB, kept $kept"
exit 0
