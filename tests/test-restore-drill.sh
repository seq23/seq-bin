#!/bin/bash
# Behaviour test for restore-drill.sh against local folders standing in for Drive, a stub Keychain, a stub
# hdiutil and a stub D1 export (no network, no vault, no real backup). macOS only (stat -f, date -j).
# Proves: three good backups pass with OUTPUT 3 and close the row; a backup file that differs from the Mac,
# a wrong passphrase, a stale snapshot, a corrupt export and a restored count that differs from live each
# fail by name with exit 1 and open the row; wrangler's signed download link never reaches the log; the
# scratch folder is gone afterwards.
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/restore-drill.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; bad(){ echo "FAIL: $1"; fail=1; }

# The Mac's ~/bin (old files: unchanged since last night's backup) and its Drive copy.
mkdir -p "$T/home/bin" "$T/drive/bin" "$T/snap" "$T/tmp"
for i in $(seq 1 25); do echo "script $i" > "$T/home/bin/f$i.sh"; done
cp "$T/home/bin/"*.sh "$T/drive/bin/"
touch -t 202001010000 "$T/home/bin/"*.sh
echo "edited today" > "$T/home/bin/f1.sh"   # changed since the backup: never compared
# The newest snapshot (an older one beside it) and the stubs.
echo old > "$T/snap/mac-snapshot-2026-10-15.dmg"; echo image > "$T/snap/mac-snapshot-2026-11-15.dmg"
cat > "$T/security" <<'SH'
#!/bin/bash
cat "$(dirname "$0")/pass"
SH
printf 'right-pass\n' > "$T/pass"
cat > "$T/hdiutil" <<'SH'
#!/bin/bash
[ "$1" = attach ] || exit 0
pw=$(cat); [ "$pw" = right-pass ] || { echo "hdiutil: attach failed - Authentication error" >&2; exit 1; }
while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && m=$2; shift; done
mkdir -p "$m/.west-peek-os/vault"; echo "restore steps" > "$m/README-RESTORE.txt"; echo k > "$m/.west-peek-os/vault/secrets.vault"
for i in $(seq 1 120); do echo x > "$m/f$i"; done
SH
cat > "$T/export" <<'SH'
#!/bin/bash
echo "You can also download your export from https://abc.r2.cloudflarestorage.com/x.sql?X-Amz-Signature=SIGNED-LINK-NEVER-LOGGED"
if [ -f "$(dirname "$0")/corrupt" ]; then echo "this is not SQL" > "$1"; exit 0; fi
{ for i in $(seq 1 60); do echo "CREATE TABLE t$i (a INTEGER);"; done
  echo "CREATE TABLE standing_duties (id TEXT);"; for i in 1 2 3; do echo "INSERT INTO standing_duties VALUES ('d$i');"; done; } > "$1"
SH
printf '#!/bin/bash\ncat "$(dirname "$0")/live"\n' > "$T/live-count"; echo 3 > "$T/live"
chmod +x "$T/security" "$T/hdiutil" "$T/export" "$T/live-count"

run() {  # extra env as args; prints the exit code
  env TMPDIR="$T/tmp" DRILL_HOME="$T/home" DRILL_DRIVE_REMOTE="$T/drive" DRILL_SNAPSHOT_REMOTE="$T/snap" \
    DRILL_SECURITY="$T/security" DRILL_HDIUTIL="$T/hdiutil" DRILL_D1_EXPORT="$T/export" DRILL_D1_LIVE_COUNT="$T/live-count" \
    DRILL_NO_NOTIFY=1 DRILL_TODAY=2026-12-01 DRILL_LOGDIR="$T/logs" DRILL_MIN_TABLES=50 "$@" "$S" >"$T/out" 2>&1
  echo $?
}

[ "$(run)" = 0 ] || { bad "three good backups did not pass"; cat "$T/out"; }
grep -q '^OUTPUT 3 backups restored and proven' "$T/out" || bad "no OUTPUT 3 line"
grep -q '"cleared":true' "$T/out" || bad "a clean run did not close the row"
grep -q 'drive: 25 files restored.*24 match the Mac' "$T/out" || bad "drive drill did not compare the unchanged files (and skip the edited one)"
grep -q 'snapshot: mac-snapshot-2026-11-15.dmg' "$T/out" || bad "the snapshot drill did not take the newest image"
grep -q 'standing_duties 3 rows = live' "$T/out" || bad "the d1 drill did not match live"
grep -rq 'SIGNED-LINK-NEVER-LOGGED\|r2.cloudflarestorage' "$T/logs" "$T/out" && bad "the signed download link reached the log"
[ -z "$(ls -A "$T/tmp")" ] || bad "the scratch folder was left behind"

echo "tampered" > "$T/drive/bin/f5.sh"
[ "$(run)" = 1 ] || bad "a backup file that differs from the Mac passed"
grep -q 'NAMED STOP \[RESTORE_DRILL_FAILED\] drive' "$T/out" || bad "the drive failure was not named"
grep -q '"stop":"RESTORE_DRILL"' "$T/out" && ! grep -q '"cleared":true' "$T/out" || bad "a failed drill did not open the row"
cp "$T/home/bin/f5.sh" "$T/drive/bin/f5.sh"

printf 'wrong\n' > "$T/pass"
[ "$(run)" = 1 ] && grep -q 'would not open with the passphrase' "$T/out" || bad "a wrong passphrase passed"
printf 'right-pass\n' > "$T/pass"
[ "$(run env DRILL_TODAY=2027-01-20)" = 1 ] && grep -q 'days old' "$T/out" || bad "a stale snapshot passed"

touch "$T/corrupt"
[ "$(run)" = 1 ] && grep -q 'NAMED STOP \[RESTORE_DRILL_FAILED\] d1' "$T/out" || bad "a corrupt export passed"
rm "$T/corrupt"
echo 4 > "$T/live"
[ "$(run)" = 1 ] && grep -q 'live has 4' "$T/out" || bad "a restored count that differs from live passed"
echo 3 > "$T/live"

[ "$(run env DRILL_MIN_SAME=100)" = 1 ] && grep -q 'fewer than 100' "$T/out" || bad "too few compared files passed (rule 0)"
[ "$(run)" = 0 ] || bad "the good state did not pass again"
[ -z "$(ls -A "$T/tmp")" ] || bad "the scratch folder was left behind after failures"

[ $fail -eq 0 ] && echo "restore-drill: ok"
exit $fail
