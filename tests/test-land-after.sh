#!/bin/bash
# land-after, driven for real (a real detached worker, a fake gh, a fake lander, a stub Open Loops intake that
# must see ZERO posts: a land's result goes on its task sheet, never on her Open Loops list, 22 Nov 2026)
# against a fake HOME. Each case is a way it breaks (22 Nov 2026 brief, "how it breaks"):
#   abuse/mistake  no PASS line, a builder-signed PASS, the same PR twice, a slug with / or .. -> refused, nothing started
#   data loss      only its own sheet is touched; cleanup touches only done/ and logs/ past 14 days; a sheet
#                  deleted mid-land is recreated with the result; secrets never reach the log
#   outage         gh rate-limited, land "could not verify", the merge unreadable after land -> FAIL unknown, never
#                  PASS; any FAIL (red, rate limit, network, auth, dead worker) -> line 1 FAIL and zero posts;
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
export BOSS_OPEN_LOOPS_TOKEN=olt_testtoken123 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; failn=0
check() { local d="$1"; shift; if "$@"; then pass=$((pass + 1)); echo "  ok  $d"; else failn=$((failn + 1)); echo "  FAIL $d"; fi; }

# --- a stub Open Loops intake: the real poster (open-loops.mjs) would post here; nothing may ---
cat > "$W/stub.mjs" <<'JS'
import http from "node:http"; import fs from "node:fs";
const dir = process.argv[2];
http.createServer((req, res) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => {
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
[ "$1 $2" = "pr checks" ] && echo "${GH_SHARE_UNTIL:-none}" > "$F/checks-until"   # the deadline ~/bin/gh is given
mode() { cat "$F/$1" 2>/dev/null; }
case "$1 $2" in
  "api repos/{owner}/{repo}/commits/"*) # when the PR's commit reached GitHub (its earliest check suite): $F/suite-at
    jq -rn --arg t "$(cat "$F/suite-at" 2>/dev/null || echo 2026-11-22T12:05:00Z)" '$t | fromdateiso8601'; exit 0 ;;   # jq: CI is Linux, BSD date -j is not there
  "api rate_limit") # the allowance GitHub reports: spent with a reset at $F/reset-at while rate limited
    if [ -f "$F/reset-at" ]; then jq -n --argjson r "$(cat "$F/reset-at")" '{resources: {core: {remaining: 0, reset: $r}, graphql: {remaining: 5000, reset: $r}}}' | jq -r "${4:-.}"
    else echo 0 | jq -r '.'; fi; exit 0 ;;
  "pr view")
    [ "$(mode view-mode)" = ratelimit-until ] && [ "$(date +%s)" -lt "$(cat "$F/reset-at")" ] \
      && { echo "GraphQL: API rate limit exceeded for user ID 1." >&2; exit 1; }
    { [ "$(mode view-mode)" = down ] || { [ "$(mode view-mode)" = down-after-land ] && [ -f "$F/land-ran" ]; }; } \
      && { echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1; }
    st=OPEN; mc=null; [ -f "$F/merged" ] && { st=MERGED; mc='{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'; }
    cm="$(cat "$F/comments" 2>/dev/null || echo '[]')"
    lb="$(cat "$F/labels" 2>/dev/null || echo null)"   # labels: absent = not in GitHub's answer (unread)
    # url: the repo the PR is in (default seq23/seq-bin, on the shipped live-repos.json); a Review class: none line
    # is in every body unless no-class.
    body="$(mode body)"; [ -f "$F/no-class" ] || body="$body"$'\n\n''Review class: none — a fixture change in no risk class'
    jq -n --arg head "$HEADSHA" --arg body "$body" --arg st "$st" --argjson mc "$mc" --arg n "$3" --argjson cm "$cm" --argjson lb "$lb" \
      --arg url "$(cat "$F/url" 2>/dev/null || echo "https://github.com/seq23/seq-bin/pull/$3")" \
      '{state: $st, body: $body, comments: $cm, headRefOid: $head, headRefName: "feat", title: "A change",
        url: $url, author: {login: "builder-bot"}, commits: [], mergeCommit: $mc, files: [{path: "worker/x.ts"}]}
       + (if $lb == null then {} else {labels: $lb} end)' ;;
  "api --paginate") # every label ever added (gh's --jq answer over the issue events): $F/label-events, default none; down = no answer
    [ "$(mode label-events)" = down ] && { echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1; }
    cat "$F/label-events" 2>/dev/null || echo '[]'; exit 0 ;;
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
  outcome) echo "task=${LAND_TASK:-}" > "$F/land-task"; printf '\n--- NOT BUILT (PR #%s, word for word) ---\n- the job-target lever (G1)\n- G19, the sales reader\n--- END NOT BUILT ---\n' "$1"
           echo "     OUTCOME-CHECK DUE t/fixture#$1 bbb — task:${LAND_TASK:-} by:2026-11-25 expect:>=3 — outcome: x — check: y"; echo "     OUTCOME: check due 2026-11-25 — Noelle acts on her decisions"; : > "$F/merged"; exit 0 ;;
  nonecut) printf '\n--- NOT BUILT (PR #%s, word for word) ---\nNothing cut.\n--- END NOT BUILT ---\n' "$1"; : > "$F/merged"; exit 0 ;;
  red) echo "4/5  e2e"; printf '\033[31mSTOPPED: NAMED STOP [E2E_RED_AFTER_LARGE_CHANGE] e2e run 9 ended failure\033[0m\n'; exit 1 ;;
  unverified) printf '\033[31mSTOPPED: could not verify (network) — TLS handshake timeout. Nothing was merged by this step\033[0m\n'; exit 75 ;;
  ratelimited) printf '\033[31mSTOPPED: could not verify (rate limit) — HTTP 403: API rate limit exceeded. Nothing was merged by this step\033[0m\n'; exit 75 ;;
  deployfail) printf '\033[31mSTOPPED: the deploy from abc1234 failed: npm ci in the deploy worktree at abc1234 exited 1: %s. #%s IS MERGED and main is green (a 7403 is a missing CLOUDFLARE_ACCOUNT_ID, not permissions).\033[0m\n' "$(cat "$F/why")" "$1"; : > "$F/merged"; exit 1 ;;
  authfail) printf '\033[31mSTOPPED: could not verify (auth) — HTTP 401: Requires authentication. Nothing was merged by this step\033[0m\n'; exit 75 ;;
  secret) echo "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456 CLOUDFLARE_API_TOKEN=cfsecretvalue123"
          echo "npm npm_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 google AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUvW jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
          echo "cf Zk3pQ9vX2mL7nR4tY8wB1cD6fG0hJ5kM3sA9qE2u commit 0123456789abcdef0123456789abcdef01234567"
          : > "$F/merged"; exit 0 ;;
