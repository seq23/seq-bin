#!/bin/bash
# land-after, driven for real (a real detached worker, a fake gh, a fake lander, a stub Open Loops intake)
# against a fake HOME. Each case is a way it breaks (22 Nov 2026 brief, "how it breaks"):
#   abuse/mistake  no PASS line, a builder-signed PASS, the same PR twice, a slug with / or .. -> refused, nothing started
#   data loss      only its own sheet is touched; cleanup touches only done/ and logs/ past 14 days; a sheet
#                  deleted mid-land is recreated with the result; secrets never reach the log
#   outage         gh rate-limited, land "could not verify", the merge unreadable after land -> FAIL unknown, never
#                  PASS; Open Loops down -> FAIL still on the sheet and in the log, saying the row was not filed;
#                  a killed worker -> --status says stale, never running
#   rule 0         land exits 0 having merged nothing -> FAIL LAND_MERGED_NOTHING
#   detached       the worker finishes after the starting shell AND its whole process group are gone
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LA="${LAND_AFTER_UNDER_TEST:-$HERE/../land-after}"
[ -x "$LA" ] || { echo "FAIL: no land-after at $LA"; exit 1; }
W="$(mktemp -d)"; STUB=""
trap '[ -n "$STUB" ] && kill "$STUB" 2>/dev/null; rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
T="$HOME/Work/tasks"; FAKE="$W/fake"; BIN="$W/bin"; mkdir -p "$FAKE" "$BIN"
export FAKE_DIR="$FAKE" PATH="$BIN:$PATH" LAND_AFTER_LAND="$W/fake-land" LAND_AFTER_POLL_SECS=0 LAND_AFTER_RETRY_SECS=0
export LAND_OPEN_LOOPS_NO_VAULT=1 BOSS_OPEN_LOOPS_TOKEN=olt_testtoken123 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; failn=0
check() { local d="$1"; shift; if "$@"; then pass=$((pass + 1)); echo "  ok  $d"; else failn=$((failn + 1)); echo "  FAIL $d"; fi; }

# --- a stub Open Loops intake (the real open-loops.mjs posts to it) ---
cat > "$W/stub.mjs" <<'JS'
import http from "node:http"; import fs from "node:fs";
const dir = process.argv[2];
http.createServer((req, res) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => {
  if (fs.existsSync(`${dir}/down`)) { res.writeHead(500); return res.end("down"); }
  fs.appendFileSync(`${dir}/posts.jsonl`, JSON.stringify(JSON.parse(b)) + "\n");
  res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ ok: true, data: { action: "opened" } }));
}); }).listen(0, "127.0.0.1", function () { fs.writeFileSync(`${dir}/port`, String(this.address().port)); });
JS
mkdir -p "$W/api"; node "$W/stub.mjs" "$W/api" & STUB=$!
for _ in $(seq 1 50); do [ -s "$W/api/port" ] && break; sleep 0.1; done
OPEN_LOOPS_URL="http://127.0.0.1:$(cat "$W/api/port")/intake"; export OPEN_LOOPS_URL

# --- fakes ---
cat > "$BIN/gh" <<'SH'
#!/bin/bash
F="$FAKE_DIR"; echo "$*" >> "$F/gh-log"
mode() { cat "$F/$1" 2>/dev/null; }
case "$1 $2" in
  "pr view")
    { [ "$(mode view-mode)" = down ] || { [ "$(mode view-mode)" = down-after-land ] && [ -f "$F/land-ran" ]; }; } \
      && { echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1; }
    st=OPEN; mc=null; [ -f "$F/merged" ] && { st=MERGED; mc='{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'; }
    jq -n --arg body "$(mode body)" --arg st "$st" --argjson mc "$mc" --arg n "$3" \
      '{state: $st, body: $body, headRefOid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", headRefName: "feat", title: "A change",
        url: "https://github.com/t/fixture/pull/\($n)", author: {login: "builder-bot"}, commits: [], mergeCommit: $mc}' ;;
  "pr checks")
    case "$(mode checks-mode)" in
      ratelimit) echo "HTTP 403: API rate limit exceeded for user" >&2; exit 1 ;;
      red) echo '[{"name":"ci","bucket":"fail"}]'; exit 1 ;;
      pending-once) if [ -f "$F/checked" ]; then echo '[{"name":"ci","bucket":"pass"}]'; else : > "$F/checked"; echo '[{"name":"ci","bucket":"pending"}]'; exit 8; fi ;;
      *) echo '[{"name":"ci","bucket":"pass"}]' ;;
    esac ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
