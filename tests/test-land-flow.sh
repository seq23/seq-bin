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
# 4. A SMALL CHANGE WAITED FOR A SUITE NOTHING WOULD RUN (2 Oct 2026). With the e2e workflows on
#    demand only, `land <pr>` on a small change printed WAITING and six repos sat on staging. The
#    owner's ruling: a small change ships on the fast check alone; e2e gates production only after
#    a large change or when asked. Pinned here, end to end: a small PR deploys staging AND
#    production and records why; a suite KNOWN RED on main (or red on the exact sha) is a NAMED
#    STOP with production untouched, and `--run-e2e` is the way out; an unreadable history is exit
#    75, never "not red"; a large commit production has not seen makes land run the suite even
#    behind a small PR; production is never rolled back or deployed twice; a self-deploying repo
#    with PROMOTE_VIA ships through its own workflow, dispatched with the sha and the reason; and
#    boss-os waits for its deploy.yml after a green suite instead of racing it. Negative proofs by
#    mutation at the foot of the file.
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
echo "$* head=$(git rev-parse HEAD)" >> "$FAKE_DIR/npm-log"   # every invocation, in order (npm-ran holds only the last)
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
  "run list --workflow promote.yml "*"--status completed"*|"run list --workflow deploy.yml "*"--status completed"*) cat "$FAKE_DIR/promote-last" 2>/dev/null || echo 100; exit 0 ;;  # last_duration
  # --- land's own dispatch of a PROMOTE_VIA workflow (cases 19+): `workflow run` leaves its
  # arguments in `dispatched`; run 778 is that run; dispatch-conc is its conclusion (default
  # success), and on success the workflow has recorded production = origin/main (prod-state)
  # unless dispatch-no-record says it did not.
  "workflow run promote.yml "*|"workflow run deploy.yml "*) echo "$a" > "$FAKE_DIR/dispatched"; exit 0 ;;
  "run list --workflow promote.yml --event workflow_dispatch"*|"run list --workflow deploy.yml --event workflow_dispatch"*)
    [ -f "$FAKE_DIR/dispatched" ] && echo 778; exit 0 ;;
  "run view 778 "*conclusion*) c="$(cat "$FAKE_DIR/dispatch-conc" 2>/dev/null || echo success)"
    [ "$c" = success ] && [ ! -f "$FAKE_DIR/dispatch-no-record" ] && echo "$ORIGIN_MAIN" > "$FAKE_DIR/prod-state"
    echo "$c"; exit 0 ;;
  "run list --workflow promote.yml "*|"run list --workflow deploy.yml "*)
    if [ -f "$FAKE_DIR/promote-inflight" ] && [ ! -f "$FAKE_DIR/promote-done" ]; then printf '777\t%s\tin_progress\n' "$ORIGIN_MAIN"; fi; exit 0 ;;
  "run view 777 "*conclusion*)
    [ -f "$FAKE_DIR/promote-hang" ] && exit 0
    t="$(cat "$FAKE_DIR/promote-ticks" 2>/dev/null || echo 0)"
    if [ "$t" -le 0 ]; then : > "$FAKE_DIR/promote-done"; echo success; else echo $((t - 1)) > "$FAKE_DIR/promote-ticks"; fi; exit 0 ;;
  "run cancel 777"*) : > "$FAKE_DIR/promote-cancelled"; exit 0 ;;
  # e2e-on-sha = the conclusion of the completed e2e run on the merge sha (absent: none completed).
  "run list --workflow e2e "*"--json headSha,status,conclusion"*) cat "$FAKE_DIR/e2e-on-sha" 2>/dev/null; exit 0 ;;
  # e2e-last = the newest run on main that reached a verdict, "<conclusion><TAB><run><TAB><sha>"
  # (absent: "none", no run ever did; "tls": the history cannot be read).
  "run list --workflow e2e "*"conclusion,headSha,databaseId,status"*) answer e2e-last none ;;
  # e2e-pending = no green e2e yet; run 800 is in flight on origin/main and goes green when read.
  "run list --workflow e2e "*"--status success"*) [ -f "$FAKE_DIR/e2e-pending" ] || echo "$ORIGIN_MAIN"; exit 0 ;;
  "run list --workflow e2e "*"databaseId,headSha,status"*) [ -f "$FAKE_DIR/e2e-pending" ] && echo 800; exit 0 ;;
  "run list --workflow e2e "*"--status completed"*) echo 100; exit 0 ;;
  "run list --workflow e2e "*) exit 0 ;;
  "run view 800 "*conclusion*) rm -f "$FAKE_DIR/e2e-pending"
    if [ -f "$FAKE_DIR/e2e-red" ]; then echo failure; else : > "$FAKE_DIR/promote-inflight"; echo success; fi; exit 0 ;;  # green e2e fires promote.yml
  # What production runs. promote-done (the repo's own promote run finished) = origin/main.
  # Otherwise prod-state: a sha, "unrecorded" (the default), or "tls" (the API does not answer).
  # production_state asks with `// "unrecorded"` and tells the three apart; production_sha (the
  # older read) answers a sha or nothing.
  "api repos/{owner}/{repo}/deployments?environment=production"*)
    if [ -f "$FAKE_DIR/promote-done" ]; then echo "$ORIGIN_MAIN"; exit 0; fi
    case "$a" in
      *unrecorded*) answer prod-state unrecorded ;;
      *) m="$(cat "$FAKE_DIR/prod-state" 2>/dev/null || true)"; case "$m" in ""|unrecorded|tls) : ;; *) echo "$m" ;; esac; exit 0 ;;
    esac ;;
  "api -X POST repos/{owner}/{repo}/deployments/"*) cat >/dev/null; exit 0 ;;              # record_production: the status
  "api -X POST repos/{owner}/{repo}/deployments "*) cat > "$FAKE_DIR/deploy-record"; echo 4242; exit 0 ;;   # …and the deployment (its JSON is kept)
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
# "promote", origin/main carries .github/workflows/promote.yml (the repo promotes itself); with
# "deploy", .github/workflows/deploy.yml (boss-os and justbeingmercedes ship through that file).
fixture() {
  local name="$1"
  rm -rf "$W/origin.git" "${W:?}/${name:?}" "$W/pusher" "$FAKE"; mkdir -p "$FAKE"
  git init -q --bare -b main "$W/origin.git"
  git clone -q "$W/origin.git" "$W/pusher" 2>/dev/null
  mkdir -p "$W/pusher/artifacts"; echo '{"v":1}' > "$W/pusher/artifacts/a.json"; echo one > "$W/pusher/other.txt"
  echo '{"lockfileVersion":3}' > "$W/pusher/package-lock.json"   # identical lockfile: deploy_at shares her node_modules
  if [ -n "${2:-}" ]; then mkdir -p "$W/pusher/.github/workflows"; echo "name: $2" > "$W/pusher/.github/workflows/$2.yml"; fi
  git -C "$W/pusher" add -A; git -C "$W/pusher" commit -qm base; git -C "$W/pusher" push -q origin HEAD:main
  git clone -q "$W/origin.git" "$W/$name"
  echo '{"v":2}' > "$W/pusher/artifacts/a.json"; git -C "$W/pusher" commit -qam "the merged PR"; git -C "$W/pusher" push -q origin HEAD:main
  ORIGIN_MAIN="$(git -C "$W/pusher" rev-parse HEAD)"; export ORIGIN_MAIN
}
run_land() { # name [flags...] -> sets OUT, RC
  local name="$1"; shift
  OUT="$(cd "$W/$name" && PATH="$BIN:$PATH" LAND_RETRY_SECS=0 PAGES_APPEAR_SECS=0 LAND_PROMOTE_APPEAR_SECS=5 bash "$LAND" 7 "$@" 2>&1)"; RC=$?
  [ -z "${LAND_TEST_SHOW:-}" ] || printf '%s\n' "$OUT" | sed 's/^/    | /'   # LAND_TEST_SHOW=1: print what land said
}
npm_log() { cat "$FAKE/npm-log" 2>/dev/null || true; }
suite_untouched() { ! grep -q "^run view 800" "$FAKE/calls" && ! grep -q "^workflow run e2e" "$FAKE/calls"; }
dispatched() { [ -f "$FAKE/dispatched" ]; }
small_pr() { printf '10 2 1\nworker/domain/sync.ts\n' > "$FAKE/pr-size"; }
large_pr() { printf '250 50 3\nworker/domain/sync.ts\napp/pages/Calendar.tsx\nshared/types.ts\n' > "$FAKE/pr-size"; }
SMALL_REASON="small change: 12 lines, 1 files; shipped on the fast check, e2e on demand"
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
check "a self-deploying repo with no PROMOTE_VIA is done at its build: nothing dispatched, no size read" eval '! grep -q "^workflow run" "$FAKE/calls" && ! grep -q additions "$FAKE/calls"'

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
# main's head and ship production only on green; a small one ships on the fast check (cases 16+).
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

