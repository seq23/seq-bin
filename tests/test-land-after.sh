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
#   22 Nov review  F1 another job's sheet, or a sheet another land holds -> refused, untouched; F2 a GitHub hiccup or
#                  a spent allowance inside the wait is waited out, never "FAIL unknown"; N1 a worker that never
#                  starts -> refused, sheet restored; N3 more token shapes masked, --then never on a command line;
#                  N4 --sweep files a dead worker's land; N6 logs an open sheet names are kept; N7 a failed sheet
#                  write drops both locks; N8 a PASS comment counts only from the owner account
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LA="${LAND_AFTER_UNDER_TEST:-$HERE/../land-after}"
[ -x "$LA" ] || { echo "FAIL: no land-after at $LA"; exit 1; }
W="$(mktemp -d)"; STUB=""
trap '[ -n "$STUB" ] && kill "$STUB" 2>/dev/null; rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
T="$HOME/Work/tasks"; FAKE="$W/fake"; BIN="$W/bin"; mkdir -p "$FAKE" "$BIN"
export FAKE_DIR="$FAKE" PATH="$BIN:$PATH" LAND_AFTER_LAND="$W/fake-land" LAND_AFTER_POLL_SECS=0 LAND_AFTER_RETRY_SECS=0 LAND_AFTER_READ_PATIENCE_SECS=3
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
  "api rate_limit") # the allowance GitHub reports: spent with a reset at $F/reset-at while rate limited
    if [ -f "$F/reset-at" ]; then jq -n --argjson r "$(cat "$F/reset-at")" '{resources: {core: {remaining: 0, reset: $r}, graphql: {remaining: 5000, reset: $r}}}' | jq -r "${4:-.}"
    else echo 0 | jq -r '.'; fi; exit 0 ;;
  "pr view")
    { [ "$(mode view-mode)" = down ] || { [ "$(mode view-mode)" = down-after-land ] && [ -f "$F/land-ran" ]; }; } \
      && { echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1; }
    st=OPEN; mc=null; [ -f "$F/merged" ] && { st=MERGED; mc='{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'; }
    cm="$(cat "$F/comments" 2>/dev/null || echo '[]')"
    jq -n --arg body "$(mode body)" --arg st "$st" --argjson mc "$mc" --arg n "$3" --argjson cm "$cm" \
      '{state: $st, body: $body, comments: $cm, headRefOid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", headRefName: "feat", title: "A change",
        url: "https://github.com/t/fixture/pull/\($n)", author: {login: "builder-bot"}, commits: [], mergeCommit: $mc}' ;;
  "pr checks")
    case "$(mode checks-mode)" in
      ratelimit) echo "HTTP 403: API rate limit exceeded for user" >&2; exit 1 ;;
      ratelimit-until) # spent until the epoch in reset-at, then answers
        [ "$(date +%s)" -ge "$(cat "$F/reset-at")" ] || { echo "HTTP 403: API rate limit exceeded for user" >&2; exit 1; }
        echo '[{"name":"ci","bucket":"pass"}]' ;;
      flaky) # two short network failures, then answers
        n=$(grep -c '^pr checks' "$F/gh-log"); [ "$n" -gt 2 ] || { echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1; }
        echo '[{"name":"ci","bucket":"pass"}]' ;;
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
  ratelimit-once) # GitHub's allowance spent on the first land only (22 Nov 2026: land stopped 4 PRs this way)
    [ -f "$F/land-limited" ] || { : > "$F/land-limited"; printf '\033[31mSTOPPED: could not verify (auth) — the sha of green run 1 could not be read: HTTP 403: API rate limit exceeded\033[0m\n'; exit 1; }
    echo "1/5  verifying PR #$1 myself"; : > "$F/merged"; echo "LANDED"; exit 0 ;;
  badcreds) printf '\033[31mSTOPPED: could not verify (auth) — HTTP 401: Bad credentials\033[0m\n'; exit 1 ;;
  unverified) printf '\033[31mSTOPPED: could not verify (network) — TLS handshake timeout. Nothing was merged by this step\033[0m\n'; exit 75 ;;
  secret) echo "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456 CLOUDFLARE_API_TOKEN=cfsecretvalue123"
          echo "npm npm_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 google AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUvW jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
          echo "cf Zk3pQ9vX2mL7nR4tY8wB1cD6fG0hJ5kM3sA9qE2u commit 0123456789abcdef0123456789abcdef01234567"
          : > "$F/merged"; exit 0 ;;
