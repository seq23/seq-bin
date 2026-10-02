#!/bin/bash
# land, driven end to end against a fake gh and a real git origin — the two defects of 26 Sep 2026.
#
# 1. STEP 3 MUTATED HER CHECKOUT. land ran `git checkout main && git pull` in the checkout it was
#    called from. local-guides-citation-velocity #159: regenerated artifacts/validation/*.json in
#    her tree made the pull abort, and land said "STOPPED: could not sync main" AFTER merging — a
#    landed PR reported as failure, main never watched. Pinned here: a dirty tree, a tree on another
#    branch, and a clean main each land rc 0 with her files and branch exactly as they were; a
#    scripted deploy runs from a throwaway worktree of origin/main, never from her tree; ~/bin (the
#    launchd working copy) is fast-forwarded only around her edits, or stops by name.
# 2. COULD-NOT-CHECK READ AS GREEN / AS RED. how-we-know #130: a 401 on the head lookup printed
#    "green, head , MERGEABLE/CLEAN" and merged. horse-legal-guide-velocity #35: one "TLS handshake
#    timeout" refused a green PR as "not green". Pinned here: an empty head never merges; a
#    transient error is retried and lands; a persistent one exits 75 saying "could not verify
#    (network)", never "not green"; a real failing check is still exit 1 "not green".
# 3. --PROMOTE RACED THE REPO'S OWN PROMOTE.YML (sheila-creator-dashboard, 26 Sep 2026): both would
#    build + migrate + deploy the same sha. Pinned here: an in-flight promote run is waited for
#    (bounded, cancelled + NAMED STOP past the ceiling) and production is read after it; a repo
#    without promote.yml is untouched; --run-e2e waits for the promote run its green e2e fires.
#
# LAND_UNDER_TEST points it at another copy of land — that is how the negative proof is run
# (the pre-fix land fails the cases above).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="${LAND_UNDER_TEST:-$HERE/../land}"
[ -f "$LAND" ] || { echo "FAIL: no land at $LAND"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAKE="$W/fake"; BIN="$W/bin"; mkdir -p "$FAKE" "$BIN"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
HEADSHA="1111111111111111111111111111111111111111"
MERGESHA="2222222222222222222222222222222222222222"

# --- fakes -------------------------------------------------------------------
printf '#!/bin/bash\nexit 0\n' > "$BIN/sleep"
cat > "$BIN/npm" <<'SH'
#!/bin/bash
{ echo "pwd=$PWD"; echo "head=$(git rev-parse HEAD)"; [ -L node_modules ] && echo "node_modules=linked"; } > "$FAKE_DIR/npm-ran"
SH
# gh: behaviour per call from files in $FAKE_DIR. A mode file holding "tls" fails every time,
# "tls-once" fails the first call only, "401" answers with the auth error, anything else is the answer.
cat > "$BIN/gh" <<'SH'
#!/bin/bash
a="$*"; echo "$a" >> "$FAKE_DIR/calls"
answer() { # mode-file default
  local m; m="$(cat "$FAKE_DIR/$1" 2>/dev/null || echo "$2")"
  case "$m" in
    tls) echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' >&2; exit 1 ;;
    tls-once) if [ -f "$FAKE_DIR/$1.failed" ]; then echo "$2"; exit 0; fi
              : > "$FAKE_DIR/$1.failed"; echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' >&2; exit 1 ;;
    401) echo 'HTTP 401: Requires authentication (https://api.github.com/graphql)' >&2; echo 'Try authenticating with:  gh auth login' >&2; exit 1 ;;
    *) echo "$m"; exit 0 ;;
  esac
}
merged() { [ -f "$FAKE_DIR/merged" ]; }
case "$a" in
  "pr view "*"state,mergeCommit"*) merged && echo "MERGED/$MERGESHA" || echo "OPEN/"; exit 0 ;;
  "pr checks "*) answer checks "[{\"name\":\"test\",\"bucket\":\"pass\",\"link\":\"https://github.com/o/r/actions/runs/555/job/1\"},{\"name\":\"Cloudflare Pages\",\"bucket\":\"pass\",\"link\":\"https://dash.cloudflare.com/x/fe13d725-4827-bc619\"}]" ;;
  "pr view "*headRefOid*) answer head "$HEADSHA" ;;
  "run view 555 "*workflowName*) cat "$FAKE_DIR/pr-workflow" 2>/dev/null || echo "Fast Check"; exit 0 ;;
  "run view 555 "*) echo "$HEADSHA"; exit 0 ;;
  "pr view "*mergeStateStatus*) echo "MERGEABLE/CLEAN"; exit 0 ;;
  "pr merge "*) : > "$FAKE_DIR/merged"; exit 0 ;;
  "pr view "*"--json state "*) merged && echo MERGED || echo OPEN; exit 0 ;;
  "pr view "*mergeCommit*) echo "$MERGESHA"; exit 0 ;;
  # pr-size = "ADD DEL FILES" + paths, one per line (cases 15-17); absent = the read fails (unhandled).
  "pr view "*additions*) [ -f "$FAKE_DIR/pr-size" ] || { echo "HTTP 500" >&2; exit 1; }; cat "$FAKE_DIR/pr-size"; exit 0 ;;
  # --- promote fakes (cases 11-14). promote-inflight = a promote.yml run 777 is in flight on
  # origin/main; each conclusion read counts down promote-ticks, and when it reaches 0 the run is
  # done and production's deployment record says origin/main. promote-hang = it never finishes.
  "run list --workflow promote.yml "*"--status completed"*) cat "$FAKE_DIR/promote-last" 2>/dev/null || echo 100; exit 0 ;;  # last_duration
  "run list --workflow promote.yml "*)
    if [ -f "$FAKE_DIR/promote-inflight" ] && [ ! -f "$FAKE_DIR/promote-done" ]; then printf '777\t%s\tin_progress\n' "$ORIGIN_MAIN"; fi; exit 0 ;;
  "run view 777 "*conclusion*)
    [ -f "$FAKE_DIR/promote-hang" ] && exit 0
    t="$(cat "$FAKE_DIR/promote-ticks" 2>/dev/null || echo 0)"
    if [ "$t" -le 0 ]; then : > "$FAKE_DIR/promote-done"; echo success; else echo $((t - 1)) > "$FAKE_DIR/promote-ticks"; fi; exit 0 ;;
  "run cancel 777"*) : > "$FAKE_DIR/promote-cancelled"; exit 0 ;;
  # e2e-pending = no green e2e yet; run 800 is in flight on origin/main and goes green when read.
  "run list --workflow e2e "*"--status success"*) [ -f "$FAKE_DIR/e2e-pending" ] || echo "$ORIGIN_MAIN"; exit 0 ;;
  "run list --workflow e2e "*"databaseId,headSha,status"*) [ -f "$FAKE_DIR/e2e-pending" ] && echo 800; exit 0 ;;
  "run list --workflow e2e "*"--status completed"*) echo 100; exit 0 ;;
  "run list --workflow e2e "*) exit 0 ;;
  "run view 800 "*conclusion*) rm -f "$FAKE_DIR/e2e-pending"
    if [ -f "$FAKE_DIR/e2e-red" ]; then echo failure; else : > "$FAKE_DIR/promote-inflight"; echo success; fi; exit 0 ;;  # green e2e fires promote.yml
  "api repos/{owner}/{repo}/deployments?environment=production"*)
    [ -f "$FAKE_DIR/promote-done" ] && echo "$ORIGIN_MAIN"; exit 0 ;;
  "api -X POST repos/{owner}/{repo}/deployments"*) echo 4242; exit 0 ;;                    # record_production
  "run list "*) echo 900; exit 0 ;;
  "run watch "*) exit 0 ;;
  "run view 900 "*conclusion*) echo success; exit 0 ;;
  "run view 900 "*status*) echo completed; exit 0 ;;
  "api "*) exit 0 ;;   # no Cloudflare check-runs posted
  *) echo "fake gh: unhandled: $a" >&2; exit 1 ;;