# --- a SMALL change ships on the fast check (owner, 2 Oct 2026) -----------------------------------
# Until this ruling case 16 pinned "WAITING, no production deploy". The new truth, pinned harder:
# production IS deployed, from the merge sha, with the reason printed and recorded — and only when
# the suite is not known red (16c-16e), which the old rule never had to ask.
echo "=== 16. a small PR (12 lines, worker only), no e2e verdict on main yet: ships on the fast check ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says why it shipped: small, with the numbers" has "SMALL CHANGE — $SMALL_REASON"
check "…and what the suite's last verdict was" has "(last e2e verdict on main: none)"
check "never WAITING" eval '! has "WAITING"'
check "the suite was neither adopted nor dispatched" suite_untouched
check "staging, then production, both from the merge sha — and nothing else" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN
run deploy:production head=$ORIGIN_MAIN" ]
check "the production deployment is recorded at that sha" grep -q "\"ref\":\"$ORIGIN_MAIN\"" "$FAKE/deploy-record"
check "…carrying the reason" grep -qF "land #7, $SMALL_REASON" "$FAKE/deploy-record"
check "LANDED — staging and production" has "LANDED — #7 is merged, main is green, staging and production run ${ORIGIN_MAIN:0:7}"
check "the plan line says production, not waiting" has "${ORIGIN_MAIN:0:7}: staging production (e2e on this sha: no completed run)"
check "…but --run-e2e forces the suite for any size" eval 'rm -f "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; run_land sheila-creator-dashboard --run-e2e; has "LARGE CHANGE — --run-e2e given" && has "LANDED" && grep -q "^run view 800" "$FAKE/calls"'