esac
SH
chmod +x "$BIN/gh" "$W/fake-land"
git init -q "$W/repo" && git -C "$W/repo" remote add origin https://github.com/t/fixture.git && git -C "$W/repo" commit -q --allow-empty -m init
GOOD='Ship-ready: PASS — reviewer session_rev123 looked at the self-test output and a detached land; Engineering: PASS'
reset() { rm -f "$FAKE"/*; : > "$W/api/posts.jsonl"; rm -f "$W/api/down"; printf '%s' "${1-$GOOD}" > "$FAKE/body"; }
la() { (cd "$W/repo" && "$LA" "$@") > "$W/out" 2>&1; RC=$?; }
lockgone() { local _; for _ in $(seq 1 150); do [ -z "$(find "$T/locks" -name '*.lock' 2>/dev/null)" ] && return 0; sleep 0.2; done; return 1; }
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
check "…due TODAY in Central (fixable now), never tomorrow by default" eval 'posts | jq -e --arg d "$(TZ=America/Chicago date +%F)" "select(.next_date == \$d)" >/dev/null'
check "…one row, owner claude, stop LAND_AFTER_PR_9" eval '[ "$(posts | grep -c .)" -eq 1 ] && posts | jq -e "select(.owner == \"claude\" and .stop == \"LAND_AFTER_PR_9\" and .repo == \"t/fixture\")" >/dev/null'
check "…next_step is one sentence naming the PR, the step and the sheet" eval 'posts | jq -r .next_step | grep -q "E2E_RED.*t/fixture#9.*$T/redjob.md"'
check "…the sheet says the row was filed" grep -q 'Open Loops row LAND_AFTER_PR_9 filed' "$T/redjob.md"
# A later green try closes the row.
reset; la 9 --task redjob; lockgone
check "a later green try of the same PR: PASS and the row closed" eval 'line1 "$T/done/redjob.md" | grep -q "^STATUS: PASS" && posts | jq -e "select(.stop == \"LAND_AFTER_PR_9\" and .cleared == true)" >/dev/null'

echo "=== the poster: every open row says which day it means ==="
reset; node "$HERE/../open-loops.mjs" '{"repo":"t/x","stop":"NO_DAY","owner":"claude","business":"personal","title":"t"}' > "$W/out" 2>&1; RC=$?
check "a row with no next_date: refused NAMED STOP [OPEN_LOOPS_NO_DAY] (rc 2), nothing posted" eval '[ "$RC" -eq 2 ] && has "OPEN_LOOPS_NO_DAY" && [ -z "$(posts)" ]'
node "$HERE/../open-loops.mjs" '{"repo":"t/x","stop":"D","owner":"claude","business":"personal","title":"t","next_date":"tomorrow"}' >/dev/null 2>&1
check "…\"tomorrow\" is resolved to tomorrow's date in Central" eval 'posts | jq -e --arg d "$(TZ=America/Chicago date -v+1d +%F 2>/dev/null || TZ=America/Chicago date -d tomorrow +%F)" "select(.stop == \"D\" and .next_date == \$d)" >/dev/null'
node "$HERE/../open-loops.mjs" '{"repo":"t/x","stop":"D","cleared":true}' >/dev/null 2>&1
check "…a closing post needs no day" eval 'posts | jq -e "select(.stop == \"D\" and .cleared == true)" >/dev/null'

echo "=== outage: unknown, never PASS ==="
reset; echo ratelimit > "$FAKE/checks-mode"; echo $(( $(date +%s) + 7200 )) > "$FAKE/reset-at"
LAND_AFTER_RATE_HOLD_MAX_SECS=1 la 10 --task ratelimited; lockgone
check "allowance spent past every wait: FAIL naming the rate limit, land never ran" eval 'line1 "$T/ratelimited.md" | grep -q "^STATUS: FAIL .*unknown: .*rate limit: GitHub.s allowance resets in" && [ ! -f "$FAKE/land-ran" ]'
check "…a wait, not a failure: NO Open Loops row, the sheet says why and when to run again" eval '[ -z "$(posts)" ] && grep -q "no Open Loops row (a wait, not a failure)" "$T/ratelimited.md"'
check "…started over after each reset wait, 3 starts in all, one checks read each (never burning the wait)" eval '[ "$(grep -c "^pr checks" "$FAKE/gh-log")" -eq 3 ] && [ "$(grep -c "starting over" "$T/logs/ratelimited-10.log")" -eq 2 ]'
reset; echo ratelimit-once > "$FAKE/land-mode"; echo $(( $(date +%s) + 1 )) > "$FAKE/reset-at"
LAND_AFTER_RATE_HOLD_MAX_SECS=10 la 31 --task landlimited; lockgone
check "land stopped by a spent allowance (the 22 Nov 403): waits for the reset, lands again, PASS, no row" eval 'line1 "$T/done/landlimited.md" | grep -q "^STATUS: PASS" && [ "$(grep -c . "$FAKE/land-log")" -eq 2 ] && [ -z "$(posts | jq -c "select(.cleared != true)")" ]'
reset; echo badcreds > "$FAKE/land-mode"
la 32 --task badcreds; lockgone
check "a 401 (bad credentials) is a failure, not a wait: one land, a row due today in Central" eval '[ "$(grep -c . "$FAKE/land-log")" -eq 1 ] && posts | jq -e --arg d "$(TZ=America/Chicago date +%F)" "select(.stop == \"LAND_AFTER_PR_32\" and .next_date == \$d)" >/dev/null'
reset
la 33 --task thenlimited --then "echo x >> $W/thenruns; echo rate limit; exit 1"; lockgone
check "a rate limit after the merge is confirmed: no start-over, land once, the --then once" eval '[ "$(grep -c . "$FAKE/land-log")" -eq 1 ] && [ "$(grep -c . "$W/thenruns")" -eq 1 ] && ! grep -q "starting over" "$T/logs/thenlimited-33.log"'
rm -f "$W/thenruns"
reset; echo ratelimit > "$FAKE/checks-mode"; echo $(( $(date +%s) + 7200 )) > "$FAKE/reset-at"
LAND_AFTER_RATE_HOLD_MAX_SECS=30 la 34 --task killwait
for _ in $(seq 1 50); do grep -q "starting over" "$T/logs/killwait-34.log" 2>/dev/null && break; sleep 0.2; done
kill -TERM "$(cat "$T/locks/slugs/killwait.lock/pid")" 2>/dev/null; lockgone
check "F4: a kill during the reset wait stops the worker (FAIL, stopped by a signal), never a fresh start" eval 'line1 "$T/killwait.md" | grep -q "^STATUS: FAIL .*stopped by a signal" && [ "$(grep -c "^pr checks" "$FAKE/gh-log")" -eq 1 ]'
reset; echo flaky > "$FAKE/checks-mode"
LAND_AFTER_READ_PATIENCE_SECS=10 la 23 --task flaky; lockgone   # 1+2 s of backoff; 10 s so a slow second never gives up early
check "F2: two network failures reading checks are asked again with backoff, then PASS" eval 'line1 "$T/done/flaky.md" | grep -q "^STATUS: PASS" && grep -q "asking again in" "$T/logs/flaky-23.log"'
reset; echo ratelimit-until > "$FAKE/checks-mode"; echo $(( $(date +%s) + 2 )) > "$FAKE/reset-at"
LAND_AFTER_READ_PATIENCE_SECS=1 la 24 --task waitreset; lockgone
check "F2: allowance spent, resetting inside the wait: one sleep to the reset (past the 1 s patience), then PASS" eval 'line1 "$T/done/waitreset.md" | grep -q "^STATUS: PASS" && grep -q "waiting [0-9]*s for its reset" "$T/logs/waitreset-24.log"'
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
check "…nor an npm, Google, JWT or bare 40-character Cloudflare token" eval '! grep -qE "npm_AbCd|AIzaSyA1|eyJhbGci|Zk3pQ9vX" "$T/logs/secrets-17.log"'
check "…while a 40-character git sha stays readable" grep -q 'commit 0123456789abcdef0123456789abcdef01234567' "$T/logs/secrets-17.log"
reset
FAKE_LAND_SECS=2 la 19 --task thensecret --then "echo CLOUDFLARE_API_TOKEN=thenvalue987 > /dev/null"
sleep 0.5
# shellcheck disable=SC2034 # read inside an eval below
WP="$(cat "$T"/locks/slugs/thensecret.lock/pid 2>/dev/null)"
check "--then text is never on the worker's command line (ps)" eval '[ -n "$WP" ] && ! ps -p "$WP" -o command= | grep -q thenvalue987'
check "…its file is readable by this user only" eval 'find "$T"/locks/t_fixture-19.lock/then -perm 600 | grep -q .'
lockgone
check "…and its echo in the log is masked" eval 'grep -q "^=== then: echo CLOUDFLARE_API_TOKEN=\[masked\]" "$T/logs/thensecret-19.log" && ! grep -q thenvalue987 "$T/logs/thensecret-19.log"'
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
mkdir -p "$T/locks/t_fixture-20.lock" "$T/locks/slugs/killed.lock"; echo killed > "$T/locks/t_fixture-20.lock/slug"; echo 999999 > "$T/locks/t_fixture-20.lock/pid"; echo 999999 > "$T/locks/slugs/killed.lock/pid"
printf 'STATUS: landing t/fixture#21 aaa 2026-11-22T01:00\n' > "$T/oldlanding.md"; old 0.1 "$T/oldlanding.md"
"$LA" --status > "$W/out" 2>&1
check "landing with a dead worker pid: stale" grep -q '^killed  STATUS: landing .*\[stale: landing, no land running\]' "$W/out"
check "landing 2.4 h old with no worker: stale" grep -q '^oldlanding  .*\[stale: landing' "$W/out"
check "nothing shown as running" eval '! grep -q "\\[running" "$W/out"'
check "done/ sheets are not listed" eval '! grep -q "done/" "$W/out"'

echo "=== N4: --sweep files a land whose worker is gone ==="
old 0.01 "$T/killed.md"; : > "$W/api/posts.jsonl"
"$LA" --sweep > "$W/out" 2>&1
check "a landing sheet with a dead worker: FAIL unknown naming the dead worker" eval 'line1 "$T/killed.md" | grep -q "^STATUS: FAIL t/fixture#20 .*unknown: the land-after worker is gone"'
check "…its Open Loops row is filed (stop LAND_AFTER_PR_20)" eval 'posts | jq -e "select(.stop == \"LAND_AFTER_PR_20\")" >/dev/null'
check "…its dead slug lock is dropped, and the OUTPUT line counts it" eval '[ ! -e "$T/locks/slugs/killed.lock" ] && has "OUTPUT land-after sweep: 2 dead land(s) filed"'
rm -rf "$T/locks/t_fixture-20.lock"; rm -f "$T/killed.md" "$T/oldlanding.md"
# A dead holder's lock does not block a new land of that PR.
mkdir -p "$T/locks/t_fixture-22.lock"; echo x > "$T/locks/t_fixture-22.lock/slug"; echo 999999 > "$T/locks/t_fixture-22.lock/pid"
reset; la 22 --task afterkill; lockgone
check "a dead worker's lock is taken over; the new land ends PASS" eval 'line1 "$T/done/afterkill.md" | grep -q "^STATUS: PASS"'


echo "=== F1: one sheet is one job's ==="
reset; printf 'STATUS: building seq23/other#99 abc 2026-11-22\nGoal: another job\n' > "$T/theirs.md"
# shellcheck disable=SC2034 # read inside an eval below
SUM="$(cksum < "$T/theirs.md")"
la 30 --task theirs
check "a sheet whose line 1 names another PR: refused, land never ran" eval '[ "$RC" -eq 1 ] && has "belongs to seq23/other#99" && [ ! -f "$FAKE/land-ran" ]'
check "…the sheet byte for byte the same, and no lock left" eval '[ "$(cksum < "$T/theirs.md")" = "$SUM" ] && [ -z "$(find "$T/locks" -name "*.lock")" ]'
reset; printf 'STATUS: building\nGoal: g\n' > "$T/shared.md"
FAKE_LAND_SECS=3 la 31 --task shared
check "first PR on a sheet: rc 0" [ "$RC" -eq 0 ]
sed -i.bak '1s/.*/STATUS: building/' "$T/shared.md"; rm -f "$T/shared.md.bak"
la 32 --task shared
check "a second PR on the same sheet while the first lands (line 1 names no PR): refused by the sheet lock" eval '[ "$RC" -eq 1 ] && has "is held by another land" && ! grep -q "^land 32" "$FAKE/land-log" 2>/dev/null'
lockgone; check "…the first still ends PASS" eval 'line1 "$T/done/shared.md" | grep -q "^STATUS: PASS t/fixture#31"'

echo "=== N8: a PASS comment counts only from the repo's owner account ==="
reset "Fixes it."; jq -nc --arg b "$GOOD" '[{author: {login: "seq23"}, authorAssociation: "OWNER", body: $b}]' > "$FAKE/comments"
la 33 --task ownercomment; lockgone
check "the reviewer's PASS in an owner-account comment: lands" eval 'line1 "$T/done/ownercomment.md" | grep -q "^STATUS: PASS"'
reset "Fixes it."; jq -nc --arg b "$GOOD" '[{author: {login: "passerby"}, authorAssociation: "NONE", body: $b}]' > "$FAKE/comments"
la 34 --task strangercomment
check "the same PASS in a comment by anyone else: refused, nothing started" eval '[ "$RC" -eq 1 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/strangercomment.md" ]'

echo "=== N1: a worker that never starts is reported, the sheet put back ==="
reset; printf 'STATUS: review\nGoal: kept\n' > "$T/nostart.md"
# shellcheck disable=SC2034 # read inside an eval below
SUM="$(cksum < "$T/nostart.md")"
mkdir -p "$W/badperl"; printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = --worker ] && { echo "perl: cannot detach" >&2; exit 1; }; done\nexec /usr/bin/perl "$@"\n' > "$W/badperl/perl"; chmod +x "$W/badperl/perl"
PATH="$W/badperl:$PATH" LAND_AFTER_START_WAIT_SECS=2 la 35 --task nostart
check "detach fails: refused, saying the worker did not start" eval '[ "$RC" -eq 1 ] && has "did not start" && [ ! -f "$FAKE/land-ran" ]'
check "…the sheet is as it was and no lock is left" eval '[ "$(cksum < "$T/nostart.md")" = "$SUM" ] && [ -z "$(find "$T/locks" -name "*.lock")" ]'
rm -f "$T/nostart.md"

