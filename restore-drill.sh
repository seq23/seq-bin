#!/bin/bash
# MONTHLY RESTORE DRILL (owner, 19 Nov 2026, phase 1 of the veteran quality bar: "restore one real backup
# into a scratch location and prove it reads"). launchd com.seq.restore-drill, the 1st at 13:00 Central
# (after the 10:00 snapshot; the Mac is usually awake then, and a missed run fires on wake).
#
# A backup nobody has restored is a hope. Three drills, each on the newest REAL copy, in a private scratch
# folder that is deleted at the end, whatever happens:
#   drive     the nightly Drive backup (gdrive:Mac-Backup, drive-backup.sh): ~/bin's copy comes back, rclone
#             checks every file's MD5 against Drive on the way down, and every file the Mac has not changed
#             since that backup matches the Mac byte for byte (at least DRILL_MIN_SAME files compared).
#   snapshot  the encrypted Mac snapshot (gdrive-sl:Mac-Snapshots, mac-snapshot.sh): the newest image comes
#             back at the size Drive lists, is no older than 20 days, opens read-only with its passphrase
#             (Keychain item mac-snapshot, one read, piped, never printed), and holds README-RESTORE.txt and
#             the vault.
#   d1        the Boss OS database: a fresh `wrangler d1 export` of production loads into SQLite, passes
#             PRAGMA integrity_check, has at least DRILL_MIN_TABLES tables, and its standing_duties count
#             equals the live database's.
#
#   ~/bin/restore-drill.sh            # all three (launchd)
#   ~/bin/restore-drill.sh drive d1   # just these
#
# Rule 0: prints `OUTPUT <n> backups restored and proven`; exit 0 only when every drill asked for passed.
# A failed drill is NAMED STOP [RESTORE_DRILL_FAILED] (exit 1), an Open Loops row (stop RESTORE_DRILL, owner
# claude) and a banner; a clean run closes the row. Nothing here writes to a backup, the Mac's files or the
# live database (the export is a read). wrangler prints a one-hour signed download link; it never reaches
# the log.
#
# Test-only overrides: DRILL_HOME, DRILL_DRIVE_REMOTE, DRILL_SNAPSHOT_REMOTE, DRILL_SECURITY, DRILL_HDIUTIL,
# DRILL_D1_EXPORT (a command that writes the SQL to $1), DRILL_D1_LIVE_COUNT (prints the live count),
# DRILL_NO_NOTIFY=1, DRILL_TODAY (YYYY-MM-DD).
set -uo pipefail
umask 077
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="${DRILL_HOME:-$HOME}"
DRIVE="${DRILL_DRIVE_REMOTE:-gdrive:Mac-Backup}"
SNAP="${DRILL_SNAPSHOT_REMOTE:-gdrive-sl:Mac-Snapshots}"
SECURITY="${DRILL_SECURITY:-/usr/bin/security}"
HDIUTIL="${DRILL_HDIUTIL:-hdiutil}"
MIN_SAME="${DRILL_MIN_SAME:-10}"
MIN_TABLES="${DRILL_MIN_TABLES:-50}"
TODAY="${DRILL_TODAY:-$(date +%Y-%m-%d)}"
LOGDIR="${DRILL_LOGDIR:-$HOME/Library/Logs/restore-drill}"; mkdir -p "$LOGDIR"; LOG="$LOGDIR/$TODAY.log"
VR="$HOME/.boss-os/runtime"; [ -f "$VR/scripts/vault/vault.mjs" ] || VR="$HOME/GitHub/boss-os"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

S=$(mktemp -d "${TMPDIR:-/tmp}/restore-drill.XXXXXX") || { echo "NAMED STOP [NO_SCRATCH] could not make a scratch folder" >&2; exit 2; }
MNT="$S/mnt"
cleanup() {
  if mount | grep -qF " on $MNT "; then "$HDIUTIL" detach "$MNT" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$S"
}
trap cleanup EXIT