echo "=== 16b. a small PR, the last e2e verdict on main is green: ships ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'success\t790\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says the last verdict was success" has "(last e2e verdict on main: success)"
check "production deployed" eval 'npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'
check "the suite was not run" suite_untouched

echo "=== 16c. a small PR, but e2e is KNOWN RED on main (no green run after it): NAMED STOP, production untouched ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'failure\t791\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP names the red run and its sha" has "NAMED STOP [E2E_KNOWN_RED] e2e is known red on main: run 791 on ${ORIGIN_MAIN:0:7} ended failure and no green run is newer"
check "…and the way out" has "Fix main, then: land 7 --run-e2e"
check "the plan line says blocked" has "staging blocked"
check "staging ran, production never" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN" ] && ! has "production <-"
check "no production deployment was recorded" [ ! -f "$FAKE/deploy-record" ]
check "the suite was not run behind her back" suite_untouched
check "never 'SMALL CHANGE — … shipped'" eval '! has "SMALL CHANGE —"'
check "the way out works: --run-e2e runs the suite and ships on green" eval 'rm -f "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; run_land sheila-creator-dashboard --run-e2e; [ "$RC" -eq 0 ] && has "LARGE CHANGE — --run-e2e given" && has "LANDED"'

echo "=== 16d. a small PR, the e2e history cannot be read: exit 75 'could not verify', never 'not red' ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo tls > "$FAKE/e2e-last"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "exit 75" [ "$RC" -eq 75 ]
check "says could not verify (network), and what" has "could not verify (network)" && has "the e2e history on main could not be read"
check "says the PR is merged and production untouched" has "#7 IS MERGED, staging runs ${ORIGIN_MAIN:0:7}; production untouched"
check "3 attempts at the read, bounded" [ "$(grep -c 'conclusion,headSha,databaseId,status' "$FAKE/calls")" -eq 3 ]
check "production never deployed" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN" ] && [ ! -f "$FAKE/deploy-record" ]
check "does NOT call it a known-red stop" eval '! has "E2E_KNOWN_RED"'