echo "=== N7: a sheet that cannot be written drops both locks ==="
reset; chmod 555 "$T"   # the sheet folder read-only: the status line cannot be written
la 36 --task unwritable; chmod 755 "$T"
check "set_status fails: refused, and neither lock is left behind" eval '[ "$RC" -eq 1 ] && has "could not write" && [ -z "$(find "$T/locks" -name "*.lock")" ] && [ ! -f "$FAKE/land-ran" ]'

echo "=== R3: a worker that ends inside the starter's poll leaves no lock behind ==="
reset; printf 'STATUS: review t/fixture#37 x 2026-11-22\nGoal: g\n' > "$T/fastjob.md"
LAND_AFTER_TEST_CLEANUP_DELAY=1.5 la 37 --task fastjob   # the worker (instant land) is done before the starter cleans up
check "a fast worker: started, and no lock is left once it ends" eval '[ "$RC" -eq 0 ] && lockgone'
check "…no backup is left beside the locks" eval '[ -z "$(find "$T/locks" -name "*.sheet.before*")" ]'
reset; la 37 --task fastjob
check "…the same sheet can be landed again at once (not held as 'starting')" eval '[ "$RC" -eq 0 ] && lockgone'
rm -f "$T/fastjob.md" "$T/done/fastjob.md"