# One Open Loops row, stop RESTORE_DRILL: a failure opens it (owner claude), a clean run closes it.
notify() {  # $1 = ok|stop  $2 = one line
  local body
  # shellcheck disable=SC2016  # a JavaScript template literal, not a shell expansion
  body=$(node -e 'const [s,l]=process.argv.slice(1);const b={repo:"seq23/seq-bin",business:"personal",owner:"claude",stop:"RESTORE_DRILL",title:l,finish_line:"every backup restores and reads (~/bin/restore-drill.sh exits 0)"};if(s==="ok")b.cleared=true;else b.next_step=`Read ${process.argv[3]}, fix the backup or the drill at the root, then run ~/bin/restore-drill.sh`;console.log(JSON.stringify(b))' "$1" "$2" "$LOG")
  if [ "${DRILL_NO_NOTIFY:-}" = 1 ]; then log "NOTIFY (test, not sent) $body"; return 0; fi
  osascript -e "display notification \"${2//\"/}\" with title \"Restore drill\"" >/dev/null 2>&1 || true
  (cd "$VR" && npm run -s vault:run -- node "$BIN/open-loops.mjs" "$body") >>"$LOG" 2>&1 \
    || log "NAMED STOP [DRILL_NOTIFY_FAILED] the Open Loops row could not be posted; the banner was shown."
}