echo "=== 16e. a small PR whose own sha has a RED e2e run, though main's last verdict is green: blocked ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo failure > "$FAKE/e2e-on-sha"; printf 'success\t795\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP names this sha's red run" has "NAMED STOP [E2E_KNOWN_RED] e2e is known red on main: on ${ORIGIN_MAIN:0:7} ended failure"
check "production never deployed" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN" ]

echo "=== 16f. e2e already green on the exact sha: production at once, the size is never asked ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
echo success > "$FAKE/e2e-on-sha"; mkdir "$W/sheila-creator-dashboard/node_modules"   # no pr-size: a size read would fail
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "production deployed" eval 'npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'
check "no size read, no verdict read" eval '! grep -q additions "$FAKE/calls" && ! grep -q "conclusion,headSha,databaseId,status" "$FAKE/calls"'
check "not called a small change" eval '! has "SMALL CHANGE"'

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

# --- every change production has not seen is judged, not only this PR -------------------------------
# history NAME: base (production) -> "the merged PR" (1 line) -> "big unproven change" (250 lines)
# -> "the second PR" (1 line, the merge under test). prod-state = base.
history() {
  fixture "$1" "${2:-promote}"
  BASE="$(git -C "$W/pusher" rev-parse HEAD~1)"; FIRST="$ORIGIN_MAIN"
  seq 1 250 > "$W/pusher/big.ts"; git -C "$W/pusher" add -A; git -C "$W/pusher" commit -qm "big unproven change"
  BIG="$(git -C "$W/pusher" rev-parse HEAD)"
  echo two >> "$W/pusher/other.txt"; git -C "$W/pusher" commit -qam "the second PR"; git -C "$W/pusher" push -q origin HEAD:main
  ORIGIN_MAIN="$(git -C "$W/pusher" rev-parse HEAD)"; MERGESHA="$ORIGIN_MAIN"; export ORIGIN_MAIN MERGESHA
  mkdir -p "$W/$1/node_modules"
}
echo "=== 18. production recorded one small commit back: the range is judged, none large, ships ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; git -C "$W/pusher" rev-parse HEAD~1 > "$FAKE/prod-state"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says it judged what production has not seen" has "judged all 1 change(s) main carries past production $(cut -c1-7 "$FAKE/prod-state"): none is large"
check "shipped as a small change" has "SMALL CHANGE — $SMALL_REASON" && npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"

echo "=== 18b. a small PR behind a LARGE commit production has never seen: land runs the suite ==="
history sheila-creator-dashboard
small_pr; echo "$BASE" > "$FAKE/prod-state"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "names the unproven commit and why it is large" has "LARGE CHANGE — main carries ${BIG:0:7} (big unproven change) past production ${BASE:0:7}, large and not yet proven: 250 lines changed (+250/-0) ≥ 200"
check "the suite ran (run 800 adopted)" grep -q '^run view 800' "$FAKE/calls"
check "never shipped as a small change" eval '! has "SMALL CHANGE"'
check "LANDED on the green suite" has "LANDED"

echo "=== 18c. what production runs cannot be read: large, fail closed — the suite runs ==="
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo tls > "$FAKE/prod-state"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/sheila-creator-dashboard/node_modules"
run_land sheila-creator-dashboard
check "says so" has "LARGE CHANGE — what production runs could not be read"
check "the suite ran" grep -q '^run view 800' "$FAKE/calls"
check "never shipped as a small change" eval '! has "SMALL CHANGE"'