echo "=== N13: a backup a killed starter left is never restored over the sheet ==="
reset; rm -f "$T/stalejob.md"; mkdir -p "$T/locks/slugs"; printf 'STATUS: review OLD\nGoal: stale\n' > "$T/locks/slugs/stalejob.lock.sheet.before.99999"
PATH="$W/badperl:$PATH" LAND_AFTER_START_WAIT_SECS=2 la 38 --task stalejob
check "the worker fails to start on a slug with no sheet: no stale sheet is put back" eval '[ "$RC" -eq 1 ] && [ ! -e "$T/stalejob.md" ]'
check "…and the stale backup is cleared" eval '[ -z "$(find "$T/locks" -name "stalejob*")" ]'

echo "=== N6: a log an open FAIL sheet names is kept past 14 days ==="
printf 'STATUS: FAIL t/fixture#9 x 2026-11-01 — red; log %s\n' "$T/logs/evidence-9.log" > "$T/evidence.md"
echo x > "$T/logs/evidence-9.log"; old 20 "$T/logs/evidence-9.log"; echo x > "$T/logs/orphan.log"; old 20 "$T/logs/orphan.log"
"$LA" --status > "$W/out" 2>&1
check "the named log kept, an unnamed one of the same age deleted" eval '[ -e "$T/logs/evidence-9.log" ] && [ ! -e "$T/logs/orphan.log" ]'
rm -f "$T/evidence.md"

echo
echo "land-after: $pass passed, $failn failed"
[ "$pass" -gt 0 ] || { echo "FAIL: zero checks ran"; exit 1; }
[ "$failn" -eq 0 ]