esac
SH
chmod +x "$BIN/gh" "$W/fake-land"
# The checkout: its origin is a real local repo at a path that reads as github.com/t/fixture, so land-after's
# fresh_pass reads real commits: main, then the PR's one commit on top (HEADSHA, the head the fake gh reports).
git init -q --bare -b main "$W/github.com/t/fixture.git"
git init -q -b main "$W/repo" && git -C "$W/repo" remote add origin "$W/github.com/t/fixture.git" && git -C "$W/repo" commit -q --allow-empty -m init
git -C "$W/repo" push -q origin main && git -C "$W/repo" fetch -q origin
GIT_COMMITTER_DATE="2026-11-22T12:00:00Z" git -C "$W/repo" commit -q --allow-empty -m "the PR's work"
HEADSHA="$(git -C "$W/repo" rev-parse HEAD)"; export HEADSHA; git -C "$W/repo" reset -q --hard origin/main
# land reads 7-40 hex characters with at least one a-f as a commit: an all-digit prefix is lengthened, never a flake.
eval "$(grep '^sha_name() ' "$(dirname "$LA")/land")"   # land's own helper, never a copy
GOOD="Ship-ready: PASS — reviewer session_rev123 looked at the self-test output and a detached land at $(sha_name "$HEADSHA"); Engineering: PASS"
reset() { rm -f "$FAKE"/*; : > "$W/api/posts.jsonl"; printf '%s' "${1-$GOOD}" > "$FAKE/body"; }
la() { (cd "$W/repo" && "$LA" "$@") > "$W/out" 2>&1; RC=$?; }
lockgone() { local _; for _ in $(seq 1 150); do [ -z "$(find "$T/locks" -name '*.lock' 2>/dev/null)" ] && return 0; sleep 0.2; done; return 1; }
has() { grep -qF -- "$1" "$W/out"; }
line1() { head -1 "$1" 2>/dev/null; }
no_posts() { [ ! -s "$W/api/posts.jsonl" ]; }

echo "=== abuse and mistakes: refused, nothing started ==="
reset "Fixes it."
la 7 --task nopass
check "no PASS line: refused (rc 4: needs a reviewer)" [ "$RC" -eq 4 ]
check "…with the line to add" has "Ship-ready: PASS"
check "…land never ran, no sheet, no log, no lock" eval '[ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/nopass.md" ] && [ -z "$(find "$T" -type f 2>/dev/null)" ]'
reset "Ship-ready: PASS — reviewer looked at it"
la 7 --task noeng
check "a PASS line without '; Engineering: PASS': refused, nothing started" eval '[ "$RC" -eq 4 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/noeng.md" ]'
reset "Ship-ready: PASS — builder-bot looked at it; Engineering: PASS"
la 7 --task selfsigned
check "a PASS signed by the PR's builder: refused, nothing started" eval '[ "$RC" -eq 4 ] && has "signed by its builder" && [ ! -f "$FAKE/land-ran" ]'
reset
for bad in "../escape" "a/b" "x..y" ".hidden"; do
  la 7 --task "$bad"
  check "slug '$bad': refused, nothing written" eval '[ "$RC" -eq 1 ] && [ ! -f "$FAKE/land-ran" ] && [ -z "$(find "$W/home" -name "*.md" 2>/dev/null)" ]'
done
reset; echo down > "$FAKE/view-mode"
la 7 --task ghdown
check "the PR unreadable at the start: exit 75 'could not verify', nothing started" eval '[ "$RC" -eq 75 ] && has "could not verify" && [ ! -e "$T/ghdown.md" ] && [ ! -f "$FAKE/land-ran" ]'

echo "=== Fast PRs (her ruling 23 Nov 2026): the PASS is asked for only of a review-class PR ==="
reset "Fixes it."; echo '[{"name":"review-required"}]' > "$FAKE/labels"
la 7 --task fastreview
check "safety: review-required label and no PASS line: refused, nothing started" eval '[ "$RC" -eq 4 ] && has "Ship-ready: PASS" && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/fastreview.md" ]'
reset "Fixes it."; echo '[]' > "$FAKE/labels"
la 7 --task fastplain
check "happy path: no review class, no PASS line: started at once (rc 0)" [ "$RC" -eq 0 ]
check "…and lands: PASS on line 1, in done/" eval 'lockgone && line1 "$T/done/fastplain.md" | grep -q "^STATUS: PASS t/fixture#7 "'

# 23 Nov 2026: lands lost because the worker ran inside an agent's worktree that was removed right after.
reset "Fixes it."; echo '[]' > "$FAKE/labels"
git -C "$W/repo" worktree add -q "$W/wt-agent" -b agent-branch 2>/dev/null
(cd "$W/wt-agent" && "$LA" 7 --task fromwt) > "$W/out" 2>&1; RC=$?
git -C "$W/repo" worktree remove --force "$W/wt-agent"
check "started from a linked worktree that is removed at once: the worker runs in the main checkout and lands" \
  eval '[ "$RC" -eq 0 ] && lockgone && line1 "$T/done/fromwt.md" | grep -q "^STATUS: PASS t/fixture#7 " && grep -qE "in (/private)?$W/repo [(]sheet" "$T"/logs/fromwt-7.log'

reset "Fixes it."; echo '[]' > "$FAKE/labels"; : > "$FAKE/no-class"
la 7 --task noclass
check "safety: no Review class line and no PASS: refused, saying what to add, nothing started" eval '[ "$RC" -eq 4 ] && has "Review class: none — <why>" && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/noclass.md" ]'
reset $'Fixes it.\nReview class: none — log wording only'; echo '[]' > "$FAKE/labels"; : > "$FAKE/no-class"
la 7 --task noneclass
check "happy path: 'Review class: none — log wording only', no PASS: started at once (rc 0)" eval '[ "$RC" -eq 0 ] && lockgone'
reset "Fixes it."; echo '[]' > "$FAKE/labels"; echo '["review-required"]' > "$FAKE/label-events"
la 7 --task wasLabeled
check "abuse: review-required added then taken off, no PASS: refused, nothing started" eval '[ "$RC" -eq 4 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/wasLabeled.md" ]'
reset "Fixes it."; echo '[]' > "$FAKE/labels"; echo down > "$FAKE/label-events"
la 7 --task evdown
check "outage: the label history unread: exit 75 'could not verify', nothing started" eval '[ "$RC" -eq 75 ] && has "label history" && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/evdown.md" ]'
reset "Fixes it."; echo '[]' > "$FAKE/labels"; echo "https://github.com/t/fixture/pull/7" > "$FAKE/url"
la 7 --task unlisted
check "new until launched: a repo not on live-repos.json, no PASS: refused, nothing started" eval '[ "$RC" -eq 4 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/unlisted.md" ]'

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
check "…the sheet said landing while land ran" eval 'line1 "$T/job1.md" | grep -q "^STATUS: landing t/fixture#7 ${HEADSHA:0:7}" || [ -f "$T/done/job1.md" ]'
check "…the worker finished after its starter's process group was killed" lockgone
check "…PASS with the merge sha on line 1, moved to done/" eval 'line1 "$T/done/job1.md" | grep -q "^STATUS: PASS t/fixture#7 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb " && [ ! -e "$T/job1.md" ]'
check "…the rest of the sheet kept" grep -q 'built (abc123)' "$T/done/job1.md"
check "…its checks reads gave ~/bin/gh the read's own deadline, so the wrapper never sleeps past it" eval '[[ "$(cat "$FAKE/checks-until")" =~ ^[0-9]{10}$ ]]'
check "…both --then ran, in order" eval '[ "$(cat "$W/thens" 2>/dev/null | paste -sd, -)" = "one,two" ]'
check "…pending checks were waited for before land" eval '[ "$(grep -c "^pr checks" "$FAKE/gh-log")" -ge 2 ]'
check "…land ran in the repo's checkout" grep -q "pwd=$(cd "$W/repo" && pwd -P)" "$FAKE/land-log"
check "…the log ends with the OUTPUT line" grep -q '^OUTPUT land-after t/fixture#7 PASS bbbbbbb' "$T/logs/job1-7.log"
check "…another agent's sheet is byte for byte the same" eval '[ "$(cksum < "$T/other.md")" = "$OTHER_SUM" ]'
check "…nothing posted to Open Loops on a green land" no_posts
rm -f "$T/other.md"

echo "=== the same PR twice: the second is refused by the lock ==="
reset
FAKE_LAND_SECS=3 la 8 --task first
check "first start: rc 0" [ "$RC" -eq 0 ]
la 8 --task second
check "second start on the same PR: refused" eval '[ "$RC" -eq 1 ] && has "already being landed"'
check "…and it wrote no sheet of its own" eval '[ ! -e "$T/second.md" ] && [ ! -e "$T/logs/second-8.log" ]'
lockgone; check "…the first still ends PASS" eval 'line1 "$T/done/first.md" | grep -q "^STATUS: PASS"'

echo "=== --holds and --dry-run (pr-watch, 23 Nov 2026): a held PR is seen, a dry run starts nothing ==="
reset
FAKE_LAND_SECS=3 la 11 --task holder
check "a land started on #11: rc 0" [ "$RC" -eq 0 ]
"$LA" --holds t/fixture 11 > "$W/holds" 2>&1; hrc=$?
check "--holds: rc 0 while a live land holds the PR, with its pid" eval '[ "$hrc" -eq 0 ] && grep -qE "^[0-9]+$" "$W/holds"'
la 11 --dry-run
check "--dry-run on a held PR: refused, already being landed" eval '[ "$RC" -eq 1 ] && has "already being landed"'
lockgone
"$LA" --holds t/fixture 11 >/dev/null 2>&1; hrc=$?
check "--holds: rc 1 once the land is over" [ "$hrc" -eq 1 ]
mkdir -p "$T/locks/t_fixture-12.lock"; echo 999999 > "$T/locks/t_fixture-12.lock/pid"; touch -t 202601010000 "$T/locks/t_fixture-12.lock"
"$LA" --holds t/fixture 12 >/dev/null 2>&1; hrc=$?
check "--holds: a dead holder's lock is not a hold (rc 1)" [ "$hrc" -eq 1 ]
rm -rf "$T/locks/t_fixture-12.lock"
"$LA" --holds "bad repo" 12 >/dev/null 2>&1; hrc=$?
check "--holds: a malformed repo is refused (rc 1), never read as held" [ "$hrc" -eq 1 ]
reset
la 13 --dry-run
check "--dry-run on a ready PR: rc 0, 'would land'" eval '[ "$RC" -eq 0 ] && has "would land t/fixture#13"'
check "…nothing started: no land, no sheet, no lock, no log" eval '[ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/pr-fixture-13.md" ] && [ ! -e "$T/logs/pr-fixture-13-13.log" ] && [ -z "$(find "$T" -name "*.lock" 2>/dev/null)" ]'
reset "Fixes it."; : > "$FAKE/no-class"
la 14 --dry-run
check "--dry-run on a review-class PR with no PASS: rc 4 (needs a reviewer), nothing started" eval '[ "$RC" -eq 4 ] && [ ! -f "$FAKE/land-ran" ]'

echo "=== red: FAIL with the step and log on line 1, sheet stays open, NOTHING on Open Loops ==="
reset; echo red > "$FAKE/land-mode"
la 9 --task redjob; lockgone
check "STATUS: FAIL names the failing step and the log" eval 'line1 "$T/redjob.md" | grep -q "^STATUS: FAIL t/fixture#9 .*E2E_RED_AFTER_LARGE_CHANGE.*log $T/logs/redjob-9.log"'
check "…sheet stays open (not in done/)" eval '[ -f "$T/redjob.md" ] && [ ! -e "$T/done/redjob.md" ]'
check "…zero posts to the Open Loops intake" no_posts
check "…the log ends with the FAIL OUTPUT line naming the step" grep -q '^OUTPUT land-after t/fixture#9 FAIL — .*E2E_RED_AFTER_LARGE_CHANGE' "$T/logs/redjob-9.log"
# A later green try of the same sheet ends PASS, still posting nothing.
reset; la 9 --task redjob; lockgone
check "a later green try of the same PR: PASS, zero posts" eval 'line1 "$T/done/redjob.md" | grep -q "^STATUS: PASS" && no_posts'

echo "=== outage: unknown, never PASS ==="
reset; echo ratelimit > "$FAKE/checks-mode"; echo $(( $(date +%s) + 7200 )) > "$FAKE/reset-at"
la 10 --task ratelimited; lockgone
check "allowance spent with its reset after the wait ends: FAIL unknown naming the reset, land never ran" eval 'line1 "$T/ratelimited.md" | grep -q "^STATUS: FAIL .*unknown: .*rate limit: GitHub.s allowance resets in 12[01] min" && [ ! -f "$FAKE/land-ran" ]'
check "…zero posts to the Open Loops intake" no_posts
check "…and it did not burn the wait asking again (one checks read)" eval '[ "$(grep -c "^pr checks" "$FAKE/gh-log")" -eq 1 ]'
reset; echo flaky > "$FAKE/checks-mode"
LAND_AFTER_READ_PATIENCE_SECS=10 la 23 --task flaky; lockgone   # 1+2 s of backoff; 10 s so a slow second never gives up early
check "F2: two network failures reading checks are asked again with backoff, then PASS" eval 'line1 "$T/done/flaky.md" | grep -q "^STATUS: PASS" && grep -q "asking again in" "$T/logs/flaky-23.log"'
reset; echo ratelimit-until > "$FAKE/checks-mode"; echo $(( $(date +%s) + 2 )) > "$FAKE/reset-at"
LAND_AFTER_READ_PATIENCE_SECS=1 la 24 --task waitreset; lockgone
check "F2: allowance spent, resetting inside the wait: one sleep to the reset (past the 1 s patience), then PASS" eval 'line1 "$T/done/waitreset.md" | grep -q "^STATUS: PASS" && grep -q "waiting [0-9]*s for its reset" "$T/logs/waitreset-24.log"'
reset; echo ratelimit-until > "$FAKE/view-mode"; echo $(( $(date +%s) + 2 )) > "$FAKE/reset-at"
la 25 --task ratelaunch; lockgone
check "allowance spent when land-after starts (22 Nov 2026, #134): waits for the reset, then lands; no FAIL, zero posts" eval 'line1 "$T/done/ratelaunch.md" | grep -q "^STATUS: PASS" && [ -f "$FAKE/land-ran" ] && no_posts'
reset; echo unverified > "$FAKE/land-mode"
la 11 --task netdown; lockgone
check "land exit 75 (network down mid-land): FAIL unknown, zero posts" eval 'line1 "$T/netdown.md" | grep -q "^STATUS: FAIL .*unknown: STOPPED: could not verify" && no_posts'
reset; echo ratelimited > "$FAKE/land-mode"
la 26 --task landrate; lockgone
check "land stopped by a spent allowance (exit 75): FAIL unknown with its STOPPED line on line 1, zero posts" eval 'line1 "$T/landrate.md" | grep -q "^STATUS: FAIL t/fixture#26 .*unknown: STOPPED: could not verify (rate limit)" && no_posts'
reset; echo authfail > "$FAKE/land-mode"
la 27 --task landauth; lockgone
check "land stopped by a failed sign-in (exit 75, auth): FAIL unknown with its STOPPED line, never PASS, zero posts" eval 'line1 "$T/landauth.md" | grep -q "^STATUS: FAIL t/fixture#27 .*unknown: STOPPED: could not verify (auth)" && [ ! -e "$T/done/landauth.md" ] && no_posts'
reset; echo down-after-land > "$FAKE/view-mode"
la 12 --task cantconfirm; lockgone
check "land green but the merge unreadable after: FAIL unknown, never PASS" eval 'line1 "$T/cantconfirm.md" | grep -q "^STATUS: FAIL .*unknown: land exited 0 but the merge could not be confirmed" && [ ! -e "$T/done/cantconfirm.md" ]'

echo "=== rule 0: land exits 0 having merged nothing ==="
# 22 Nov 2026 review F2: a deploy STOPPED line runs ~400 characters; the cause (npm's "Missing: ...") sat past
# a 220-character cut. The reason here is land's own deploy_tail of captured real npm output.
reset; echo deployfail > "$FAKE/land-mode"
( eval "$(sed -n '/^deploy_tail() {/,/^}/p' "$HERE/../land")"; deploy_tail "$HERE/fixtures/npm/ci-mismatch.out" ) > "$FAKE/why"
la 28 --task deployjob; lockgone
check "a failed deploy: line 1 keeps npm's cause, past the old 220-character cut" eval 'line1 "$T/deployjob.md" | grep -q "^STATUS: FAIL t/fixture#28 .*npm error code EUSAGE .*Missing: left-pad@1.3.0 from lock file"'
check "…and still says the PR is merged, with no colour codes" eval 'line1 "$T/deployjob.md" | grep -q "#28 IS MERGED and main is green" && ! line1 "$T/deployjob.md" | grep -qF "$(printf "\033")"'
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
check "…zero posts to the Open Loops intake" no_posts
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
check "the same PASS in a comment by anyone else: refused, nothing started" eval '[ "$RC" -eq 4 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/strangercomment.md" ]'

echo "=== a PASS voided by a later VERDICT: fail says so, and how to post it again (22 Nov 2026: 4 PRs refused 'no PASS') ==="
FAILC='[{"authorAssociation": "OWNER", "createdAt": "2026-11-22T14:00:00Z", "body": "VERDICT: fail\n- F1 the cap is unbounded"}]'
reset "$GOOD"; printf '%s' "$FAILC" > "$FAKE/comments"
la 35 --task voided
check "a PASS in the body before an owner VERDICT: fail: refused, nothing started (the newest verdict still wins)" eval '[ "$RC" -eq 4 ] && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/voided.md" ]'
check "…the refusal says the PASS is voided by the later fail, and when" eval 'has "PASS in the PR body does not count" && has "later VERDICT: fail comment (22 Nov 14:00 UTC) voids it"'
check "…and gives the fix: the PASS again as a new comment, at the head" eval 'has "gh pr comment 35 -R t/fixture" && has " at ${HEADSHA:0:8}; Engineering: PASS"'
reset "Fixes it."; jq -nc --arg b "$GOOD" '[{authorAssociation: "NONE", createdAt: "2026-11-22T13:00:00Z", body: $b}, {authorAssociation: "OWNER", createdAt: "2026-11-22T14:00:00Z", body: "VERDICT: fail"}]' > "$FAKE/comments"
la 36 --task voided-stranger
check "abuse: a stranger's PASS before an owner fail is never named as voided (it never counted): the plain refusal" eval '[ "$RC" -eq 4 ] && has "has no reviewer PASS line" && ! has "does not count" && ! has "session_rev123"'

echo "=== F2 (review of #137): the PASS is for this head, checked before anything starts ==="
SHALESS='Ship-ready: PASS — reviewer session_rev123 looked at the self-test output and a detached land; Engineering: PASS'
reset "$SHALESS"
la 40 --task shaless-body
check "a PASS naming no commit, in the body (time unknown): refused STALE_PASS, nothing started" eval '[ "$RC" -eq 4 ] && has "STALE_PASS" && has "nothing started" && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/shaless-body.md" ]'
reset "Fixes it."; jq -nc --arg b "$SHALESS" '[{authorAssociation: "OWNER", createdAt: "2026-11-22T13:00:00Z", body: $b}]' > "$FAKE/comments"
la 41 --task shaless-after; lockgone
check "the same line in an owner comment posted after the PR's last commit (12:00 -> 13:00): lands" eval 'line1 "$T/done/shaless-after.md" | grep -q "^STATUS: PASS"'
reset "Fixes it."; jq -nc --arg b "$SHALESS" '[{authorAssociation: "OWNER", createdAt: "2026-11-22T11:00:00Z", body: $b}]' > "$FAKE/comments"
la 42 --task shaless-before
check "…posted before the PR's last commit (11:00 < 12:00): refused STALE_PASS, nothing started" eval '[ "$RC" -eq 4 ] && has "STALE_PASS" && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/shaless-before.md" ]'
reset "Fixes it."; jq -nc --arg b "$SHALESS" '[{authorAssociation: "OWNER", createdAt: "2026-11-22T13:00:00Z", body: $b}]' > "$FAKE/comments"
echo 2026-11-22T13:30:00Z > "$FAKE/suite-at"
la 44 --task shaless-pushedlater
check "committed 12:00, PASS 13:00, reached GitHub 13:30 (review F5): refused STALE_PASS, nothing started" eval '[ "$RC" -eq 4 ] && has "STALE_PASS" && has "reached GitHub" && [ ! -f "$FAKE/land-ran" ] && [ ! -e "$T/shaless-pushedlater.md" ]'
rm -f "$FAKE/suite-at"
reset "Ship-ready: PASS — reviewer session_rev123 looked at it at 0123456789ab; Engineering: PASS"
la 43 --task notonpr
check "a PASS naming a commit that is not on the PR: refused STALE_PASS before the CI wait" eval '[ "$RC" -eq 4 ] && has "STALE_PASS" && [ ! -f "$FAKE/land-ran" ] && ! grep -q "^pr checks" "$FAKE/gh-log"'

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

echo "=== outcome gates (24 Nov 2026): landed is not done until the live check passes ==="
reset; printf 'STATUS: review t/fixture#40 x 2026-11-24\nGoal: g\nDone:\n- built (abc123)\n' > "$T/outjob.md"; echo outcome > "$FAKE/land-mode"
la 40 --task outjob; lockgone
check "an Outcome with a live check: line 1 LANDED-UNCHECKED with the due day, the sheet stays open (not in done/)" \
  eval 'line1 "$T/outjob.md" | grep -q "^STATUS: LANDED-UNCHECKED t/fixture#40 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb .* outcome check due 2026-11-25" && [ ! -e "$T/done/outjob.md" ]'
check "…land ran with the sheet's slug in LAND_TASK (the DUE line carries it)" grep -qx 'task=outjob' "$FAKE/land-task"
check "…the PR's Not built is copied under line 1, word for word, the rest of the sheet kept" \
  eval '[ "$(sed -n 2,5p "$T/outjob.md")" = "$(printf "## Not built (PR #40, from land)\n- the job-target lever (G1)\n- G19, the sales reader\n## End Not built")" ] && grep -q "^- built (abc123)$" "$T/outjob.md"'
sed -i.bak '1s/.*/STATUS: review t\/fixture#40 x 2026-11-24/' "$T/outjob.md"; rm -f "$T/outjob.md.bak"; : > "$W/api/posts.jsonl"
la 40 --task outjob; lockgone
check "…a second land of the same sheet keeps ONE Not built block" eval '[ "$(grep -c "^## Not built (PR #40" "$T/outjob.md")" -eq 1 ]'
LAND_AFTER_TODAY=2026-11-26 "$LA" --status > "$W/out" 2>&1
check "--status, a day after the due day: 'landed, not yet proven', never running or FAIL" \
  eval 'grep "^outjob " "$W/out" | grep -q "\[landed, not yet proven: outcome check due 2026-11-25\]" && ! grep "^outjob " "$W/out" | grep -qiE "running|\[stale: landing|FAIL"'
LAND_AFTER_TODAY=2026-11-27 "$LA" --status > "$W/out" 2>&1
check "--status, 2 days past the due day: NOT CHECKED, never dropped" grep -q '^outjob .*\[NOT CHECKED: outcome check 2026-11-25 is 2+ days late' "$W/out"
sed -i.bak '1s/.*/STATUS: LANDED-UNCHECKED t\/fixture#40 b 2026-11-24 — landed, not yet proven: outcome check due/' "$T/outjob.md"; rm -f "$T/outjob.md.bak"
LAND_AFTER_TODAY=2026-11-26 "$LA" --status > "$W/out" 2>&1
check "--status, a LANDED-UNCHECKED line whose due day cannot be read: NOT CHECKED (fails closed, never 'fine')" grep -q '^outjob .*\[NOT CHECKED: outcome check date unreadable' "$W/out"
printf 'STATUS: DONE t/fixture#41 b 2026-11-25 — outcome PASS\n' > "$T/donejob.md"
"$LA" --status > "$W/out" 2>&1
check "--status: an open DONE sheet reads done, never running or failed" eval 'grep "^donejob " "$W/out" | grep -q "\[done: live outcome checked\]" && ! grep "^donejob " "$W/out" | grep -qiE "running|FAIL"'
rm -f "$T/outjob.md" "$T/donejob.md"
reset; printf 'STATUS: review\nGoal: g\n' > "$T/nonejob.md"; echo nonecut > "$FAKE/land-mode"
la 42 --task nonejob; lockgone
check "Outcome none: PASS, to done/, with 'Nothing cut.' under line 1" \
  eval 'line1 "$T/done/nonejob.md" | grep -q "^STATUS: PASS t/fixture#42 " && sed -n 3p "$T/done/nonejob.md" | grep -qx "Nothing cut."'

echo
echo "land-after: $pass passed, $failn failed"
[ "$pass" -gt 0 ] || { echo "FAIL: zero checks ran"; exit 1; }
[ "$failn" -eq 0 ]