SH
cat > "$W/fake-land" <<'SH'
#!/bin/bash
F="$FAKE_DIR"; : > "$F/land-ran"; echo "land $* pwd=$PWD" >> "$F/land-log"
case "$(cat "$F/land-mode" 2>/dev/null || echo ok)" in
  ok) sleep "${FAKE_LAND_SECS:-0}"; echo "1/5  verifying PR #$1 myself"; : > "$F/merged"; echo "LANDED"; exit 0 ;;
  nomerge) echo "1/5  verifying"; exit 0 ;;
  red) echo "4/5  e2e"; printf '\033[31mSTOPPED: NAMED STOP [E2E_RED_AFTER_LARGE_CHANGE] e2e run 9 ended failure\033[0m\n'; exit 1 ;;
  unverified) printf '\033[31mSTOPPED: could not verify (network) — TLS handshake timeout. Nothing was merged by this step\033[0m\n'; exit 75 ;;
  secret) echo "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456 CLOUDFLARE_API_TOKEN=cfsecretvalue123"; : > "$F/merged"; exit 0 ;;
esac
SH
chmod +x "$BIN/gh" "$W/fake-land"
git init -q "$W/repo" && git -C "$W/repo" remote add origin https://github.com/t/fixture.git && git -C "$W/repo" commit -q --allow-empty -m init
GOOD='Ship-ready: PASS — reviewer session_rev123 looked at the self-test output and a detached land; Engineering: PASS'
reset() { rm -f "$FAKE"/*; : > "$W/api/posts.jsonl"; rm -f "$W/api/down"; printf '%s' "${1-$GOOD}" > "$FAKE/body"; }
la() { (cd "$W/repo" && "$LA" "$@") > "$W/out" 2>&1; RC=$?; }
lockgone() { local _; for _ in $(seq 1 150); do [ -z "$(ls "$T/locks" 2>/dev/null)" ] && return 0; sleep 0.2; done; return 1; }
has() { grep -qF -- "$1" "$W/out"; }
line1() { head -1 "$1" 2>/dev/null; }
posts() { cat "$W/api/posts.jsonl" 2>/dev/null; }

echo "=== abuse and mistakes: refused, nothing started ==="
reset "Fixes it."
la 7 --task nopass
check "no PASS line: refused (rc 1)" [ "$RC" -eq 1 ]
check "…with the line to add" has "Ship-ready: PASS"
check "…land never ran, no sheet, no log, no lock" eval '[ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/nopass.md" ] && [ -z "$(find "$T" -type f 2>/dev/null)" ]'
reset "Ship-ready: PASS — reviewer looked at it"
la 7 --task noeng
check "a PASS line without '; Engineering: PASS': refused, nothing started" eval '[ "$RC" -eq 1 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/noeng.md" ]'
reset "Ship-ready: PASS — builder-bot looked at it; Engineering: PASS"
la 7 --task selfsigned
check "a PASS signed by the PR's builder: refused, nothing started" eval '[ "$RC" -eq 1 ] && has "signed by its builder" && [ ! -f "$FAKE/land-ran" ]'
reset
for bad in "../escape" "a/b" "x..y" ".hidden"; do
  la 7 --task "$bad"
  check "slug '$bad': refused, nothing written" eval '[ "$RC" -eq 1 ] && [ ! -f "$FAKE/land-ran" ] && [ -z "$(find "$W/home" -name "*.md" 2>/dev/null)" ]'
done
reset; echo down > "$FAKE/view-mode"
la 7 --task ghdown
check "the PR unreadable at the start: exit 75 'could not verify', nothing started" eval '[ "$RC" -eq 75 ] && has "could not verify" && [ ! -e "$T/ghdown.md" ] && [ ! -f "$FAKE/land-ran" ]'

echo "=== green, detached: survives the starting shell and its whole process group; only its own sheet is touched ==="
reset; mkdir -p "$T"
printf 'STATUS: review #7 aaa 2026-11-22\nGoal: g\nDone:\n- built (abc123)\n' > "$T/job1.md"
printf 'STATUS: building\nGoal: someone else\n' > "$T/other.md"
# shellcheck disable=SC2034 # read inside an eval below
OTHER_SUM="$(cksum < "$T/other.md")"
echo pending-once > "$FAKE/checks-mode"
# The "agent": its own process group, which is killed outright the moment land-after has printed its line.
perl -MPOSIX=setsid -e 'setsid(); exec @ARGV' -- bash -c "cd '$W/repo' && FAKE_LAND_SECS=2 '$LA' 7 --task job1 --then 'echo one >> $W/thens' --then 'echo two >> $W/thens' > '$W/out' 2>&1; echo \$? > '$W/rc'; sleep 30" &
AGENT=$!
for _ in $(seq 1 100); do [ -s "$W/rc" ] && break; sleep 0.1; done
kill -KILL -- "-$AGENT" 2>/dev/null; wait "$AGENT" 2>/dev/null
check "starter exited 0 at once with one line naming pid and log" eval '[ "$(cat "$W/rc")" = 0 ] && [ "$(grep -c . "$W/out")" -eq 1 ] && has "pid " && has "logs/job1-7.log"'
check "…the sheet said landing while land ran" eval 'line1 "$T/job1.md" | grep -q "^STATUS: landing t/fixture#7 aaaaaaa" || [ -f "$T/done/job1.md" ]'
check "…the worker finished after its starter's process group was killed" lockgone
check "…PASS with the merge sha on line 1, moved to done/" eval 'line1 "$T/done/job1.md" | grep -q "^STATUS: PASS t/fixture#7 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb " && [ ! -e "$T/job1.md" ]'
check "…the rest of the sheet kept" grep -q 'built (abc123)' "$T/done/job1.md"
check "…both --then ran, in order" eval '[ "$(cat "$W/thens" 2>/dev/null | paste -sd, -)" = "one,two" ]'
check "…pending checks were waited for before land" eval '[ "$(grep -c "^pr checks" "$FAKE/gh-log")" -ge 2 ]'
check "…land ran in the repo's checkout" grep -q "pwd=$(cd "$W/repo" && pwd -P)" "$FAKE/land-log"
check "…the log ends with the OUTPUT line" grep -q '^OUTPUT land-after t/fixture#7 PASS bbbbbbb' "$T/logs/job1-7.log"
check "…another agent's sheet is byte for byte the same" eval '[ "$(cksum < "$T/other.md")" = "$OTHER_SUM" ]'
check "…nothing posted to Open Loops on a green land" eval '[ -z "$(posts)" ]'
rm -f "$T/other.md"

echo "=== the same PR twice: the second is refused by the lock ==="
reset
FAKE_LAND_SECS=3 la 8 --task first
check "first start: rc 0" [ "$RC" -eq 0 ]
la 8 --task second
check "second start on the same PR: refused" eval '[ "$RC" -eq 1 ] && has "already being landed"'
check "…and it wrote no sheet of its own" eval '[ ! -e "$T/second.md" ] && [ ! -e "$T/logs/second-8.log" ]'
lockgone; check "…the first still ends PASS" eval 'line1 "$T/done/first.md" | grep -q "^STATUS: PASS"'

echo "=== red: FAIL with the step and log on line 1, one Open Loops row, sheet stays open ==="
reset; echo red > "$FAKE/land-mode"
la 9 --task redjob; lockgone
check "STATUS: FAIL names the failing step and the log" eval 'line1 "$T/redjob.md" | grep -q "^STATUS: FAIL t/fixture#9 .*E2E_RED_AFTER_LARGE_CHANGE.*log $T/logs/redjob-9.log"'
check "…sheet stays open (not in done/)" eval '[ -f "$T/redjob.md" ] && [ ! -e "$T/done/redjob.md" ]'
check "…one row, owner claude, stop LAND_AFTER_PR_9" eval '[ "$(posts | grep -c .)" -eq 1 ] && posts | jq -e "select(.owner == \"claude\" and .stop == \"LAND_AFTER_PR_9\" and .repo == \"t/fixture\")" >/dev/null'
check "…next_step is one sentence naming the PR, the step and the sheet" eval 'posts | jq -r .next_step | grep -q "E2E_RED.*t/fixture#9.*$T/redjob.md"'
check "…the sheet says the row was filed" grep -q 'Open Loops row LAND_AFTER_PR_9 filed' "$T/redjob.md"
# A later green try closes the row.
reset; la 9 --task redjob; lockgone
check "a later green try of the same PR: PASS and the row closed" eval 'line1 "$T/done/redjob.md" | grep -q "^STATUS: PASS" && posts | jq -e "select(.stop == \"LAND_AFTER_PR_9\" and .cleared == true)" >/dev/null'

echo "=== outage: unknown, never PASS ==="
reset; echo ratelimit > "$FAKE/checks-mode"
la 10 --task ratelimited; lockgone
check "gh rate-limited reading checks: FAIL unknown, land never ran" eval 'line1 "$T/ratelimited.md" | grep -q "^STATUS: FAIL .*unknown: .*rate limit" && [ ! -f "$FAKE/land-ran" ]'
reset; echo unverified > "$FAKE/land-mode"
la 11 --task netdown; lockgone
check "land exit 75 (network down mid-land): FAIL unknown" eval 'line1 "$T/netdown.md" | grep -q "^STATUS: FAIL .*unknown: STOPPED: could not verify"'
reset; echo down-after-land > "$FAKE/view-mode"
la 12 --task cantconfirm; lockgone
check "land green but the merge unreadable after: FAIL unknown, never PASS" eval 'line1 "$T/cantconfirm.md" | grep -q "^STATUS: FAIL .*unknown: land exited 0 but the merge could not be confirmed" && [ ! -e "$T/done/cantconfirm.md" ]'
reset; echo red > "$FAKE/land-mode"; : > "$W/api/down"
la 13 --task loopsdown; lockgone
check "Open Loops down: FAIL still on line 1" eval 'line1 "$T/loopsdown.md" | grep -q "^STATUS: FAIL t/fixture#13"'
check "…the sheet says the row was NOT filed" grep -q 'Open Loops row was NOT filed' "$T/loopsdown.md"
check "…and so does the log" grep -q 'NAMED STOP \[LAND_AFTER_LOOP_NOT_FILED\]' "$T/logs/loopsdown-13.log"

echo "=== rule 0: land exits 0 having merged nothing ==="
reset; echo nomerge > "$FAKE/land-mode"
la 14 --task nomerge; lockgone
check "FAIL LAND_MERGED_NOTHING, not PASS" eval 'line1 "$T/nomerge.md" | grep -q "^STATUS: FAIL .*LAND_MERGED_NOTHING" && [ ! -e "$T/done/nomerge.md" ]'

echo "=== a --then that fails is the FAIL ==="
reset
la 15 --task thenfail --then 'exit 3' --then "touch $W/never"; lockgone
check "first failing --then: FAIL naming it; later ones never run" eval 'line1 "$T/thenfail.md" | grep -q "then failed (exit 3): exit 3" && [ ! -e "$W/never" ]'

echo "=== data loss: a sheet deleted mid-land is recreated; secrets never reach the log; no --task makes a sheet ==="
reset; printf 'STATUS: review\nGoal: g\n' > "$T/vanish.md"
FAKE_LAND_SECS=2 la 16 --task vanish; rm -f "$T/vanish.md"; lockgone
check "sheet missing at finish: recreated with the PASS, in done/" eval 'line1 "$T/done/vanish.md" | grep -q "^STATUS: PASS t/fixture#16"'
reset; echo secret > "$FAKE/land-mode"
la 17 --task secrets; lockgone
check "no token, bearer or KEY=value in the log" eval '! grep -qE "ghp_ABCDEF|sk-abcdefghij|cfsecretvalue123" "$T/logs/secrets-17.log" && grep -q "\[masked\]" "$T/logs/secrets-17.log"'
reset
la 18; lockgone
check "no --task: a minimal sheet from the PR, ending PASS in done/" eval 'line1 "$T/done/pr-fixture-18.md" | grep -q "^STATUS: PASS" && grep -q "Goal: land t/fixture#18 (A change)" "$T/done/pr-fixture-18.md"'

echo "=== cleanup: only done/ and logs/, only past 14 days; open sheets never ==="
old() { perl -e 'utime time - $ARGV[0] * 86400, time - $ARGV[0] * 86400, $ARGV[1]' "$1" "$2"; }
mkdir -p "$T/keepdir"; for f in done/old.md logs/old.log done/fresh.md logs/fresh.log openold.md keepdir/old.txt; do echo x > "$T/$f"; done
old 15 "$T/done/old.md"; old 15 "$T/logs/old.log"; old 13 "$T/done/fresh.md"; old 13 "$T/logs/fresh.log"; old 30 "$T/openold.md"; old 30 "$T/keepdir/old.txt"
printf 'STATUS: building x\n' > "$T/openold.md"; old 30 "$T/openold.md"
"$LA" --status > "$W/out" 2>&1
check "15-day-old files in done/ and logs/ deleted" eval '[ ! -e "$T/done/old.md" ] && [ ! -e "$T/logs/old.log" ]'
check "13-day-old files kept" eval '[ -e "$T/done/fresh.md" ] && [ -e "$T/logs/fresh.log" ]'
check "a 30-day-old OPEN sheet kept, and flagged stale" eval '[ -e "$T/openold.md" ] && grep -q "^openold  STATUS: building x  \[stale: untouched 30d\]  $T/openold.md" "$W/out"'
check "a file outside done/ and logs/ kept" [ -e "$T/keepdir/old.txt" ]

echo "=== --status: a killed worker is stale, never running; done/ is never listed ==="
printf 'STATUS: landing t/fixture#20 aaa 2026-11-22T01:00\n' > "$T/killed.md"; old 0.1 "$T/killed.md"
mkdir -p "$T/locks/t_fixture-20.lock"; echo killed > "$T/locks/t_fixture-20.lock/slug"; echo 999999 > "$T/locks/t_fixture-20.lock/pid"
printf 'STATUS: landing t/fixture#21 aaa 2026-11-22T01:00\n' > "$T/oldlanding.md"; old 0.1 "$T/oldlanding.md"
"$LA" --status > "$W/out" 2>&1
check "landing with a dead worker pid: stale" grep -q '^killed  STATUS: landing .*\[stale: landing, no land running\]' "$W/out"
check "landing 2.4 h old with no worker: stale" grep -q '^oldlanding  .*\[stale: landing' "$W/out"
check "nothing shown as running" eval '! grep -q "\\[running" "$W/out"'
check "done/ sheets are not listed" eval '! grep -q "done/" "$W/out"'
rm -rf "$T/locks/t_fixture-20.lock"
# A dead holder's lock does not block a new land of that PR.
mkdir -p "$T/locks/t_fixture-22.lock"; echo x > "$T/locks/t_fixture-22.lock/slug"; echo 999999 > "$T/locks/t_fixture-22.lock/pid"
reset; la 22 --task afterkill; lockgone
check "a dead worker's lock is taken over; the new land ends PASS" eval 'line1 "$T/done/afterkill.md" | grep -q "^STATUS: PASS"'

echo
echo "land-after: $pass passed, $failn failed"
[ "$pass" -gt 0 ] || { echo "FAIL: zero checks ran"; exit 1; }
[ "$failn" -eq 0 ]