echo "=== 18d. landing a merged PR that production already runs (or has passed): nothing deployed, never backwards ==="
history sheila-creator-dashboard
small_pr; : > "$FAKE/merged"; echo "$ORIGIN_MAIN" > "$FAKE/prod-state"
run_land sheila-creator-dashboard
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says production already runs it" has "production already runs ${ORIGIN_MAIN:0:7} (GitHub Deployment record). Nothing to deploy."
check "no deploy of any kind" [ -z "$(npm_log)" ]
MERGESHA="$FIRST"; export MERGESHA; rm -f "$FAKE/calls"
run_land sheila-creator-dashboard
check "an OLDER merged PR: production is ahead of it, and stays there" has "production already runs ${ORIGIN_MAIN:0:7}, which contains ${FIRST:0:7}"
check "…no deploy, no roll back" [ -z "$(npm_log)" ] && [ ! -f "$FAKE/deploy-record" ]

# --- a self-deploying repo whose own workflow moves production (PROMOTE_VIA) -------------------------
echo "=== 19. secondaries, small PR: land dispatches promote.yml with the sha and the reason, waits, reads the record ==="
fixture secondaries promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr
run_land secondaries
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "staging is confirmed first, and it does not stop there" has "staging is published by the repo's own workflow on push"
check "dispatched promote.yml on main with exactly that sha" grep -qF -- "workflow run promote.yml --ref main -f sha=$ORIGIN_MAIN" "$FAKE/dispatched"
check "…and the small-change reason" grep -qF -- "-f reason=land #7, $SMALL_REASON" "$FAKE/dispatched"
check "waited for the run it started" has "promote.yml run 778: success"
check "read production back from the record" has "recorded by promote.yml: production = ${ORIGIN_MAIN:0:7}"
check "LANDED" has "LANDED — #7 is merged, main is green, production run ${ORIGIN_MAIN:0:7}"
check "nothing was run from the laptop" [ -z "$(npm_log)" ]
check "the suite was not run" suite_untouched

echo "=== 19b. the promote run goes red: stopped, production untouched ==="
fixture secondaries promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo failure > "$FAKE/dispatch-conc"
run_land secondaries
check "rc 1" [ "$RC" -eq 1 ]
check "says the repo's workflow did not ship it" has "secondaries's own promote.yml did not ship ${ORIGIN_MAIN:0:7} — production untouched"
check "never LANDED" eval '! has "LANDED"'

echo "=== 19c. the promote run is green but production's record does not name the sha: not LANDED ==="
fixture secondaries promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; : > "$FAKE/dispatch-no-record"
run_land secondaries
check "rc 1" [ "$RC" -eq 1 ]
check "says the record does not name it" has "production's GitHub Deployment record does not name it"
check "never LANDED" eval '! has "LANDED"'

echo "=== 19d. secondaries, small PR, suite known red: blocked, promote.yml never dispatched ==="
fixture secondaries promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'failure\t791\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"
run_land secondaries
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP [E2E_KNOWN_RED]" has "NAMED STOP [E2E_KNOWN_RED]"
check "nothing dispatched" eval '! dispatched'

echo "=== 19e. secondaries, LARGE PR: the suite runs, and its green fires promote.yml — land waits, dispatches nothing ==="
fixture secondaries promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
large_pr; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"
run_land secondaries
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says why: 300 lines" has "LARGE CHANGE — 300 lines changed (+250/-50) ≥ 200"
check "waited for the promote run the green suite fired" has "promote run 777 in flight"
check "LANDED — promote.yml shipped it" has "the repo's own promote.yml shipped it to production"
check "land dispatched nothing itself" eval '! dispatched'