# ─── Drill 1: the nightly Drive backup ──────────────────────────────────────────────────────────────
drill_drive() {
  local dest="$S/drive/bin" same=0 diff=0 f rel
  rclone copy "$DRIVE/bin" "$dest" --transfers 8 --log-file "$LOG" --log-level ERROR || { log "drive: the copy back from $DRIVE/bin failed"; return 1; }
  local n; n=$(find "$dest" -type f | wc -l | tr -d ' ')
  [ "$n" -ge 20 ] || { log "drive: only $n files came back from $DRIVE/bin (fewer than 20)"; return 1; }
  # Files the Mac has not touched in 26 h were in last night's 01:40 backup as they are now.
  while IFS= read -r f; do
    rel=${f#"$dest/"}
    [ -f "$H/bin/$rel" ] || continue
    [ -n "$(find "$H/bin/$rel" -mmin -1560 2>/dev/null)" ] && continue
    if cmp -s "$f" "$H/bin/$rel"; then same=$((same + 1)); else diff=$((diff + 1)); log "drive: $rel differs from the Mac"; fi
  done < <(find "$dest" -type f)
  [ "$diff" -eq 0 ] || { log "drive: $diff unchanged file(s) came back different"; return 1; }
  [ "$same" -ge "$MIN_SAME" ] || { log "drive: only $same file(s) could be compared with the Mac (fewer than $MIN_SAME)"; return 1; }
  log "drive: $n files restored from $DRIVE/bin, MD5-checked against Drive, $same match the Mac byte for byte"
}

# ─── Drill 2: the encrypted Mac snapshot ────────────────────────────────────────────────────────────
drill_snapshot() {
  local name size got age n
  name=$(rclone lsf "$SNAP" --files-only 2>>"$LOG" | grep -E '^mac-snapshot-[0-9]{4}-[0-9]{2}-[0-9]{2}\.dmg$' | sort | tail -1)
  [ -n "$name" ] || { log "snapshot: no mac-snapshot-*.dmg in $SNAP"; return 1; }
  age=$(( ( $(date -j -f %Y-%m-%d "$TODAY" +%s) - $(date -j -f %Y-%m-%d "${name:13:10}" +%s) ) / 86400 ))
  [ "$age" -le 20 ] || { log "snapshot: the newest, $name, is $age days old (the 1st/15th job is not running)"; return 1; }
  size=$(rclone lsl "$SNAP/$name" 2>>"$LOG" | awk '{print $1}')
  mkdir -p "$S/snap" "$MNT"
  rclone copy "$SNAP/$name" "$S/snap" --log-file "$LOG" --log-level ERROR || { log "snapshot: $name could not be copied back"; return 1; }
  got=$(stat -f %z "$S/snap/$name" 2>/dev/null || echo 0)
  [ -n "$size" ] && [ "$got" = "$size" ] || { log "snapshot: $name came back at $got bytes, Drive lists $size"; return 1; }
  "$SECURITY" find-generic-password -s mac-snapshot -a sequoia -w 2>/dev/null | tr -d '\n' \
    | "$HDIUTIL" attach -stdinpass -readonly -nobrowse -noverify -mountpoint "$MNT" "$S/snap/$name" >>"$LOG" 2>&1 \
    || { log "snapshot: $name would not open with the passphrase in the Keychain (item mac-snapshot)"; return 1; }
  n=$(find "$MNT" -type f 2>/dev/null | wc -l | tr -d ' ')
  local ok=1
  [ -s "$MNT/README-RESTORE.txt" ] || { log "snapshot: README-RESTORE.txt is missing"; ok=0; }
  [ -n "$(find "$MNT/.west-peek-os/vault" -type f -size +0 2>/dev/null | head -1)" ] || { log "snapshot: the vault is not inside"; ok=0; }
  [ "$n" -ge 100 ] || { log "snapshot: only $n files inside (fewer than 100)"; ok=0; }
  "$HDIUTIL" detach "$MNT" -quiet >>"$LOG" 2>&1 || "$HDIUTIL" detach "$MNT" -quiet -force >>"$LOG" 2>&1 || true
  [ "$ok" = 1 ] || return 1
  log "snapshot: $name ($age days old, $got bytes) opened with its passphrase; $n files, the vault and README-RESTORE.txt inside"
}

# ─── Drill 3: the Boss OS database ──────────────────────────────────────────────────────────────────
d1_export() {  # $1 = output file. The signed link wrangler prints is dropped before the log.
  {
    if [ -n "${DRILL_D1_EXPORT:-}" ]; then "$DRILL_D1_EXPORT" "$1"
    else (cd "$VR" && npm run -s vault:run -- npx wrangler d1 export WP_OS_DB --env production --remote --output "$1"); fi
  } 2>&1 | grep -v -i -E 'r2\.cloudflarestorage\.com|X-Amz-' >>"$LOG"
  return "${PIPESTATUS[0]}"
}
d1_live_count() {
  if [ -n "${DRILL_D1_LIVE_COUNT:-}" ]; then "$DRILL_D1_LIVE_COUNT"; return; fi
  (cd "$VR" && npm run -s vault:run -- npx wrangler d1 execute WP_OS_DB --env production --remote --json \
    --command "SELECT COUNT(*) AS n FROM standing_duties") 2>>"$LOG" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s.slice(s.indexOf("[")))[0].results[0].n)}catch{process.exit(1)}})'
}
drill_d1() {
  local sql="$S/d1/boss.sql" db="$S/d1/boss.db" check tables mine live
  mkdir -p "$S/d1"
  d1_export "$sql" || { log "d1: wrangler d1 export of production failed"; return 1; }
  [ -s "$sql" ] || { log "d1: the export is empty"; return 1; }
  # One transaction: the 88 MB export loads in seconds instead of minutes.
  { echo "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; BEGIN;"; cat "$sql"; echo "COMMIT;"; } | sqlite3 "$db" 2>>"$LOG" \
    || { log "d1: the export would not load into SQLite"; return 1; }
  check=$(sqlite3 "$db" "PRAGMA integrity_check;" 2>>"$LOG")
  [ "$check" = ok ] || { log "d1: integrity_check said: ${check:0:200}"; return 1; }
  tables=$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';")
  [ "$tables" -ge "$MIN_TABLES" ] || { log "d1: only $tables tables restored (fewer than $MIN_TABLES)"; return 1; }
  mine=$(sqlite3 "$db" "SELECT COUNT(*) FROM standing_duties;" 2>>"$LOG")
  live=$(d1_live_count) || { log "d1: the live standing_duties count could not be read"; return 1; }
  [ -n "$mine" ] && [ "$mine" -gt 0 ] && [ "$mine" = "$live" ] || { log "d1: restored standing_duties has ${mine:-no} rows, live has ${live:-?}"; return 1; }
  log "d1: production exported ($(( $(stat -f %z "$sql") / 1000000 )) MB) and restored: integrity ok, $tables tables, standing_duties $mine rows = live"
}

# ─── The run ────────────────────────────────────────────────────────────────────────────────────────
drills=("$@"); [ ${#drills[@]} -gt 0 ] || drills=(drive snapshot d1)
log "=== restore drill $TODAY: ${drills[*]} (scratch $S) ==="
passed=0; failed=()
for d in "${drills[@]}"; do
  case "$d" in drive|snapshot|d1) ;; *) echo "usage: restore-drill.sh [drive] [snapshot] [d1]" >&2; exit 64 ;; esac
  if "drill_$d"; then passed=$((passed + 1)); else failed+=("$d"); fi
done
echo "OUTPUT $passed backups restored and proven" | tee -a "$LOG"
if [ ${#failed[@]} -gt 0 ]; then
  log "NAMED STOP [RESTORE_DRILL_FAILED] ${failed[*]} did not restore and read; the lines above say why. Log: $LOG"
  notify stop "Restore drill failed: ${failed[*]} did not restore and read"
  exit 1
fi
[ "$passed" -gt 0 ] || { log "NAMED STOP [RESTORE_DRILL_NOTHING] no drill ran"; exit 2; }
notify ok "Restore drill passed: ${drills[*]} restored and read"
log "restore drill: $passed of ${#drills[@]} backups restored and proven; scratch removed."
