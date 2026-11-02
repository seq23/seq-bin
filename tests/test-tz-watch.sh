#!/bin/bash
# Behaviour test for tz-watch.sh: a fake Mac moving Eastern -> Central -> Eastern gets its plists
# rewritten to the right local hour each time, through the real install-launchd.sh and the real
# boss-os mover; an unchanged zone rewrites nothing; a job mid-run defers the reinstall; a failing
# installer is a NAMED STOP with an Open Loops row, closed by the next success. Fake launchctl, fake
# LaunchAgents, stub intake: nothing on this machine is touched.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(cd "$(mktemp -d)" && pwd -P)  # real path: the mover only runs as a CLI when argv[1] is its real path
fail=0; bad(){ echo "FAIL: $1"; fail=1; }

# The one mover, from boss-os (a local checkout, else main on GitHub; boss-os is public).
BOSS="$T/boss"; mkdir -p "$BOSS/scripts/ops"
src="${BOSS_OS_REPO:-$HOME/GitHub/boss-os}/scripts/ops/plist-central.mjs"
if [ -f "$src" ]; then cp "$src" "$BOSS/scripts/ops/"
else curl -fsSL https://raw.githubusercontent.com/seq23/boss-os/main/scripts/ops/plist-central.mjs -o "$BOSS/scripts/ops/plist-central.mjs" \
  || { echo "FAIL: could not fetch plist-central.mjs; nothing was tested"; exit 1; }; fi

mkdir -p "$T/src" "$T/agents" "$T/state" "$T/stubbin"
cp "$BIN/launchd/com.seq.drive-backup.plist" "$BIN/launchd/com.seq.ci-sweep.plist" "$T/src/"
# Fake launchctl: records bootstraps; `list` names every installed job, PID 123 for any in $T/busy.
cat > "$T/stubbin/launchctl" <<SH
#!/bin/bash
case "\$1" in
  bootstrap) echo "bootstrap \$3" >> "$T/lctl.log" ;;
  list) for f in "$T"/agents/*.plist; do l=\$(basename "\$f" .plist); if grep -qx "\$l" "$T/busy" 2>/dev/null; then printf '123\t0\t%s\n' "\$l"; else printf -- '-\t0\t%s\n' "\$l"; fi; done ;;
esac
exit 0
SH
chmod +x "$T/stubbin/launchctl"
command -v plutil >/dev/null || { printf '#!/bin/bash\n[ "$1" = -lint ] && shift; for f; do python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],\"rb\"))" "$f" || exit 1; done\n' > "$T/stubbin/plutil"; chmod +x "$T/stubbin/plutil"; }

# Stub Open Loops intake: one JSON line per post.
cat > "$T/stub.mjs" <<'JS'
import http from "node:http"; import fs from "node:fs";
const dir = process.argv[2];
http.createServer((req, res) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => {
  fs.appendFileSync(`${dir}/posts.jsonl`, b + "\n"); res.writeHead(200, { "content-type": "application/json" }); res.end('{"ok":true}');
}); }).listen(0, "127.0.0.1", function () { fs.writeFileSync(`${dir}/port`, String(this.address().port)); });
JS
node "$T/stub.mjs" "$T" & STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "FAIL: stub intake did not start"; exit 1; }

OPEN_LOOPS_URL="http://127.0.0.1:$(cat "$T/port")/intake"
export PATH="$T/stubbin:$PATH" OPEN_LOOPS_URL BOSS_OS_REPO="$BOSS" LAUNCHCTL="$T/stubbin/launchctl" LAUNCH_AGENTS_DIR="$T/agents" LAUNCHD_SRC="$T/src" \
  TZ_WATCH_STATE="$T/state" TZ_WATCH_LOG="$T/tz.log" TZ_WATCH_NO_VAULT=1 BOSS_OPEN_LOOPS_TOKEN=olt_test
INSTALL="seq-bin|$BIN/install-launchd.sh com.seq.drive-backup com.seq.ci-sweep"
run(){ TZ_WATCH_ZONE="$1" TZ_WATCH_INSTALLERS="${2:-$INSTALL}" "$BIN/tz-watch.sh" > "$T/out" 2>&1; }
hour(){ tr -d '\n\t ' < "$T/agents/$1.plist" | grep -o '<key>Hour</key><integer>[0-9]*</integer>' | head -1 | grep -o '[0-9]*</integer>' | grep -o '[0-9]*'; }
boots(){ grep -c bootstrap "$T/lctl.log" 2>/dev/null || echo 0; }

run America/New_York || bad "first Eastern run exited non-zero: $(tail -3 "$T/out")"
[ "$(hour com.seq.drive-backup)" = 2 ] || bad "Eastern: 01:40 Central should be Hour 2, got $(hour com.seq.drive-backup)"
[ "$(hour com.seq.ci-sweep)" = 9 ] || bad "Eastern: Monday 08:00 Central should be Hour 9, got $(hour com.seq.ci-sweep)"
[ "$(cat "$T/state/seq-bin")" = "America/New_York 1" ] || bad "zone not recorded: $(cat "$T/state/seq-bin" 2>/dev/null)"
b=$(boots); sum=$(cat "$T"/agents/*.plist | cksum)

run America/New_York || bad "unchanged zone exited non-zero"
[ "$(boots)" = "$b" ] || bad "unchanged zone reloaded jobs"
[ "$(cat "$T"/agents/*.plist | cksum)" = "$sum" ] || bad "unchanged zone rewrote a plist"
grep -q "in step" "$T/out" || bad "unchanged zone did not say it was in step"

run America/Chicago || bad "Central run exited non-zero"
[ "$(hour com.seq.drive-backup)" = 1 ] || bad "Central: drive-backup should be Hour 1, got $(hour com.seq.drive-backup)"
[ "$(hour com.seq.ci-sweep)" = 8 ] || bad "Central: ci-sweep should be Hour 8, got $(hour com.seq.ci-sweep)"

echo com.seq.drive-backup > "$T/busy"; b=$(boots)
run America/New_York || bad "deferred run exited non-zero"
grep -q "TZ_WATCH_DEFERRED" "$T/out" || bad "a running job did not defer the reinstall"
[ "$(boots)" = "$b" ] && [ "$(hour com.seq.drive-backup)" = 1 ] || bad "reinstalled under a running job"
rm -f "$T/busy"
run America/New_York || bad "back-to-Eastern run exited non-zero"
[ "$(hour com.seq.drive-backup)" = 2 ] || bad "back to Eastern: drive-backup should be Hour 2 again, got $(hour com.seq.drive-backup)"
[ "$(hour com.seq.ci-sweep)" = 9 ] || bad "back to Eastern: ci-sweep should be Hour 9 again"

run America/Chicago "broken|exit 7" && bad "a failing installer exited 0"
grep -q "NAMED STOP \[TZ_WATCH_INSTALL_FAILED\] broken" "$T/out" || bad "a failing installer was not a named stop"
grep -q '"stop":"TZ_WATCH_INSTALL_FAILED"' "$T/posts.jsonl" 2>/dev/null || bad "a failing installer opened no Open Loops row"
run America/Chicago "broken|true" || bad "the repaired installer exited non-zero"
grep -q '"cleared":true' "$T/posts.jsonl" 2>/dev/null || bad "success did not close the Open Loops row"

[ $fail -eq 0 ] && echo "tz-watch: ok"
exit $fail
