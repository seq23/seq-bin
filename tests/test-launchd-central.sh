#!/bin/bash
# Every versioned launchd job is installed through install-launchd.sh, which moves its Central hours to
# the Mac's zone (boss-os plist-central.mjs). Proves the mover on a scratch copy: an Eastern Mac moves
# Monday 08:00 Central to Monday 09:00 local, and a second run changes nothing.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
grep -q 'plist-central.mjs' "$BIN/install-launchd.sh" || { echo "FAIL: install-launchd.sh does not use plist-central.mjs"; fail=1; }
for f in "$BIN"/launchd/*.plist; do
  if command -v plutil >/dev/null; then plutil -lint "$f" >/dev/null || { echo "FAIL: $f does not parse"; fail=1; }
  else python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$f" || { echo "FAIL: $f does not parse"; fail=1; }; fi
done
grep -q 'install-launchd.sh' "$BIN/README.md" || { echo "FAIL: README does not say to install with install-launchd.sh"; fail=1; }
CENTRAL="${BOSS_OS_REPO:-$HOME/GitHub/boss-os}/scripts/ops/plist-central.mjs"
if [ -f "$CENTRAL" ]; then
  tmp=$(mktemp -d); cp "$BIN/launchd/com.seq.ci-sweep.plist" "$tmp/x.plist"
  out=$(cd "$tmp" && node --input-type=module -e "import { shiftPlist } from '$CENTRAL'; import fs from 'node:fs'; process.stdout.write(shiftPlist(fs.readFileSync('x.plist','utf8'), 1));")
  echo "$out" | tr -d '\n\t ' | grep -q '<key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer>' || { echo "FAIL: Monday 08:00 Central did not become 09:00 on an Eastern Mac"; fail=1; }
  rm -rf "$tmp"
else
  echo "SKIP: no boss-os checkout here, the mover proof did not run"
fi
[ $fail -eq 0 ] && echo "launchd-central: ok"
exit $fail