esac
SH
printf '#!/bin/bash\necho "{\\"ok\\":true}"\n' > "$BIN/curl"   # the smoke check never leaves the machine
chmod +x "$BIN"/*
export FAKE_DIR="$FAKE" HEADSHA MERGESHA

# fixture NAME [promote]: a bare origin whose main has moved on (the merge) past a clone at $W/NAME,
# and the merge commit rewrites artifacts/a.json — the file the owner has dirty in case 1. With
# "promote", origin/main carries .github/workflows/promote.yml (the repo promotes itself).
fixture() {
  local name="$1"
  rm -rf "$W/origin.git" "${W:?}/${name:?}" "$W/pusher" "$FAKE"; mkdir -p "$FAKE"
  git init -q --bare -b main "$W/origin.git"
  git clone -q "$W/origin.git" "$W/pusher" 2>/dev/null
  mkdir -p "$W/pusher/artifacts"; echo '{"v":1}' > "$W/pusher/artifacts/a.json"; echo one > "$W/pusher/other.txt"
  echo '{"lockfileVersion":3}' > "$W/pusher/package-lock.json"   # identical lockfile: deploy_at shares her node_modules
  if [ "${2:-}" = promote ]; then mkdir -p "$W/pusher/.github/workflows"; echo 'name: promote' > "$W/pusher/.github/workflows/promote.yml"; fi
  git -C "$W/pusher" add -A; git -C "$W/pusher" commit -qm base; git -C "$W/pusher" push -q origin HEAD:main
  git clone -q "$W/origin.git" "$W/$name"
  echo '{"v":2}' > "$W/pusher/artifacts/a.json"; git -C "$W/pusher" commit -qam "the merged PR"; git -C "$W/pusher" push -q origin HEAD:main
  ORIGIN_MAIN="$(git -C "$W/pusher" rev-parse HEAD)"; export ORIGIN_MAIN
}
run_land() { # name -> sets OUT, RC
  OUT="$(cd "$W/$1" && PATH="$BIN:$PATH" LAND_RETRY_SECS=0 PAGES_APPEAR_SECS=0 bash "$LAND" 7 2>&1)"; RC=$?
}
run_promote() { # name [flags...] -> sets OUT, RC   (LAND_WAIT_FLOOR_SECS from the caller, default 360)
  local name="$1"; shift
  OUT="$(cd "$W/$name" && PATH="$BIN:$PATH" LAND_RETRY_SECS=0 LAND_PROMOTE_APPEAR_SECS=5 bash "$LAND" --promote "$@" 2>&1)"; RC=$?
}
fails=0; passes=0
check() { # label, command...
  local label="$1"; shift
  if "$@"; then echo "  ok   $label"; passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$1" <<<"$OUT"; }
merge_called() { grep -q '^pr merge' "$FAKE/calls"; }

echo "=== 1. dirty tracked files the merge also changes: landed, her tree untouched (lgcv #159) ==="
fixture approvalprep
echo '{"v":"hers"}' > "$W/approvalprep/artifacts/a.json"
BEFORE="$(git -C "$W/approvalprep" rev-parse HEAD)"
run_land approvalprep
check "rc 0 (was: STOPPED: could not sync main, rc 1)" [ "$RC" -eq 0 ]
check "main watched to success" has "completed success"
check "her dirty file is byte-for-byte hers" [ "$(cat "$W/approvalprep/artifacts/a.json")" = '{"v":"hers"}' ]
check "her local main was not moved" [ "$(git -C "$W/approvalprep" rev-parse HEAD)" = "$BEFORE" ]
check "it says it left the tree alone" has "left exactly as they are"
check "origin/main was fetched" [ "$(git -C "$W/approvalprep" rev-parse origin/main)" = "$ORIGIN_MAIN" ]
# 2 Oct 2026 (lgcv #163/#166): the run watched on main is the workflow that judged the PR, not `[0]`.
check "the PR's workflow was read from its own check run" grep -q '^run view 555 .*workflowName' "$FAKE/calls"
check "…and handed to the pick of main's run" grep -q '^run list --branch main .*Fast Check' "$FAKE/calls"
check "…without reading the checks a second time" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 1 ]
check "it says which run it watched and what judged the PR" has 'the PR was judged by "Fast Check"'

echo "=== 1b. a workflow name carrying a quote is never spliced into the filter: lands, on the newest run ==="
fixture approvalprep
echo 'Bad "Name"' > "$FAKE/pr-workflow"
run_land approvalprep
check "rc 0" [ "$RC" -eq 0 ]
check "main watched to success" has "completed success"
check "the quoted name never reached the run list" eval '! grep -q "^run list --branch main .*Bad" "$FAKE/calls"'

echo "=== 1c. an already-merged PR skipped step 1, so its checks are read for the workflow ==="
fixture approvalprep
: > "$FAKE/merged"
run_land approvalprep
check "rc 0" [ "$RC" -eq 0 ]
check "nothing was merged again" eval '! merge_called'
check "the merged PR's checks were read once, for the workflow" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 1 ]
check "…and its workflow was handed to the pick of the merge commit's run" grep -q '^run list --branch main .*Fast Check' "$FAKE/calls"

echo "=== 2. checkout on a feature branch: not switched to main ==="
fixture approvalprep
git -C "$W/approvalprep" checkout -qb her-work
run_land approvalprep
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "still on her-work" [ "$(git -C "$W/approvalprep" symbolic-ref --short HEAD)" = her-work ]

echo "=== 3. clean main: fast-forwarded to origin/main ==="
fixture approvalprep
run_land approvalprep
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "local main == origin/main" [ "$(git -C "$W/approvalprep" rev-parse HEAD)" = "$ORIGIN_MAIN" ]

echo "=== 4. a scripted deploy runs from a worktree of origin/main, not her dirty tree ==="
fixture creator-network
echo '{"v":"hers"}' > "$W/creator-network/artifacts/a.json"; mkdir "$W/creator-network/node_modules"
run_land creator-network
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "the deploy ran" [ -f "$FAKE/npm-ran" ]
check "…not in her checkout" [ -f "$FAKE/npm-ran" ] && ! grep -qx "pwd=$W/creator-network" "$FAKE/npm-ran"
check "…at origin/main" grep -qx "head=$ORIGIN_MAIN" "$FAKE/npm-ran"
check "…with her node_modules linked in" grep -qx "node_modules=linked" "$FAKE/npm-ran"
check "the deploy worktree was removed afterwards" [ "$(git -C "$W/creator-network" worktree list | grep -c .)" -eq 1 ]
check "her dirty file is untouched" [ "$(cat "$W/creator-network/artifacts/a.json")" = '{"v":"hers"}' ]

echo "=== 5. ~/bin (launchd runs its working copy): fast-forwarded around her unrelated edits ==="
fixture seq-bin
echo "hers" > "$W/seq-bin/other.txt"
run_land seq-bin
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "working copy is at origin/main (the deploy)" [ "$(git -C "$W/seq-bin" rev-parse HEAD)" = "$ORIGIN_MAIN" ]
check "her edit to other.txt is kept" [ "$(cat "$W/seq-bin/other.txt")" = hers ]
echo "=== 6. ~/bin where the merge touches a file she has edited: named stop, nothing touched ==="
fixture seq-bin
echo '{"v":"hers"}' > "$W/seq-bin/artifacts/a.json"; BEFORE="$(git -C "$W/seq-bin" rev-parse HEAD)"
run_land seq-bin
check "rc 1 (merged, not deployed — said, not hidden)" [ "$RC" -eq 1 ]
check "names the file" has "artifacts/a.json"
check "her file untouched, HEAD unmoved" [ "$(cat "$W/seq-bin/artifacts/a.json")" = '{"v":"hers"}' ] && [ "$(git -C "$W/seq-bin" rev-parse HEAD)" = "$BEFORE" ]

echo "=== 7. head lookup answers 401 (how-we-know #130): never merges on an empty head ==="
fixture approvalprep; echo 401 > "$FAKE/head"
# Only a Cloudflare check, so no Actions run sha backs the head up — nothing but the head read itself
# stands between a 401 and the merge (how-we-know's run-sha read failed on the same 401).
echo '[{"name":"Cloudflare Pages","bucket":"pass","link":"https://dash.cloudflare.com/x/fe13d725-4827-bc619"}]' > "$FAKE/checks"
run_land approvalprep
check "gh pr merge was NOT called" eval '! merge_called'
check "exit 75 (could not verify), not 0" [ "$RC" -eq 75 ]
check "says could not verify (auth)" has "could not verify (auth)"
check "never prints an empty head" eval '! has "head ,"'

echo "=== 8. one TLS handshake timeout (horse #35): retried, then lands ==="
fixture approvalprep; echo tls-once > "$FAKE/checks"
run_land approvalprep
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "the checks read was attempted twice" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 2 ]
check "merged" merge_called

echo "=== 9. a TLS timeout that persists: exit 75 'could not verify (network)', not 'not green' ==="
fixture approvalprep; echo tls > "$FAKE/checks"
run_land approvalprep
check "exit 75" [ "$RC" -eq 75 ]
check "says could not verify (network)" has "could not verify (network)"
check "does NOT say not green" eval '! has "not green"'
check "3 attempts, bounded" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 3 ]
check "not merged" eval '! merge_called'

echo "=== 10. a real failing check is still a refusal (exit 1, not green) ==="
fixture approvalprep
echo '[{"name":"test","bucket":"fail","link":"https://github.com/o/r/actions/runs/555/job/1"}]' > "$FAKE/checks"
run_land approvalprep
check "exit 1" [ "$RC" -eq 1 ]
check "says not green — test: fail" has "not green — test: fail"
check "a single read, no retry of a real answer" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 1 ]
check "not merged" eval '! merge_called'

# --- land --promote against a repo that promotes itself (promote.yml) — 26 Sep 2026 ----------------
# sheila-creator-dashboard's promote.yml deploys production on a green e2e. A person's `land --promote`
# in the same minutes must WAIT for that run and read production after it, never build + migrate +
# deploy the same sha on top of it.
echo "=== 11. a promote.yml run is in flight: land waits for it, then finds nothing to promote ==="
fixture sheila-creator-dashboard promote
: > "$FAKE/promote-inflight"; echo 2 > "$FAKE/promote-ticks"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_promote sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "says it is waiting on run 777" has "promote run 777 in flight for ${ORIGIN_MAIN:0:7}"
check "waited to the run's conclusion (3 reads: two pending, one success)" [ "$(grep -c '^run view 777' "$FAKE/calls")" -eq 3 ]
check "read production AFTER the run (deployment record answered)" has "promote run 777 finished: success"
check "NOTHING TO PROMOTE — the run shipped that sha" has "NOTHING TO PROMOTE"
check "no deploy ran on top of it" [ ! -f "$FAKE/npm-ran" ]
check "the run was not cancelled" [ ! -f "$FAKE/promote-cancelled" ]

echo "=== 12. no promote.yml on origin/main: nothing to wait for, promotes as before ==="
fixture sheila-creator-dashboard
: > "$FAKE/promote-inflight"; mkdir "$W/sheila-creator-dashboard/node_modules"   # a stray in-flight row is irrelevant: no promote.yml
run_promote sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "silent about promote runs" eval '! has "promote run"'
check "never listed promote.yml runs" eval '! grep -q "^run list --workflow promote.yml" "$FAKE/calls"'
check "deployed from a worktree at origin/main" grep -qx "head=$ORIGIN_MAIN" "$FAKE/npm-ran"
check "PROMOTED" has "PROMOTED"

echo "=== 13. the promote run never finishes: cancelled at the ceiling, NAMED STOP, nothing deployed ==="
fixture sheila-creator-dashboard promote
: > "$FAKE/promote-inflight"; : > "$FAKE/promote-hang"; echo 0 > "$FAKE/promote-last"; mkdir "$W/sheila-creator-dashboard/node_modules"
LAND_WAIT_FLOOR_SECS=0 run_promote sheila-creator-dashboard
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP names the run" has "NAMED STOP [PROMOTE_RUN_PAST_CEILING] promote.yml run 777"
check "the hung run was cancelled" [ -f "$FAKE/promote-cancelled" ]
check "nothing deployed on top of it" [ ! -f "$FAKE/npm-ran" ]

echo "=== 14. --run-e2e: the green e2e fires promote.yml; land waits for THAT run, does not double-deploy ==="
fixture sheila-creator-dashboard promote
: > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_promote sheila-creator-dashboard --run-e2e
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "waited for the in-flight e2e run 800, did not dispatch" [ "$(grep -c '^run view 800' "$FAKE/calls")" -ge 1 ] && ! grep -q '^workflow run' "$FAKE/calls"
check "then waited for the promote run it triggered" has "promote run 777 in flight"
check "NOTHING TO PROMOTE — promote.yml shipped the head" has "shipped main's head ${ORIGIN_MAIN:0:7}"
check "no deploy from this side" [ ! -f "$FAKE/npm-ran" ]

# --- land <pr> after a LARGE change on an e2e route — 2 Oct 2026 --------------------------------------
# The e2e workflows are dispatch-only now, so after a merge nothing runs them unless land does. A
# large PR (measured by the `large` block, tests/test-land-large.sh) makes land run the suite on
# main's head and ship production only on green; a small one still prints WAITING.
# Here the merge commit IS main's head and the merge sha the fake answers is ORIGIN_MAIN.
echo "=== 15. a large PR (300 lines): land runs the suite, waits, and the repo's promote.yml ships it ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
printf '250 50 3\nworker/domain/sync.ts\napp/pages/Calendar.tsx\nshared/types.ts\n' > "$FAKE/pr-size"
: > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says why: 300 lines ≥ 200" has "LARGE CHANGE — 300 lines changed (+250/-50) ≥ 200"
check "staging deployed first, from the merge sha" grep -qx "head=$ORIGIN_MAIN" "$FAKE/npm-ran"
check "waited for the in-flight e2e run 800 (adopted, not doubled)" [ "$(grep -c '^run view 800' "$FAKE/calls")" -ge 1 ] && ! grep -q '^workflow run' "$FAKE/calls"
check "then waited for the promote run the green fired" has "promote run 777 in flight"
check "LANDED — promote.yml shipped it" has "LANDED" && has "promote.yml shipped it to production"
check "never WAITING" eval '! has "WAITING"'

echo "=== 16. a small PR (12 lines, worker only): WAITING as before, no suite run ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
printf '10 2 1\nworker/domain/sync.ts\n' > "$FAKE/pr-size"
: > "$FAKE/e2e-pending"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "WAITING, with the small-change reason" has "WAITING" && has "small change (under 200 lines, 8 files"
check "the suite was neither adopted nor dispatched" eval '! grep -q "^run view 800" "$FAKE/calls" && ! grep -q "^workflow run" "$FAKE/calls"'
check "production never deployed from this side (staging only)" [ "$(grep -c 'head=' "$FAKE/npm-ran")" -eq 1 ]
check "…but --run-e2e forces it for any size" eval 'rm -f "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; OUT="$(cd "$W/sheila-creator-dashboard" && PATH="$BIN:$PATH" LAND_RETRY_SECS=0 LAND_PROMOTE_APPEAR_SECS=5 bash "$LAND" 7 --run-e2e 2>&1)"; has "LARGE CHANGE — --run-e2e given" && has "LANDED"'

echo "=== 17. a large PR whose suite goes RED: NAMED STOP, staging deployed, production untouched ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
printf '3 0 1\nmigrations/0042_posts.sql\n' > "$FAKE/pr-size"
: > "$FAKE/e2e-pending"; : > "$FAKE/e2e-red"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 1" [ "$RC" -eq 1 ]
check "a migration is large at any size" has "LARGE CHANGE — touches the schema or the browser-test contract (migrations/0042_posts.sql)"
check "NAMED STOP names the run and the reason" has "NAMED STOP [E2E_RED_AFTER_LARGE_CHANGE] e2e run 800"
check "staging ran once, production never" [ "$(grep -c 'head=' "$FAKE/npm-ran")" -eq 1 ] && ! has "production <-"
check "the size read that cannot be answered is large, fail closed" eval 'rm -f "$FAKE/pr-size" "$FAKE/e2e-red" "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; run_land sheila-creator-dashboard; has "LARGE CHANGE — PR size unreadable" && has "LANDED"'
MERGESHA="2222222222222222222222222222222222222222"; export MERGESHA

echo "=== negative proof: a land that does not wait for the promote run deploys on top of it ==="
BROKEN="$W/land-no-wait"; sed '/^  promote_wait_inflight$/d' "$LAND" > "$BROKEN"
check "the broken copy differs (the wait call was removed)" eval '! cmp -s "$LAND" "$BROKEN"'
fixture sheila-creator-dashboard promote
: > "$FAKE/promote-inflight"; echo 2 > "$FAKE/promote-ticks"; mkdir "$W/sheila-creator-dashboard/node_modules"
LAND="$BROKEN" run_promote sheila-creator-dashboard
check "the broken land raced the run and deployed (this harness catches it)" [ -f "$FAKE/npm-ran" ]
check "…without ever watching run 777" eval '! grep -q "^run view 777" "$FAKE/calls"'

# Rule 0: this must have examined something.
[ "$passes" -ge 72 ] || { echo "FAIL: only $passes checks ran — the harness examined too little"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-flow: $fails failure(s), $passes passed"; exit 1; }
echo "test-land-flow: $passes checks passed — land leaves her tree alone, never reads could-not-check as an answer, never races a repo's own promote run, and runs the suite itself after a large change"