echo "=== 19f. justbeingmercedes ships through deploy.yml (PROMOTE_VIA=deploy.yml) ==="
fixture justbeingmercedes deploy
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr
run_land justbeingmercedes
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "dispatched deploy.yml with the sha and the reason" grep -qF -- "workflow run deploy.yml --ref main -f sha=$ORIGIN_MAIN -f reason=land #7, $SMALL_REASON" "$FAKE/dispatched"
check "LANDED" has "LANDED"

# --- boss-os: deploy.yml ships on a green e2e (PROMOTE_WF) — waited for, never raced -----------------
echo "=== 20. boss-os, LARGE PR: after the green suite land waits for deploy.yml, and does NOT deploy from the laptop ==="
fixture boss-os deploy
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
large_pr; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/boss-os/node_modules"
run_land boss-os
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "waited for the Deploy run the green suite fired" has "promote run 777 in flight"
check "LANDED — deploy.yml shipped it" has "the repo's own deploy.yml shipped it to production"
check "no second migrate-and-deploy from the laptop" [ -z "$(npm_log)" ]

echo "=== 20b. boss-os, small PR: production from the laptop on the fast check (no staging target) ==="
fixture boss-os deploy
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; mkdir "$W/boss-os/node_modules"
run_land boss-os
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "one deploy, production, at the merge sha" [ "$(npm_log)" = "run deploy:production head=$ORIGIN_MAIN" ]
check "recorded with the reason" grep -qF "land #7, $SMALL_REASON" "$FAKE/deploy-record"
check "LANDED — production (no 'staging and')" has "LANDED — #7 is merged, main is green, production run ${ORIGIN_MAIN:0:7}"
MERGESHA="2222222222222222222222222222222222222222"; export MERGESHA

# --- negative proofs for the 2 Oct 2026 rule: each guard removed in a copy of land -------------------
echo "=== negative proof: a land that ships past a known-red suite ==="
BROKEN="$W/land-past-red"; sed 's/^    success|none) printf/    success|none|failure) printf/' "$LAND" > "$BROKEN"
check "the broken copy differs" eval '! cmp -s "$LAND" "$BROKEN"'
fixture sheila-creator-dashboard promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'failure\t791\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/sheila-creator-dashboard/node_modules"
LAND="$BROKEN" run_land sheila-creator-dashboard
check "the broken land deployed production over a red suite (16c catches it)" eval 'npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'

echo "=== negative proof: a land that judges only the PR lets an unproven large commit ride out ==="
BROKEN="$W/land-pr-only"; sed '/REASON="\$(unshipped_large_reason /d' "$LAND" > "$BROKEN"
check "the broken copy differs" eval '! cmp -s "$LAND" "$BROKEN"'
history sheila-creator-dashboard
small_pr; echo "$BASE" > "$FAKE/prod-state"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"
LAND="$BROKEN" run_land sheila-creator-dashboard
check "the broken land shipped the 250-line change as 'small', suite never run (18b catches it)" eval 'has "SMALL CHANGE" && ! grep -q "^run view 800" "$FAKE/calls" && npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'

echo "=== negative proof: a boss-os route that does not name deploy.yml races it ==="
BROKEN="$W/land-boss-race"; sed 's/ ; E2E_WF="e2e" ; PROMOTE_WF="deploy.yml" ;;/ ; E2E_WF="e2e" ;;/' "$LAND" > "$BROKEN"
check "the broken copy differs" eval '! cmp -s "$LAND" "$BROKEN"'
fixture boss-os deploy
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
large_pr; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/boss-os/node_modules"
LAND="$BROKEN" run_land boss-os
check "the broken land deployed from the laptop while deploy.yml was shipping the same sha (20 catches it)" eval 'npm_log | grep -q "run deploy:production"'
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
[ "$passes" -ge 160 ] || { echo "FAIL: only $passes checks ran — the harness examined too little"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-flow: $fails failure(s), $passes passed"; exit 1; }
echo "test-land-flow: $passes checks passed — land leaves her tree alone, never reads could-not-check as an answer, never races a repo's own promote run, runs the suite itself after a large change, and ships a small one on the fast check unless the suite is known red"
