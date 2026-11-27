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
# 3. --PROMOTE RACED THE REPO'S OWN PROMOTE.YML (build-first-fixture, 26 Sep 2026): both would
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
# land writes its post-land-check lines into a list (27 Nov 2026: ~/Work/tasks/post-land-checks.md, no longer
# HANDOFF's Today): never her real list from a test (case 21 points it elsewhere)
export LAND_DUE_FILE="$W/post-land-checks.md"
# land reads live-repos.json beside itself (LAND_DIR = $W, where its fixture copy runs): o/r has launched, so its
# PRs land on green CI unless a case makes them review-class.
printf '{"live": ["o/r", "seq23/boss-os"]}\n' > "$W/live-repos.json"
cp "$HERE/../pr-body-template.md" "$W/"   # the ONE template beside land (same LAND_DIR): every "add:" line land prints comes from it
FAKE="$W/fake"; BIN="$W/bin"; mkdir -p "$FAKE" "$BIN"
# The build-first shape (staging on every land, a named e2e workflow, promote.yml on a green e2e)
# has no live repo since both creator dashboards retired (3 Nov 2026), so these cases run against a
# copy of land carrying one fixture route of exactly that shape, inserted before the catch-all.
FIXTURE_ROUTE='  build-first-fixture) DEPLOY="npm run deploy:production" ; SELF="" ; STAGING="npm run deploy:staging" ; E2E_WF="e2e" ; SMOKE="https://build-first-fixture.invalid/healthz" ;;'
awk -v r="$FIXTURE_ROUTE" '/^  \*\) .*die "\$NAME has no deploy route recorded/ && !done { print r; done=1 } { print }' "$LAND" > "$W/land-with-fixture"
grep -q "$(head -1 <<<"$FIXTURE_ROUTE" | cut -c1-12)" "$W/land-with-fixture" || { echo "FAIL: the fixture route was not put into land's routes case"; exit 1; }
grep -q '^  build-first-fixture)' "$W/land-with-fixture" || { echo "FAIL: could not add the build-first fixture route"; exit 1; }
LAND="$W/land-with-fixture"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
HEADSHA="1111111111111111111111111111111111111111"
MERGESHA="2222222222222222222222222222222222222222"

# --- fakes -------------------------------------------------------------------
printf '#!/bin/bash\necho "$*" >> "$FAKE_DIR/sleeps" 2>/dev/null\nexit 0\n' > "$BIN/sleep"   # every wait land asks for, logged (case 1e: none on the happy path)
cat > "$BIN/npm" <<'SH'
#!/bin/bash
{ echo "pwd=$PWD"; echo "head=$(git rev-parse HEAD)"; [ -L node_modules ] && echo "node_modules=linked"; } > "$FAKE_DIR/npm-ran"
echo "$* head=$(git rev-parse HEAD)" >> "$FAKE_DIR/npm-log"   # every invocation, in order (npm-ran holds only the last)
SH
# gh: behaviour per call from files in $FAKE_DIR. A mode file holding "tls" fails every time,
# "tls-once" fails the first call only, "401" answers with the auth error, anything else is the answer.
{ echo '#!/bin/bash'; grep '^sha_name() ' "$LAND"; cat <<'SH'   # land's own sha_name, never a copy
a="$*"; echo "$a" >> "$FAKE_DIR/calls"
echo "${GH_SHARE_UNTIL:-none}" > "$FAKE_DIR/gh-until"   # the deadline ~/bin/gh is given
answer() { # mode-file default
  local m; m="$(cat "$FAKE_DIR/$1" 2>/dev/null || echo "$2")"
  case "$m" in
    tls) echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' >&2; exit 1 ;;
    tls-once) if [ -f "$FAKE_DIR/$1.failed" ]; then echo "$2"; exit 0; fi
              : > "$FAKE_DIR/$1.failed"; echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' >&2; exit 1 ;;
    ratelimit) echo 'HTTP 403: API rate limit exceeded for user ID 1.' >&2; exit 1 ;;
    ratelimit-once) if [ -f "$FAKE_DIR/$1.failed" ]; then echo "$2"; exit 0; fi
              : > "$FAKE_DIR/$1.failed"; echo 'HTTP 403: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID' >&2; exit 1 ;;
    401) echo 'HTTP 401: Requires authentication (https://api.github.com/graphql)' >&2; echo 'Try authenticating with:  gh auth login' >&2; exit 1 ;;
    403) echo 'HTTP 403: Resource not accessible by integration (https://api.github.com/graphql)' >&2; exit 1 ;;
    502) echo 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' >&2; exit 1 ;;
    *) echo "$m"; exit 0 ;;
  esac
}
merged() { [ -f "$FAKE_DIR/merged" ]; }
case "$a" in
  # the merge queue (test-land-queue.sh covers it): nothing in flight, no recent land, in every case here.
  "run list --workflow "*"--status in_progress"*|"run list --workflow "*"--status queued"*|"pr list --state merged"*) exit 0 ;;
  "pr view "*"state,mergeCommit"*) merged && echo "MERGED/$MERGESHA" || echo "OPEN/"; exit 0 ;;
  # pending-reads N: the next N checks reads answer pending (a queued run), then the normal answer.
  # no-checks: GitHub ran no CI; mergeable answers what the PR's merge state is (default MERGEABLE).
  "pr view "*"--json mergeable "*) cat "$FAKE_DIR/mergeable" 2>/dev/null || echo MERGEABLE; exit 0 ;;
  "pr checks "*) [ -f "$FAKE_DIR/no-checks" ] && { echo "no checks reported on the 'x' branch" >&2; exit 1; }
    n="$(cat "$FAKE_DIR/pending-reads" 2>/dev/null || echo 0)"
    if [ "$n" = forever ] || [ "$n" -gt 0 ] 2>/dev/null; then
      [ "$n" = forever ] || echo $((n - 1)) > "$FAKE_DIR/pending-reads"
      echo "[{\"name\":\"test\",\"bucket\":\"pending\",\"link\":\"https://github.com/o/r/actions/runs/555/job/1\"}$(cat "$FAKE_DIR/pending-also" 2>/dev/null)]"; exit 0
    fi
    answer checks "[{\"name\":\"test\",\"bucket\":\"pass\",\"link\":\"https://github.com/o/r/actions/runs/555/job/1\"},{\"name\":\"Cloudflare Pages\",\"bucket\":\"pass\",\"link\":\"https://dash.cloudflare.com/x/fe13d725-4827-bc619\"}]" ;;
  "pr view "*baseRefName*) answer base main ;;
  # the allowance GitHub reports (land reads it with --jq): spent, back in 3 s.
  "api rate_limit"*) echo $(( $(date +%s) + 3 )); exit 0 ;;
  "pr view "*headRefOid*) answer head "$HEADSHA" ;;
  # pr-meta = the PR's files/body/comments JSON (case 1d); absent = one non-screen file, no body.
  # --owner reads the body and writes the override line back into pr-meta's body (her bypass, 21 Nov 2026).
  "pr view "*"--json body "*) jq -r '.body // ""' "$FAKE_DIR/pr-meta" 2>/dev/null; exit 0 ;;
  "pr edit "*"--body-file -"*) b="$(cat)"; jq --arg b "$b" '.body = $b' "$FAKE_DIR/pr-meta" > "$FAKE_DIR/pr-meta.new" && mv "$FAKE_DIR/pr-meta.new" "$FAKE_DIR/pr-meta"; exit 0 ;;
  # The PR's repo is its url (o/r, on the fixture live-repos.json unless a case says otherwise); no-url = GitHub left it out.
  "pr view "*"files,body,comments"*) { sed "s/@HEAD@/$(sha_name "$HEADSHA")/g" "$FAKE_DIR/pr-meta" 2>/dev/null || echo '{"files":[{"path":"README.md"}],"labels":[],"body":"","comments":[]}'; } \
      | if [ -f "$FAKE_DIR/no-url" ]; then cat; else jq -c '.url //= "https://github.com/o/r/pull/7"'; fi \
      | if [ -f "$FAKE_DIR/no-class" ]; then cat; else jq -c '.body = ((.body // "") + "\n\nReview class: none — a fixture change in no risk class")'; fi \
      | if [ -f "$FAKE_DIR/no-forms" ]; then cat; else jq -c '.body = ((.body // "") + "\nForms: none — a fixture change touching no form")'; fi \
      | if [ -f "$FAKE_DIR/no-outcome" ]; then cat; else jq -c '.body = ((.body // "") + "\nOutcome: none — a fixture change that runs nothing")'; fi \
      | if [ -f "$FAKE_DIR/no-notbuilt" ]; then cat; else jq -c '.body = ((.body // "") + "\n\n## Not built\nNothing cut.")'; fi; exit 0 ;;
  # label-events = every label ever added (gh's --jq answer over the PR's issue events); default none; tls = down.
  "api --paginate repos/"*"/issues/7/events "*) answer label-events '[]' ;;
  # live_add: seq-bin's list through the contents API (live-get = its answer), the PUT logged to live-put.
  "api repos/seq23/seq-bin/contents/live-repos.json?ref=main"*) answer live-get "{\"sha\":\"$(printf b%.0s {1..40})\",\"content\":\"$(printf '{"live":["o/r"]}' | base64 | tr -d '\n')\"}" ;;
  "api -X PUT repos/seq23/seq-bin/contents/live-repos.json "*) echo "$a" > "$FAKE_DIR/live-put"; answer live-put-answer "$(printf c%.0s {1..40})" ;;
  "run view 555 "*workflowName*) cat "$FAKE_DIR/pr-workflow" 2>/dev/null || echo "Fast Check"; exit 0 ;;
  "run view 555 "*) echo "$HEADSHA"; exit 0 ;;
  "pr view "*mergeStateStatus*) echo "MERGEABLE/CLEAN"; exit 0 ;;
  # merge=graphql500: GitHub's own 5xx answer to the merge mutation (30 Oct 2026), nothing merged.
  # merge=refused: a real refusal from GitHub (not a server error), nothing merged.
  "pr merge "*) case "$(cat "$FAKE_DIR/merge" 2>/dev/null)" in
      graphql500) echo 'GraphQL: Something went wrong while executing your query on 2026-10-30T14:26:18Z. Please include `F1A0:283603:182C90:4E979C:6AE4A908` when reporting this issue.' >&2; exit 1 ;;
      refused) echo 'GraphQL: Pull Request is not mergeable (mergePullRequest)' >&2; exit 1 ;;
      ratelimit-once) if [ ! -f "$FAKE_DIR/merge.failed" ]; then : > "$FAKE_DIR/merge.failed"; echo 'GraphQL: API rate limit exceeded for user ID 1.' >&2; exit 1; fi ;;
      # race: another PR merged a second earlier (boss-os#518), every time; race-once: the first call only.
      # On a race, race-then-<file> (checks, head) replaces that answer: the PR changed between tries.
      race|race-once) if [ "$(cat "$FAKE_DIR/merge")" = race ] || [ ! -f "$FAKE_DIR/merge.failed" ]; then
          : > "$FAKE_DIR/merge.failed"; for f in checks head; do [ -f "$FAKE_DIR/race-then-$f" ] && cp "$FAKE_DIR/race-then-$f" "$FAKE_DIR/$f"; done
          echo 'GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)' >&2; exit 1; fi ;;
    esac; : > "$FAKE_DIR/merged"; exit 0 ;;
  "pr view "*"--json state "*) merged && echo MERGED || echo OPEN; exit 0 ;;
  "pr view "*mergeCommit*) echo "$MERGESHA"; exit 0 ;;
  # pr-size = "ADD DEL FILES" + paths, one per line (cases 15-17); absent = the read fails (unhandled).
  "pr view "*additions*) [ -f "$FAKE_DIR/pr-size" ] || { echo "HTTP 500" >&2; exit 1; }; cat "$FAKE_DIR/pr-size"; exit 0 ;;
  # --- promote fakes (cases 11-14). promote-inflight = a promote.yml run 777 is in flight on
  # origin/main; each conclusion read counts down promote-ticks, and when it reaches 0 the run is
  # done and production's deployment record says origin/main. promote-hang = it never finishes.
  # last_duration reads the newest SUCCESSFUL run (land, 1 Nov 2026); the stub answers that query
  # only, so a land that went back to --status completed would fall to its 1800 s default and show.
  "run list --workflow promote.yml "*"--status success --limit 5 --json createdAt,updatedAt"*|"run list --workflow deploy.yml "*"--status success --limit 5 --json createdAt,updatedAt"*) cat "$FAKE_DIR/promote-last" 2>/dev/null || echo 100; exit 0 ;;  # last_duration
  # --- land's own dispatch of a PROMOTE_VIA workflow (cases 19+): `workflow run` leaves its
  # arguments in `dispatched`; run 778 is that run; dispatch-conc is its conclusion (default
  # success), and on success the workflow has recorded production = origin/main (prod-state)
  # unless dispatch-no-record says it did not.
  "workflow run promote.yml "*|"workflow run deploy.yml "*) echo "$a" > "$FAKE_DIR/dispatched"; exit 0 ;;
  "run list --workflow promote.yml --event workflow_dispatch"*|"run list --workflow deploy.yml --event workflow_dispatch"*)
    [ -f "$FAKE_DIR/dispatched" ] && echo 778; exit 0 ;;
  "api repos/{owner}/{repo}/actions/runs/778 "*) c="$(cat "$FAKE_DIR/dispatch-conc" 2>/dev/null || echo success)"
    [ "$c" = success ] && [ ! -f "$FAKE_DIR/dispatch-no-record" ] && echo "$ORIGIN_MAIN" > "$FAKE_DIR/prod-state"
    echo "$c"; exit 0 ;;
  "run list --workflow promote.yml "*|"run list --workflow deploy.yml "*)
    if [ -f "$FAKE_DIR/promote-inflight" ] && [ ! -f "$FAKE_DIR/promote-done" ]; then printf '777\t%s\tin_progress\n' "$ORIGIN_MAIN"; fi; exit 0 ;;
  "api repos/{owner}/{repo}/actions/runs/777 "*)
    [ -f "$FAKE_DIR/promote-hang" ] && exit 0
    [ -f "$FAKE_DIR/promote-refused" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    t="$(cat "$FAKE_DIR/promote-ticks" 2>/dev/null || echo 0)"
    if [ "$t" -le 0 ]; then : > "$FAKE_DIR/promote-done"; echo success; else echo $((t - 1)) > "$FAKE_DIR/promote-ticks"; fi; exit 0 ;;
  "run cancel 777"*) : > "$FAKE_DIR/promote-cancelled"; exit 0 ;;
  # e2e-on-sha = the conclusion of the completed e2e run on the merge sha (absent: none completed).
  "run list --workflow e2e "*"--json headSha,status,conclusion"*) cat "$FAKE_DIR/e2e-on-sha" 2>/dev/null; exit 0 ;;
  # e2e-last = the newest run on main that reached a verdict, "<conclusion><TAB><run><TAB><sha>"
  # (absent: "none", no run ever did; "tls": the history cannot be read).
  "run list --workflow e2e "*"conclusion,headSha,databaseId,status"*) answer e2e-last none ;;
  # e2e-pending = no green e2e yet; run 800 is in flight on origin/main and goes green when read.
  "run list --workflow e2e "*"--status success --limit 5 --json createdAt,updatedAt"*) echo 100; exit 0 ;;  # last_duration
  "run list --workflow e2e "*"--status success"*) [ -f "$FAKE_DIR/e2e-pending" ] || echo "$ORIGIN_MAIN"; exit 0 ;;
  "run list --workflow e2e "*"databaseId,headSha,status"*) [ -f "$FAKE_DIR/e2e-pending" ] && echo 800; exit 0 ;;
  "run list --workflow e2e "*) exit 0 ;;
  "api repos/{owner}/{repo}/actions/runs/800 "*) rm -f "$FAKE_DIR/e2e-pending"
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
  "api repos/{owner}/{repo}/actions/runs/900 "*) echo success; exit 0 ;;
  # same-tree (case 1e): the merge commit's tree is the PR head's, and the PR's workflow is a file on main.
  "api repos/{owner}/{repo}/actions/workflows?per_page=100"*) [ -f "$FAKE_DIR/same-tree" ] && echo ".github/workflows/fast.yml"; exit 0 ;;
  "api repos/{owner}/{repo}/commits/"*".commit.tree.sha"*) [ -f "$FAKE_DIR/same-tree" ] && echo "7ree000000000000000000000000000000000000"; exit 0 ;;
  "api "*) exit 0 ;;   # no Cloudflare check-runs posted
  *) echo "fake gh: unhandled: $a" >&2; exit 1 ;;
esac
SH
} > "$BIN/gh"
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
  mkdir -p "$W/pusher/site"; echo '<h1>live</h1>' > "$W/pusher/site/index.html"   # a live page: a screen PR is not the repo's first surface (Launch-ready)
  echo '{"lockfileVersion":3}' > "$W/pusher/package-lock.json"   # identical lockfile: deploy_at shares her node_modules
  if [ -n "${2:-}" ]; then mkdir -p "$W/pusher/.github/workflows"; echo "name: $2" > "$W/pusher/.github/workflows/$2.yml"; fi
  git -C "$W/pusher" add -A; git -C "$W/pusher" commit -qm base; git -C "$W/pusher" push -q origin HEAD:main
  git clone -q "$W/origin.git" "$W/$name"
  echo '{"v":2}' > "$W/pusher/artifacts/a.json"; git -C "$W/pusher" commit -qam "the merged PR"; git -C "$W/pusher" push -q origin HEAD:main
  ORIGIN_MAIN="$(git -C "$W/pusher" rev-parse HEAD)"; export ORIGIN_MAIN
  # the PR's head: a real commit at refs/pull/7/head, so the STALE_PASS gate can read its history.
  git -C "$W/pusher" checkout -q -b pr HEAD~1; echo pr > "$W/pusher/pr.txt"; git -C "$W/pusher" add pr.txt
  git -C "$W/pusher" commit -qm "the PR"; HEADSHA="$(git -C "$W/pusher" rev-parse HEAD)"; export HEADSHA
  git -C "$W/pusher" push -q origin HEAD:refs/pull/7/head; git -C "$W/pusher" checkout -q main
}
run_land() { # name [flags...] -> sets OUT, RC
  local name="$1"; shift
  OUT="$(cd "$W/$name" && PATH="$BIN:$PATH" LAND_SURFACES="$HERE/../land-surfaces.json" LAND_RETRY_SECS=0 PAGES_APPEAR_SECS=0 LAND_PROMOTE_APPEAR_SECS=5 bash "$LAND" 7 "$@" 2>&1)"; RC=$?
  [ -z "${LAND_TEST_SHOW:-}" ] || printf '%s\n' "$OUT" | sed 's/^/    | /'   # LAND_TEST_SHOW=1: print what land said
}
npm_log() { cat "$FAKE/npm-log" 2>/dev/null || true; }
suite_untouched() { ! grep -q "^api repos/{owner}/{repo}/actions/runs/800" "$FAKE/calls" && ! grep -q "^workflow run e2e" "$FAKE/calls"; }
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
  if "$@"; then echo "  ok   $label"; passes=$((passes+1)); else echo "  FAIL $label"; fails=$((fails+1)); [ -z "${LAND_TEST_DEBUG:-}" ] || { printf "%s\n" "$OUT" | tail -25 | sed "s/^/    | /"; grep -n "DUE" "$LAND_DUE_FILE" | sed "s/^/    H /"; }; fi
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
# 22 Nov 2026 hostile review F1: main's run is read once per poll through one api GET (1 REST request, 0 on a
# 304), never through `run view` (2 requests, and it was two of them per poll) or `run watch` (every 3 s)
check "main's run 900 was read once, by one api GET, never run view or run watch" eval '[ "$(grep -c "^api repos/{owner}/{repo}/actions/runs/900" "$FAKE/calls")" -eq 1 ] && ! grep -qE "^run (view|watch) 900" "$FAKE/calls"'
check "her dirty file is byte-for-byte hers" [ "$(cat "$W/approvalprep/artifacts/a.json")" = '{"v":"hers"}' ]
check "her local main was not moved" [ "$(git -C "$W/approvalprep" rev-parse HEAD)" = "$BEFORE" ]
# #138 review: ~/bin/gh must not sleep past the whole land's 65-min wait (one owner of waiting).
check "every gh call carried land's deadline (GH_SHARE_UNTIL ~ start + 65 min)" eval 'u="$(cat "$FAKE/gh-until")"; [[ "$u" =~ ^[0-9]+$ ]] && [ $(( u - $(date +%s) )) -gt 3600 ] && [ $(( u - $(date +%s) )) -le 3900 ]'
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
# 22 Nov 2026 hostile review F1: main's run is read once per poll through one api GET (1 REST request, 0 on a
# 304), never through `run view` (2 requests, and it was two of them per poll) or `run watch` (every 3 s)
check "main's run 900 was read once, by one api GET, never run view or run watch" eval '[ "$(grep -c "^api repos/{owner}/{repo}/actions/runs/900" "$FAKE/calls")" -eq 1 ] && ! grep -qE "^run (view|watch) 900" "$FAKE/calls"'
check "the quoted name never reached the run list" eval '! grep -q "^run list --branch main .*Bad" "$FAKE/calls"'

echo "=== 1c. an already-merged PR skipped step 1, so its checks are read for the workflow ==="
fixture approvalprep
: > "$FAKE/merged"
run_land approvalprep
check "rc 0" [ "$RC" -eq 0 ]
check "nothing was merged again" eval '! merge_called'
check "the merged PR's checks were read once, for the workflow" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 1 ]
check "…and its workflow was handed to the pick of the merge commit's run" grep -q '^run list --branch main .*Fast Check' "$FAKE/calls"

echo "=== 1d. a changed screen lands only once it was clicked through (olp_m6qyb1m4wke6h9dx) ==="
fixture approvalprep
echo '{"files":[{"path":"src/client/boss/pages/Updates.tsx"},{"path":"tests/x.test.ts"}],"labels":[],"body":"Adds the page.\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the fix in the page | tests/x.test.ts goes red |","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "rc 1: stopped" [ "$RC" -eq 1 ]
check "a named stop that names the screen" has "NAMED STOP [NOT_CLICKED_THROUGH]"
check "…and the file" has "src/client/boss/pages/Updates.tsx"
check "nothing was merged" eval '! merge_called'
fixture approvalprep
echo '{"files":[{"path":"src/client/boss/pages/Updates.tsx"}],"body":"Adds the page.","comments":[{"body":"Clicked through: Updates page, every row and the empty state, 390 px, console clean"}]}' > "$FAKE/pr-meta"
run_land approvalprep
check "clicked through but no Ship-ready PASS (row 6e): rc 1, one line saying what to add" eval '[ "$RC" -eq 1 ] && has "Ship-ready: PASS — "'
check "…and nothing was merged" eval '! merge_called'
fixture approvalprep
echo '{"files":[{"path":"src/client/boss/pages/Updates.tsx"}],"body":"Adds the page.\nShip-ready: PASS — hostile-review session_01REVIEW looked at the Updates page at 390 px at @HEAD@; Engineering: PASS\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the fix in the page | tests/x.test.ts goes red |","comments":[{"body":"Clicked through: Updates page, every row and the empty state, 390 px, console clean"}]}' > "$FAKE/pr-meta"
run_land approvalprep
check "with a Clicked through comment and a fresh Ship-ready PASS: rc 0" [ "$RC" -eq 0 ]
check "…and it was merged" merge_called
check "…and land says what was clicked" has "clicked through: Clicked through: Updates page"
fixture approvalprep
echo '{"files":[{"path":"src/client/boss/pages/Updates.tsx"}],"body":"Ship-ready: PASS — hostile-review session_01REVIEW Looked at the Updates page at 390 px at @HEAD@; Engineering: PASS\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the fix in the page | tests/x.test.ts goes red |","comments":[{"body":"Clicked through: Updates page, 390 px"}]}' > "$FAKE/pr-meta"
run_land approvalprep
check "a capitalised \"Looked at\" sign-off is accepted (21 Nov 2026: PBS #74 was refused for the capital L): rc 0" [ "$RC" -eq 0 ]
fixture approvalprep
echo '{"files":[{"path":"tests/boss/x.test.tsx"},{"path":"site/guides/a.html"},{"path":"worker/x.ts"}],"body":"Ship-ready: PASS — hostile-review session_01REVIEW looked at guides/a at 390 px at @HEAD@; Engineering: PASS\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the fix in the page | tests/x.test.ts goes red |","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "tests, content pages and server code need no click: rc 0" [ "$RC" -eq 0 ]

echo "=== 1e. Fast PRs (her ruling 23 Nov 2026): a review only for a review-class PR, no re-wait on green CI, a rendered: PASS is a click ==="
MP='\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the fix | tests/x.test.ts goes red |'
fixture approvalprep fast; : > "$FAKE/same-tree"
echo "{\"files\":[{\"path\":\"worker/x.ts\"}],\"labels\":[],\"body\":\"Fixes the sync.$MP\",\"comments\":[]}" > "$FAKE/pr-meta"
run_land approvalprep
check "happy path: a green PR outside the review classes, with no PASS line, lands (rc 0, merged)" eval '[ "$RC" -eq 0 ] && merge_called'
check "…with no wait at all: the checks read once, no sleep, main's run of the same tree never polled" eval '[ "$(grep -c "^pr checks" "$FAKE/calls")" -eq 1 ] && [ ! -s "$FAKE/sleeps" ] && ! grep -q "^api repos/{owner}/{repo}/actions/runs/900" "$FAKE/calls" && has "same tree as the tested head"'
fixture approvalprep fast; : > "$FAKE/same-tree"
echo "{\"files\":[{\"path\":\"worker/x.ts\"}],\"labels\":[{\"name\":\"bug\"},{\"name\":\"review-required\"}],\"body\":\"Fixes the sync.$MP\",\"comments\":[]}" > "$FAKE/pr-meta"
run_land approvalprep
check "safety: a review-class PR (review-required label) with no PASS line is refused, rc 1, not merged" eval '[ "$RC" -eq 1 ] && has "review-required label" && has "Ship-ready: PASS — " && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"
echo "{\"files\":[{\"path\":\"worker/x.ts\"}],\"body\":\"Fixes the sync.$MP\",\"comments\":[]}" > "$FAKE/pr-meta"
run_land approvalprep
check "outage: labels missing from GitHub's answer count as review class: refused, rc 1, not merged" eval '[ "$RC" -eq 1 ] && has "labels could not be read" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"
echo "{\"files\":[{\"path\":\"src/client/boss/pages/Updates.tsx\"}],\"labels\":[],\"body\":\"Adds the page.\\nShip-ready: PASS — hostile-review session_01REVIEW looked at the Updates page at @HEAD@; Engineering: PASS\\nrendered: Updates page at 320 and 390 px, light and dark$MP\",\"comments\":[{\"authorAssociation\":\"OWNER\",\"body\":\"rendered: Updates page at 390 px\"}]}" > "$FAKE/pr-meta"
run_land approvalprep
check "abuse: rendered: on its own line and in a comment, not ON the PASS line: NOT_CLICKED_THROUGH, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [NOT_CLICKED_THROUGH]" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"
echo "{\"files\":[{\"path\":\"src/client/boss/pages/Updates.tsx\"}],\"labels\":[],\"body\":\"Adds the page.\\nShip-ready: PASS — builder looked at the Updates page, rendered: at 390 px at @HEAD@; Engineering: PASS$MP\",\"comments\":[]}" > "$FAKE/pr-meta"
run_land approvalprep
check "abuse: a rendered: PASS signed by the builder is no click: NOT_CLICKED_THROUGH, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [NOT_CLICKED_THROUGH]" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"
echo "{\"files\":[{\"path\":\"src/client/boss/pages/Updates.tsx\"}],\"labels\":[],\"body\":\"Adds the page.\\nShip-ready: PASS — hostile-review session_01REVIEW looked at the Updates page, rendered: Updates at 320 and 390 px light and dark, at @HEAD@; Engineering: PASS$MP\",\"comments\":[]}" > "$FAKE/pr-meta"
run_land approvalprep
check "item 4: a fresh reviewer's PASS whose own line says rendered: needs no Clicked through line: rc 0, merged" eval '[ "$RC" -eq 0 ] && merge_called && has "rendered by the reviewer: "'

echo "=== 1f. the review class: her final list (27 Nov 2026), written or read from the paths, and sticky ==="
code_pr() { # body [extra jq] -> a code PR in o/r with no PASS line, labels []
  jq -nc --arg b "$1" '{files: [{path: "worker/x.ts"}], labels: [], body: $b, comments: []}' | jq -c "${2:-.}" > "$FAKE/pr-meta"
}
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "Fixes the sync.$(printf "$MP")"
run_land approvalprep
check "her list (27 Nov 2026): a code PR with labels [] and NO Review class line, on no class path in a repo with no data store, is read as none from its paths: lands with no PASS (rc 0, merged), no reviewer asked" eval '[ "$RC" -eq 0 ] && merge_called && ! has "needs a review" && ! has "REVIEW_CLASS_UNDECLARED"'
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "Fixes the charge.$(printf "$MP")" '.files = [{path: "src/billing/charge.ts"}]'
run_land approvalprep
check "safety: no Review class line on a payments path is NEVER read as none: NAMED STOP [REVIEW_CLASS_UNDECLARED] (rc 1, not merged), naming the path and the line to add" eval '[ "$RC" -eq 1 ] && has "STOPPED: NAMED STOP [REVIEW_CLASS_UNDECLARED]" && has "no \`Review class:\` line" && has "money (src/billing/charge.ts)" && has "add: Review class: none — <why this is in no review class, 3+ words>" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "Fixes the sync.
Review class: none — log wording only$(printf "$MP")"
run_land approvalprep
check "promise: with 'Review class: none — log wording only' in a launched repo it lands with no PASS (rc 0, merged)" eval '[ "$RC" -eq 0 ] && merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "Moves the payout.
Review class: money — changes how payouts are sent$(printf "$MP")"
run_land approvalprep
check "safety: 'Review class: money' with no PASS is refused (rc 1, not merged)" eval '[ "$RC" -eq 1 ] && has "Review class: money" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "Fixes it.
Review class: none — <why>$(printf "$MP")" '.files = [{path: "src/billing/charge.ts"}]'
run_land approvalprep
check "abuse: a placeholder none is no reason, so on a payments path it is no line at all: refused, not merged" eval '[ "$RC" -eq 1 ] && has "gives no reason" && has "[REVIEW_CLASS_UNDECLARED]" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")" '.labels = [{name: "bug"}]'
echo '["review-required","bug"]' > "$FAKE/label-events"
run_land approvalprep
check "abuse: review-required labeled then removed still counts: refused, not merged" eval '[ "$RC" -eq 1 ] && has "taken off still counts" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")"; echo tls > "$FAKE/label-events"
run_land approvalprep
check "outage: the label history unread: exit 75 'could not verify', not merged" eval '[ "$RC" -eq 75 ] && has "label history" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")" '.url = "https://github.com/o/brand-new/pull/7"'
run_land approvalprep
check "her list (27 Nov 2026): a code-only PR in a repo NOT on live-repos.json is no class by that alone: lands on green CI with no reviewer PASS (rc 0, merged), and nothing is added to the list" eval '[ "$RC" -eq 0 ] && merge_called && ! has "has not launched" && ! has "needs a review" && [ ! -f "$FAKE/live-put" ]'
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "The first site.
Review class: launch — the first public launch of this site$(printf "$MP")" '.url = "https://github.com/o/brand-new/pull/7"'
run_land approvalprep
check "…its ONE launch review still stands: 'Review class: launch' with no PASS is refused (rc 1, not merged)" eval '[ "$RC" -eq 1 ] && has "STOPPED: NAMED STOP [REVIEW_PASS_MISSING]" && has "it says Review class: launch" && ! merge_called'
for cls in private-data delete store outreach; do
  fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; code_pr "Does the thing.
Review class: $cls — the brief put it in this class$(printf "$MP")"
  run_land approvalprep
  check "safety: 'Review class: $cls' with no PASS is refused (rc 1, not merged)" eval '[ "$RC" -eq 1 ] && has "it says Review class: $cls" && has "add: Ship-ready: PASS — " && ! merge_called'
done
fixture approvalprep fast; : > "$FAKE/same-tree"; : > "$FAKE/no-class"; : > "$FAKE/no-outcome"; : > "$FAKE/no-notbuilt"; code_pr "Fixes the sync." '.files = [{path: "src/billing/charge.ts"}]'
run_land approvalprep
check "ONE pass (27 Nov 2026): a description lacking four lines is told ALL four in one run, each with its line, then stopped ONCE, not merged" eval '[ "$RC" -eq 1 ] && has "4 problem(s) to fix" && has "1. [REVIEW_CLASS_UNDECLARED]" && has "2. [MUTATION_PROOF_MISSING]" && has "3. [OUTCOME_UNDECLARED]" && has "4. [NOT_BUILT_UNDECLARED]" && has "add: ## Mutation proof" && has "add: Outcome: none — <" && has "add: ## Not built" && [ "$(grep -c "STOPPED:" <<<"$OUT")" -eq 1 ] && has "And 3 more (MUTATION_PROOF_MISSING, OUTCOME_UNDECLARED, NOT_BUILT_UNDECLARED)" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")" '.url = "https://github.com/O/R/pull/7"'
run_land approvalprep
check "promise: a listed repo is not slowed, whatever GitHub's case (rc 0, merged)" eval '[ "$RC" -eq 0 ] && merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")"
cp "$W/live-repos.json" "$W/live-repos.keep"; echo '{"live": [' > "$W/live-repos.json"
run_land approvalprep
check "live-repos.json unreadable no longer holds a PR that is in no class (the list decides no review since 27 Nov 2026): rc 0, merged, nothing written to the list" eval '[ "$RC" -eq 0 ] && merge_called && ! has "LIVE_REPOS_UNREAD" && [ ! -f "$FAKE/live-put" ]'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Lists my repo.$(printf "$MP")" '.files = [{path: "live-repos.json"}]'
run_land approvalprep
check "…while a PR that CHANGES the list is still refused with the list unreadable (fail closed), not merged" eval '[ "$RC" -eq 1 ] && has "changes live-repos.json" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")"
rm -f "$W/live-repos.json"
run_land approvalprep
check "live-repos.json missing: the same, a PR in no class lands (rc 0, merged)" eval '[ "$RC" -eq 0 ] && merge_called && ! has "LIVE_REPOS_UNREAD"'
mv "$W/live-repos.keep" "$W/live-repos.json"
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Fixes the sync.$(printf "$MP")"; : > "$FAKE/no-url"
run_land approvalprep
check "outage: no url in GitHub's answer: the repo (and its label history) unknown: never 0, not merged" eval '[ "$RC" -ne 0 ] && { has "repository could not be read" || has "label history"; } && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Lists my repo.$(printf "$MP")" '.files = [{path: "live-repos.json"}]'
run_land approvalprep
check "abuse: a PR that edits live-repos.json by hand is review-class: refused, not merged" eval '[ "$RC" -eq 1 ] && has "changes live-repos.json" && ! merge_called'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Big one.$(printf "$MP")" '.changedFiles = 140'
run_land approvalprep
check "abuse: GitHub listed 1 of 140 files: the rest are unread, refused, not merged" eval '[ "$RC" -eq 1 ] && has "listed only 1 of its 140 files" && ! merge_called'
LP="Ship-ready: PASS — launch-review session_01LAUNCH looked at the home page, 404 and store listing at @HEAD@; Engineering: PASS
Launch-ready: PASS — launch-review session_01LAUNCH looked at the logo, banner, bio, links, starter posts and 404 at @HEAD@"
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Launches it.
$LP$(printf "$MP")" '.url = "https://github.com/o/brand-new/pull/7"'
run_land approvalprep
check "launch: a fresh Launch-ready PASS in an unlisted repo lands (rc 0, merged)" eval '[ "$RC" -eq 0 ] && merge_called'
check "…and commits o/brand-new onto seq-bin's live-repos.json, pinned to the file's sha" eval 'grep -q "sha=$(printf b%.0s {1..40})" "$FAKE/live-put" && sed -nE "s/.*content=([A-Za-z0-9+\/=]+).*/\1/p" "$FAKE/live-put" | base64 -d | jq -e ".live == [\"o/brand-new\",\"o/r\"]" >/dev/null'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Launches it.
${LP/Launch-ready: PASS — launch-review session_01LAUNCH/Launch-ready: PASS — builder}$(printf "$MP")" '.url = "https://github.com/o/brand-new/pull/7" | .author = {login: "builder"}'
run_land approvalprep
check "abuse: a Launch-ready PASS signed by the builder lists nothing: merged on its Ship-ready PASS, no PUT, says why" eval '[ "$RC" -eq 0 ] && merge_called && [ ! -f "$FAKE/live-put" ] && has "stays off live-repos.json"'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Launches it.
$LP$(printf "$MP")" '.url = "https://github.com/o/brand-new/pull/7"'; echo 502 > "$FAKE/live-put-answer"
run_land approvalprep
check "outage: the list commit refused: merged, but exit 5 with NAMED STOP [LIVE_REPO_NOT_ADDED], never 0" eval '[ "$RC" -eq 5 ] && merge_called && has "NAMED STOP [LIVE_REPO_NOT_ADDED]"'
fixture approvalprep fast; : > "$FAKE/same-tree"; code_pr "Launches it.
$LP$(printf "$MP")" '.url = "https://github.com/o/brand-new/pull/7"'; echo tls > "$FAKE/live-get"
run_land approvalprep
check "outage: the list unreadable on GitHub: exit 5, the named stop, nothing written" eval '[ "$RC" -eq 5 ] && has "NAMED STOP [LIVE_REPO_NOT_ADDED]" && [ ! -f "$FAKE/live-put" ]'

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
check "a self-deploying repo with no PROMOTE_VIA is done at its build: nothing dispatched, no size read" eval '! grep -q "^workflow run" "$FAKE/calls" && ! grep -q "json additions,deletions,changedFiles" "$FAKE/calls"'

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

echo "=== 10b. pending checks are waited for, bounded (22 Nov 2026: land stopped at once on a queued check) ==="
fixture approvalprep; echo 2 > "$FAKE/pending-reads"
run_land approvalprep
check "pending twice, then green: rc 0, merged" eval '[ "$RC" -eq 0 ] && merge_called'
check "…after 3 reads of the checks (two pending, one green)" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 3 ]
check "…and it said what it waited for" has "waiting for 1 pending check(s): test"
fixture approvalprep; echo forever > "$FAKE/pending-reads"
OUT="$(cd "$W/approvalprep" && PATH="$BIN:$PATH" LAND_SURFACES="$HERE/../land-surfaces.json" LAND_RETRY_SECS=0 LAND_PENDING_WAIT=0 bash "$LAND" 7 2>&1)"; RC=$?
check "pending past the bound: rc 1, NAMED STOP [CHECKS_PENDING]" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [CHECKS_PENDING]"'
check "…and nothing was merged" eval '! merge_called'
fixture approvalprep; echo forever > "$FAKE/pending-reads"
echo ',{"name":"lint","bucket":"fail","link":"https://github.com/o/r/actions/runs/555/job/2"}' > "$FAKE/pending-also"
LAND_PENDING_WAIT=2 run_land approvalprep   # bounded: a land that ignored the failure would wait, then stop as pending
check "a failure beside a pending check stops at once: rc 1, not green — lint: fail" eval '[ "$RC" -eq 1 ] && has "lint: fail"'
check "…after one read, no waiting" [ "$(grep -c '^pr checks' "$FAKE/calls")" -eq 1 ]
check "…and nothing was merged" eval '! merge_called'

echo "=== 10f. no checks on a conflicted PR is named a merge conflict (22 Nov 2026, boss-os #539) ==="
fixture approvalprep; touch "$FAKE/no-checks"; echo CONFLICTING > "$FAKE/mergeable"
run_land approvalprep
check "conflicted, no checks: rc 1, NAMED STOP [MERGE_CONFLICT]" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [MERGE_CONFLICT]"'
check "…and nothing was merged" eval '! merge_called'
fixture approvalprep; touch "$FAKE/no-checks"
run_land approvalprep
check "mergeable, no checks: still 'no checks at all', never called a conflict" eval '[ "$RC" -eq 1 ] && has "no checks at all" && ! has MERGE_CONFLICT'

echo "=== 10d. a spent allowance is waited out, then the land carries on (22 Nov 2026, #134 died at 09:35 CT) ==="
fixture approvalprep; echo ratelimit-once > "$FAKE/checks"
run_land approvalprep
check "checks read rate-limited once: rc 0, merged (was: exit 75, could not verify (auth))" eval '[ "$RC" -eq 0 ] && merge_called'
check "…it asked GitHub when the allowance resets, and said it was waiting" eval 'grep -q "^api rate_limit" "$FAKE/calls" && has "allowance is spent; waiting"'
check "…and never called it an auth failure" eval '! has "could not verify (auth)"'
fixture approvalprep; echo ratelimit-once > "$FAKE/merge"
run_land approvalprep
check "the merge call rate-limited once: waited, merged on the second call, rc 0" eval '[ "$RC" -eq 0 ] && [ "$(grep -c "^pr merge" "$FAKE/calls")" -eq 2 ]'
fixture approvalprep; echo ratelimit > "$FAKE/checks"
OUT="$(cd "$W/approvalprep" && PATH="$BIN:$PATH" LAND_SURFACES="$HERE/../land-surfaces.json" LAND_RETRY_SECS=0 LAND_RATE_WAIT=1 bash "$LAND" 7 2>&1)"; RC=$?
check "a reset past the bound: exit 75, could not verify (rate limit), nothing merged" eval '[ "$RC" -eq 75 ] && has "could not verify (rate limit)" && ! merge_called'

# Review F3 of #137: the bound is for the WHOLE land, across reads (each gh_read runs in its own $( )). A clock that
# sleep moves forward: the first read waits 8 s for the reset, so the second has 4 s of a 12 s bound left, too few.
mkdir -p "$W/clock"; echo 0 > "$W/clock/offset"
printf '#!/bin/bash\nif [ "$1" = +%%s ]; then echo $(( $(/bin/date +%%s) + $(cat "%s/clock/offset") )); else exec /bin/date "$@"; fi\n' "$W" > "$W/clock/date"
printf '#!/bin/bash\nn="${1%%%%.*}"; echo $(( $(cat "%s/clock/offset") + ${n:-0} )) > "%s/clock/offset"\n' "$W" "$W" > "$W/clock/sleep"
chmod +x "$W/clock/date" "$W/clock/sleep"
fixture approvalprep; echo ratelimit-once > "$FAKE/base"; echo ratelimit > "$FAKE/checks"
# Under `timeout 60`: a bound that never holds spins the fake clock forever; a hang must be a red check, not a stuck CI job.
OUT="$(cd "$W/approvalprep" && PATH="$W/clock:$BIN:$PATH" LAND_SURFACES="$HERE/../land-surfaces.json" LAND_RETRY_SECS=0 LAND_RATE_WAIT=12 timeout 60 bash "$LAND" 7 2>&1)"; RC=$?
check "two rate-limited reads, 8 s each, under a 12 s bound: exit 75, could not verify (rate limit), nothing merged" eval '[ "$RC" -eq 75 ] && has "could not verify (rate limit)" && ! merge_called'
check "…one wait in the whole land, not one per read" [ "$(grep -c "allowance is spent; waiting" <<<"$OUT")" -eq 1 ]

echo "=== 10e. a merge race (another PR merged a second earlier, boss-os#518) is tried again, verified each time ==="
merges() { grep -c '^pr merge' "$FAKE/calls"; }
fixture approvalprep; echo race-once > "$FAKE/merge"
run_land approvalprep
check "the base moved under the first try: verified again, merged on the second, rc 0" eval '[ "$RC" -eq 0 ] && [ -f "$FAKE/merged" ] && [ "$(merges)" -eq 2 ] && has "main moved under the merge"'
check "…the checks were read again between the tries" [ "$(grep -c '^pr checks' "$FAKE/calls")" -ge 2 ]
check "…every try pinned to the verified head, never --admin, --auto or a bypass" eval '! grep "^pr merge" "$FAKE/calls" | grep -v -- "--match-head-commit $HEADSHA" | grep -q . && ! grep "^pr merge" "$FAKE/calls" | grep -qE -- "--admin|--auto|--disable-auto"'
fixture approvalprep; echo race > "$FAKE/merge"
run_land approvalprep
check "the base keeps moving: 3 tries, then rc 1, nothing merged, says so" eval '[ "$RC" -eq 1 ] && [ ! -f "$FAKE/merged" ] && [ "$(merges)" -eq 3 ] && has "main moved under all 3 tries"'
fixture approvalprep; echo race-once > "$FAKE/merge"
echo '[{"name":"test","bucket":"fail","link":"https://github.com/o/r/actions/runs/555/job/1"}]' > "$FAKE/race-then-checks"
run_land approvalprep
check "abuse: the checks went red between tries -> rc 1, no second try, nothing merged" eval '[ "$RC" -eq 1 ] && [ "$(merges)" -eq 1 ] && [ ! -f "$FAKE/merged" ] && has "no longer green"'
fixture approvalprep; echo race-once > "$FAKE/merge"; echo 3333333333333333333333333333333333333333 > "$FAKE/race-then-head"
run_land approvalprep
check "abuse: a new head was pushed between tries -> rc 1, no second try, nothing merged" eval '[ "$RC" -eq 1 ] && [ "$(merges)" -eq 1 ] && [ ! -f "$FAKE/merged" ] && has "head moved"'
for code in 403 502; do
  fixture approvalprep; echo race-once > "$FAKE/merge"; echo "$code" > "$FAKE/race-then-checks"
  run_land approvalprep
  check "outage: GitHub answers $code when re-verifying -> exit 75 could not verify, no second try, never LANDED" eval '[ "$RC" -eq 75 ] && has "could not verify" && [ "$(merges)" -eq 1 ] && [ ! -f "$FAKE/merged" ] && ! has "LANDED"'
done
fixture approvalprep; echo refused > "$FAKE/merge"
run_land approvalprep
check "any other merge error is not retried: one try, rc 1" eval '[ "$RC" -eq 1 ] && [ "$(merges)" -eq 1 ]'

echo "=== 10c. a stacked PR (base is not main) is refused (22 Nov 2026, westpeek-live #122) ==="
fixture approvalprep; echo work/random-role-codes > "$FAKE/base"
run_land approvalprep
check "base work/random-role-codes: rc 1, NAMED STOP [STACKED_PR] naming the base" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [STACKED_PR]" && has "work/random-role-codes"'
check "…with the way out" has "gh pr edit 7 --base main"
check "…and nothing was merged" eval '! merge_called'
fixture approvalprep; echo tls > "$FAKE/base"
run_land approvalprep
check "the base unreadable: exit 75, could not verify, nothing merged" eval '[ "$RC" -eq 75 ] && ! merge_called'

# --- land --promote against a repo that promotes itself (promote.yml) — 26 Sep 2026 ----------------
# build-first-fixture's promote.yml deploys production on a green e2e. A person's `land --promote`
# in the same minutes must WAIT for that run and read production after it, never build + migrate +
# deploy the same sha on top of it.
echo "=== 11. a promote.yml run is in flight: land waits for it, then finds nothing to promote ==="
fixture build-first-fixture promote
: > "$FAKE/promote-inflight"; echo 2 > "$FAKE/promote-ticks"; mkdir "$W/build-first-fixture/node_modules"
run_promote build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "says it is waiting on run 777" has "promote run 777 in flight for ${ORIGIN_MAIN:0:7}"
check "waited to the run's conclusion (3 reads: two pending, one success)" [ "$(grep -c '^api repos/{owner}/{repo}/actions/runs/777' "$FAKE/calls")" -eq 3 ]
check "read production AFTER the run (deployment record answered)" has "promote run 777 finished: success"
check "NOTHING TO PROMOTE — the run shipped that sha" has "NOTHING TO PROMOTE"
check "no deploy ran on top of it" [ ! -f "$FAKE/npm-ran" ]
check "the run was not cancelled" [ ! -f "$FAKE/promote-cancelled" ]

echo "=== 11b. the in-flight promote run cannot be read: NAMED STOP, never cancelled, nothing deployed (22 Nov 2026) ==="
fixture build-first-fixture promote
: > "$FAKE/promote-inflight"; : > "$FAKE/promote-refused"; mkdir "$W/build-first-fixture/node_modules"
run_promote build-first-fixture
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP [RUN_UNREADABLE] names the run" has "NAMED STOP [RUN_UNREADABLE] promote.yml run 777"
check "the unread run was not cancelled" [ ! -f "$FAKE/promote-cancelled" ]
check "nothing deployed on top of it" [ ! -f "$FAKE/npm-ran" ]
rm -f "$FAKE/promote-refused"

echo "=== 12. no promote.yml on origin/main: nothing to wait for, promotes as before ==="
fixture build-first-fixture
: > "$FAKE/promote-inflight"; mkdir "$W/build-first-fixture/node_modules"   # a stray in-flight row is irrelevant: no promote.yml
run_promote build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "silent about promote runs" eval '! has "promote run"'
check "never listed promote.yml runs" eval '! grep -q "^run list --workflow promote.yml" "$FAKE/calls"'
check "deployed from a worktree at origin/main" grep -qx "head=$ORIGIN_MAIN" "$FAKE/npm-ran"
check "PROMOTED" has "PROMOTED"

echo "=== 13. the promote run never finishes: cancelled at the ceiling, NAMED STOP, nothing deployed ==="
fixture build-first-fixture promote
: > "$FAKE/promote-inflight"; : > "$FAKE/promote-hang"; echo 0 > "$FAKE/promote-last"; mkdir "$W/build-first-fixture/node_modules"
LAND_WAIT_FLOOR_SECS=0 run_promote build-first-fixture
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP names the run" has "NAMED STOP [PROMOTE_RUN_PAST_CEILING] promote.yml run 777"
check "the hung run was cancelled" [ -f "$FAKE/promote-cancelled" ]
check "nothing deployed on top of it" [ ! -f "$FAKE/npm-ran" ]

echo "=== 14. --run-e2e: the green e2e fires promote.yml; land waits for THAT run, does not double-deploy ==="
fixture build-first-fixture promote
: > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/build-first-fixture/node_modules"
run_promote build-first-fixture --run-e2e
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -5
check "waited for the in-flight e2e run 800, did not dispatch" [ "$(grep -c '^api repos/{owner}/{repo}/actions/runs/800' "$FAKE/calls")" -ge 1 ] && ! grep -q '^workflow run' "$FAKE/calls"
check "then waited for the promote run it triggered" has "promote run 777 in flight"
check "NOTHING TO PROMOTE — promote.yml shipped the head" has "shipped main's head ${ORIGIN_MAIN:0:7}"
check "no deploy from this side" [ ! -f "$FAKE/npm-ran" ]

# --- land <pr> after a LARGE change on an e2e route — 2 Oct 2026 --------------------------------------
# The e2e workflows are dispatch-only now, so after a merge nothing runs them unless land does. A
# large PR (measured by the `large` block, tests/test-land-large.sh) makes land run the suite on
# main's head and ship production only on green; a small one ships on the fast check (cases 16+).
# Here the merge commit IS main's head and the merge sha the fake answers is ORIGIN_MAIN.
echo "=== 15. a large PR (300 lines): land runs the suite, waits, and the repo's promote.yml ships it ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
printf '250 50 3\nworker/domain/sync.ts\napp/pages/Calendar.tsx\nshared/types.ts\n' > "$FAKE/pr-size"
: > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says why: 300 lines ≥ 200" has "LARGE CHANGE — 300 lines changed (+250/-50) ≥ 200"
check "staging deployed first, from the merge sha" grep -qx "head=$ORIGIN_MAIN" "$FAKE/npm-ran"
check "waited for the in-flight e2e run 800 (adopted, not doubled)" [ "$(grep -c '^api repos/{owner}/{repo}/actions/runs/800' "$FAKE/calls")" -ge 1 ] && ! grep -q '^workflow run' "$FAKE/calls"
check "then waited for the promote run the green fired" has "promote run 777 in flight"
check "LANDED — promote.yml shipped it" has "LANDED" && has "promote.yml shipped it to production"
check "never WAITING" eval '! has "WAITING"'

# --- a SMALL change ships on the fast check (owner, 2 Oct 2026) -----------------------------------
# Until this ruling case 16 pinned "WAITING, no production deploy". The new truth, pinned harder:
# production IS deployed, from the merge sha, with the reason printed and recorded — and only when
# the suite is not known red (16c-16e), which the old rule never had to ask.
echo "=== 16. a small PR (12 lines, worker only), no e2e verdict on main yet: ships on the fast check ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
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
check "…but --run-e2e forces the suite for any size" eval 'rm -f "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; run_land build-first-fixture --run-e2e; has "LARGE CHANGE — --run-e2e given" && has "LANDED" && grep -q "^api repos/{owner}/{repo}/actions/runs/800" "$FAKE/calls"'

echo "=== 16b. a small PR, the last e2e verdict on main is green: ships ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'success\t790\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says the last verdict was success" has "(last e2e verdict on main: success)"
check "production deployed" eval 'npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'
check "the suite was not run" suite_untouched

echo "=== 16c. a small PR, but e2e is KNOWN RED on main (no green run after it): NAMED STOP, production untouched ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'failure\t791\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP names the red run and its sha" has "NAMED STOP [E2E_KNOWN_RED] e2e is known red on main: run 791 on ${ORIGIN_MAIN:0:7} ended failure and no green run is newer"
check "…and the way out" has "Fix main, then: land 7 --run-e2e"
check "the plan line says blocked" has "staging blocked"
check "staging ran, production never" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN" ] && ! has "production <-"
check "no production deployment was recorded" [ ! -f "$FAKE/deploy-record" ]
check "the suite was not run behind her back" suite_untouched
check "never 'SMALL CHANGE — … shipped'" eval '! has "SMALL CHANGE —"'
check "the way out works: --run-e2e runs the suite and ships on green" eval 'rm -f "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; run_land build-first-fixture --run-e2e; [ "$RC" -eq 0 ] && has "LARGE CHANGE — --run-e2e given" && has "LANDED"'

echo "=== 16d. a small PR, the e2e history cannot be read: exit 75 'could not verify', never 'not red' ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo tls > "$FAKE/e2e-last"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "exit 75" [ "$RC" -eq 75 ]
check "says could not verify (network), and what" has "could not verify (network)" && has "the e2e history on main could not be read"
check "says the PR is merged and production untouched" has "#7 IS MERGED, staging runs ${ORIGIN_MAIN:0:7}; production untouched"
check "3 attempts at the read, bounded" [ "$(grep -c 'conclusion,headSha,databaseId,status' "$FAKE/calls")" -eq 3 ]
check "production never deployed" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN" ] && [ ! -f "$FAKE/deploy-record" ]
check "does NOT call it a known-red stop" eval '! has "E2E_KNOWN_RED"'

echo "=== 16e. a small PR whose own sha has a RED e2e run, though main's last verdict is green: blocked ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo failure > "$FAKE/e2e-on-sha"; printf 'success\t795\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "rc 1" [ "$RC" -eq 1 ]
check "NAMED STOP names this sha's red run" has "NAMED STOP [E2E_KNOWN_RED] e2e is known red on main: on ${ORIGIN_MAIN:0:7} ended failure"
check "production never deployed" [ "$(npm_log)" = "run deploy:staging head=$ORIGIN_MAIN" ]

echo "=== 16f. e2e already green on the exact sha: production at once, the size is never asked ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
echo success > "$FAKE/e2e-on-sha"; mkdir "$W/build-first-fixture/node_modules"   # no pr-size: a size read would fail
run_land build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "production deployed" eval 'npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'
check "no size read, no verdict read" eval '! grep -q "json additions,deletions,changedFiles" "$FAKE/calls" && ! grep -q "conclusion,headSha,databaseId,status" "$FAKE/calls"'
check "not called a small change" eval '! has "SMALL CHANGE"'

echo "=== 17. a large PR whose suite goes RED: NAMED STOP, staging deployed, production untouched ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
printf '3 0 1\nmigrations/0042_posts.sql\n' > "$FAKE/pr-size"
: > "$FAKE/e2e-pending"; : > "$FAKE/e2e-red"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "rc 1" [ "$RC" -eq 1 ]
check "a migration is large at any size" has "LARGE CHANGE — touches the schema or the browser-test contract (migrations/0042_posts.sql)"
check "NAMED STOP names the run and the reason" has "NAMED STOP [E2E_RED_AFTER_LARGE_CHANGE] e2e run 800"
check "staging ran once, production never" [ "$(grep -c 'head=' "$FAKE/npm-ran")" -eq 1 ] && ! has "production <-"
check "the size read that cannot be answered is large, fail closed" eval 'rm -f "$FAKE/pr-size" "$FAKE/e2e-red" "$FAKE/calls"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; run_land build-first-fixture; has "LARGE CHANGE — PR size unreadable" && has "LANDED"'
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
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; git -C "$W/pusher" rev-parse HEAD~1 > "$FAKE/prod-state"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says it judged what production has not seen" has "judged all 1 change(s) main carries past production $(cut -c1-7 "$FAKE/prod-state"): none is large"
check "shipped as a small change" has "SMALL CHANGE — $SMALL_REASON" && npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"

echo "=== 18b. a small PR behind a LARGE commit production has never seen: land runs the suite ==="
history build-first-fixture
small_pr; echo "$BASE" > "$FAKE/prod-state"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"
run_land build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "names the unproven commit and why it is large" has "LARGE CHANGE — main carries ${BIG:0:7} (big unproven change) past production ${BASE:0:7}, large and not yet proven: 250 lines changed (+250/-0) ≥ 200"
check "the suite ran (run 800 adopted)" grep -q '^api repos/{owner}/{repo}/actions/runs/800' "$FAKE/calls"
check "never shipped as a small change" eval '! has "SMALL CHANGE"'
check "LANDED on the green suite" has "LANDED"

echo "=== 18c. what production runs cannot be read: large, fail closed — the suite runs ==="
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; echo tls > "$FAKE/prod-state"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/build-first-fixture/node_modules"
run_land build-first-fixture
check "says so" has "LARGE CHANGE — what production runs could not be read"
check "the suite ran" grep -q '^api repos/{owner}/{repo}/actions/runs/800' "$FAKE/calls"
check "never shipped as a small change" eval '! has "SMALL CHANGE"'

echo "=== 18d. landing a merged PR that production already runs (or has passed): nothing deployed, never backwards ==="
history build-first-fixture
small_pr; : > "$FAKE/merged"; echo "$ORIGIN_MAIN" > "$FAKE/prod-state"
run_land build-first-fixture
check "rc 0" [ "$RC" -eq 0 ] || echo "$OUT" | tail -8
check "says production already runs it" has "production already runs ${ORIGIN_MAIN:0:7} (GitHub Deployment record). Nothing to deploy."
check "no deploy of any kind" [ -z "$(npm_log)" ]
MERGESHA="$FIRST"; export MERGESHA; rm -f "$FAKE/calls"
run_land build-first-fixture
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
check "one deploy, production, at the merge sha, through the vault" [ "$(npm_log)" = "run --loglevel=error vault:run -- npm run deploy:production head=$ORIGIN_MAIN" ]
check "recorded with the reason" grep -qF "land #7, $SMALL_REASON" "$FAKE/deploy-record"
check "LANDED — production (no 'staging and')" has "LANDED — #7 is merged, main is green, production run ${ORIGIN_MAIN:0:7}"
MERGESHA="2222222222222222222222222222222222222222"; export MERGESHA

# --- negative proofs for the 2 Oct 2026 rule: each guard removed in a copy of land -------------------
echo "=== negative proof: a land that ships past a known-red suite ==="
BROKEN="$W/land-past-red"; sed 's/^    success|none) printf/    success|none|failure) printf/' "$LAND" > "$BROKEN"
check "the broken copy differs" eval '! cmp -s "$LAND" "$BROKEN"'
fixture build-first-fixture promote
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
small_pr; printf 'failure\t791\t%s\n' "$ORIGIN_MAIN" > "$FAKE/e2e-last"; mkdir "$W/build-first-fixture/node_modules"
LAND="$BROKEN" run_land build-first-fixture
check "the broken land deployed production over a red suite (16c catches it)" eval 'npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'

echo "=== negative proof: a land that judges only the PR lets an unproven large commit ride out ==="
BROKEN="$W/land-pr-only"; sed '/REASON="\$(unshipped_large_reason /d' "$LAND" > "$BROKEN"
check "the broken copy differs" eval '! cmp -s "$LAND" "$BROKEN"'
history build-first-fixture
small_pr; echo "$BASE" > "$FAKE/prod-state"; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"
LAND="$BROKEN" run_land build-first-fixture
check "the broken land shipped the 250-line change as 'small', suite never run (18b catches it)" eval 'has "SMALL CHANGE" && ! grep -q "^api repos/{owner}/{repo}/actions/runs/800" "$FAKE/calls" && npm_log | grep -qx "run deploy:production head=$ORIGIN_MAIN"'

echo "=== negative proof: a boss-os route that does not name deploy.yml races it ==="
BROKEN="$W/land-boss-race"; sed 's/ ; E2E_WF="e2e" ; PROMOTE_WF="deploy.yml" ;;/ ; E2E_WF="e2e" ;;/' "$LAND" > "$BROKEN"
check "the broken copy differs" eval '! cmp -s "$LAND" "$BROKEN"'
fixture boss-os deploy
MERGESHA="$ORIGIN_MAIN" ; export MERGESHA
large_pr; : > "$FAKE/e2e-pending"; echo 1 > "$FAKE/promote-ticks"; mkdir "$W/boss-os/node_modules"
LAND="$BROKEN" run_land boss-os
check "the broken land deployed from the laptop while deploy.yml was shipping the same sha (20 catches it)" eval 'npm_log | grep -q "run deploy:production"'
MERGESHA="2222222222222222222222222222222222222222"; export MERGESHA

echo "=== 8b. the merge call gets GitHub's GraphQL 5xx (30 Oct 2026): exit 75, never a refusal ==="
fixture approvalprep; echo graphql500 > "$FAKE/merge"
run_land approvalprep
check "nothing merged" eval '[ ! -f "$FAKE/merged" ]'
check "exit 75 (could not verify), not 1" [ "$RC" -eq 75 ]
check "says could not verify (network)" has "could not verify (network)"
echo "=== 8c. a real refusal from GitHub on the merge call stays a refusal (rc 1) ==="
fixture approvalprep; echo refused > "$FAKE/merge"
run_land approvalprep
check "nothing merged" eval '[ ! -f "$FAKE/merged" ]'
check "rc 1, not 75" [ "$RC" -eq 1 ]
check "says merge failed" has "merge failed"
echo "=== negative proof: without the 5xx patterns, the GraphQL 5xx reads as a refusal again ==="
BROKEN5="$W/land-no-5xx"; sed 's/|Something went wrong while executing your query|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out//' "$LAND" > "$BROKEN5"
check "the broken copy differs (the patterns were removed)" eval '! cmp -s "$LAND" "$BROKEN5"'
fixture approvalprep; echo graphql500 > "$FAKE/merge"
LAND="$BROKEN5" run_land approvalprep
check "the broken land dies rc 1 on the 5xx (this harness catches it)" [ "$RC" -eq 1 ]

echo "=== negative proof: a land that does not wait for the promote run deploys on top of it ==="
BROKEN="$W/land-no-wait"; sed '/^  promote_wait_inflight$/d' "$LAND" > "$BROKEN"
check "the broken copy differs (the wait call was removed)" eval '! cmp -s "$LAND" "$BROKEN"'
fixture build-first-fixture promote
: > "$FAKE/promote-inflight"; echo 2 > "$FAKE/promote-ticks"; mkdir "$W/build-first-fixture/node_modules"
LAND="$BROKEN" run_promote build-first-fixture
check "the broken land raced the run and deployed (this harness catches it)" [ -f "$FAKE/npm-ran" ]
check "…without ever watching run 777" eval '! grep -q "^api repos/{owner}/{repo}/actions/runs/777" "$FAKE/calls"'

echo "=== 21. her bypass: ENG-CHECK DUE goes into the post-land-check list, never into HANDOFF.md, never a row on her Open Loops list ==="
# A stub intake stands where Boss OS would be, with a token and the real poster beside land, so a land that
# posted anything at all would be counted here. Every case below must leave it at zero posts.
cat > "$W/stub.mjs" <<'JS'
import http from "node:http"; import fs from "node:fs";
const dir = process.argv[2];
http.createServer((req, res) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => {
  fs.appendFileSync(`${dir}/posts.jsonl`, JSON.stringify({ url: req.url, body: b }) + "\n");
  res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ ok: true, data: { action: "opened" } }));
}); }).listen(0, "127.0.0.1", function () { fs.writeFileSync(`${dir}/port`, String(this.address().port)); });
JS
cp "$HERE/../open-loops.mjs" "$W/"   # the poster beside land: LAND_DIR is $W when land re-runs from its temp copy
cp "$HERE/../outcome-read" "$W/"   # the one reader, which land asks about every Outcome check (same LAND_DIR)
mkdir -p "$W/api"; node "$W/stub.mjs" "$W/api" & STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$W"' EXIT
for _ in $(seq 1 50); do [ -s "$W/api/port" ] && break; sleep 0.1; done
OPEN_LOOPS_URL="http://127.0.0.1:$(cat "$W/api/port")/intake"
export BOSS_OPEN_LOOPS_TOKEN=olt_test OPEN_LOOPS_URL
no_posts() { [ ! -s "$W/api/posts.jsonl" ]; }
# A home shaped like hers: HANDOFF.md with PINNED above, a Jobs list and a hand-written line in Today, a session
# note below (land must not touch it), and the list where the real one lives, ~/Work/tasks/post-land-checks.md.
# Each case starts with no list: land makes it.
mkdir -p "$W/hh"; HH="$W/hh/HANDOFF.md"; export LAND_DUE_FILE="$W/hh/Work/tasks/post-land-checks.md"
handoff_fixture() {
  rm -rf "$W/hh/Work"
  cat > "$HH" <<MD
# HANDOFF
## PINNED
PINNED-STAYS
## Today (temporary: in flight + done today; replaced each day, never stacked)
<!-- TODAY:START -->
<!-- day:$(date '+%Y-%m-%d') -->
_$(date '+%A %-d %B %Y')_

<!-- JOBS:START -->
### Jobs (open task sheets, from \`land-after --status\`)
- none open
<!-- JOBS:END -->

HAND-WRITTEN-STATUS

### Session note — earlier
<!-- compaction:x trigger:auto session:sess-1 -->
NOTE-BODY
<!-- TODAY:END -->
AFTER-TODAY-STAYS
MD
}
in_list() { local n; n="$(grep -c -- "$1" "$LAND_DUE_FILE" 2>/dev/null)"; echo "${n:-0}"; }   # no list yet is 0 lines
due_lines() { in_list '^- ENG-CHECK DUE '; }
due_list() { cat "$LAND_DUE_FILE" 2>/dev/null; }
today_region() { sed -n '/<!-- TODAY:START -->/,/<!-- TODAY:END -->/p' "$HH"; }
handoff_fixture; cp "$HH" "$W/hh/before"; fixture approvalprep
echo '{"files":[{"path":"src/client/boss/pages/Updates.tsx"}],"body":"Adds the page.","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=the important thing is our rules dont allow things to be built cheaply'
check "a changed screen with no review, under --owner: rc 0, merged" eval '[ "$RC" -eq 0 ] && merge_called'
check "…her words went on the PR" eval 'jq -r .body "$FAKE/pr-meta" | grep -q "^Owner override: \"the important thing is our rules"'
check "…NOTHING was posted to Open Loops (stub intake: zero posts)" no_posts
check "…ONE line, ENG-CHECK DUE <repo>#<pr> <merge sha>, in the list" eval '[ "$(due_lines)" -eq 1 ] && due_list | grep -q "^- ENG-CHECK DUE seq23/approvalprep#7 $MERGESHA — landed under her bypass "'
check "…the list and its folder did not exist: land made them, the line under a heading that says what the list is" eval 'head -1 "$LAND_DUE_FILE" | grep -qx "# Post-land checks" && tail -1 "$LAND_DUE_FILE" | grep -q "^- ENG-CHECK DUE seq23/approvalprep#7 " && [ -z "$(ls "$W/hh/Work/tasks" | grep -v "^post-land-checks.md$")" ]'
check "…HANDOFF.md is not touched: byte for byte as it was" cmp -s "$HH" "$W/hh/before"
check "…and land prints the line" has "ENG-CHECK DUE seq23/approvalprep#7 $MERGESHA"
# post-land-check (the real one) reads the line land just wrote, from the same file: its one batched engineering
# run is given this PR and merge sha. No verdict comes back from the stub, so the line stays DUE and it exits 1.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/hh/ai-calls"\n' "$W" > "$W/hh/ai-stub"; chmod +x "$W/hh/ai-stub"
export PLC_RC=0   # exported: it is read inside the eval of the check below
PATH="$BIN:$PATH" POST_LAND_DUE_FILE="$LAND_DUE_FILE" POST_LAND_AI_RUN="$W/hh/ai-stub" POST_LAND_LOG="$W/hh/plc.log" POST_LAND_LOCKS="$W/hh/plc-locks" \
  POST_LAND_NOTIFY=true POST_LAND_NOTICE=true POST_LAND_TASKS="$W/hh/plc-tasks" POST_LAND_SKIP="$W/hh/no-skip" \
  bash "$HERE/../post-land-check" </dev/null >"$W/hh/plc-out" 2>&1 || PLC_RC=$?
check "…post-land-check reads land's line from the list: its engineering run names this PR and merge sha" eval 'grep -q -- "- seq23/approvalprep#7 (merge $MERGESHA): landed under her bypass" "$W/hh/ai-calls"'
check "…with no verdict it exits 1 and the line stays DUE in the list (never DONE on silence)" eval '[ "$PLC_RC" -eq 1 ] && [ "$(due_lines)" -eq 1 ]'
# The real PreCompact hook rewrites Today on every compaction: the list is not its to rewrite, and Today names it.
printf '#!/bin/bash\necho "land-after: no open task sheets"\n' > "$W/hh/la-stub"; chmod +x "$W/hh/la-stub"
echo '{"session_id":"sess-2","trigger":"auto"}' | HOME="$W/hh" LAND_AFTER_BIN="$W/hh/la-stub" HANDOFF_TEST_SUMMARY="## In flight
- SESS-2-NOTE" bash "$HERE/../handoff-on-compact.sh" >/dev/null 2>&1
check "…a same-day compaction (the real hook) leaves the line in the list, and Today says 1 DUE and where" eval 'grep -q SESS-2-NOTE "$HH" && [ "$(due_lines)" -eq 1 ] && due_list | grep -q "^- ENG-CHECK DUE seq23/approvalprep#7 $MERGESHA " && [ "$(today_region | grep -c "^- \*\*Post-land checks\*\*: 1 DUE at .*~/Work/tasks/post-land-checks.md")" -eq 1 ] && ! grep -q "^- ENG-CHECK DUE " "$HH"'
fixture approvalprep; : > "$FAKE/merged"
echo '{"files":[{"path":"README.md"}],"body":"x\n\nOwner override: \"ship it now please\" (21 Nov 2026 10:00 CT)","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=ship it now please'
check "a re-run on the already-merged bypass PR: rc 0, still ONE line, nothing posted" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 1 ] && no_posts'
perl -pi -e 's{^- ENG-CHECK DUE (seq23/approvalprep#7 )}{- ENG-CHECK DONE $1}' "$LAND_DUE_FILE"   # the reviewer ran
run_land approvalprep '--owner=ship it now please'
check "a re-run after the check was marked DONE: rc 0, no new DUE line" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 0 ] && grep -c "^- ENG-CHECK DONE seq23/approvalprep#7 " "$LAND_DUE_FILE" | grep -qx 1'
# Fast PRs (her ruling 23 Nov 2026): EVERY land with no fresh reviewer's PASS joins the day's batched
# engineering check, not only her bypass. A PR a reviewer passed for its head needs none.
handoff_fixture; fixture approvalprep
run_land approvalprep
check "a Fast PR on green CI with no reviewer's PASS: rc 0, ONE ENG-CHECK DUE line saying so, nothing posted" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 1 ] && due_list | grep -q "^- ENG-CHECK DUE seq23/approvalprep#7 $MERGESHA — landed on green CI with no reviewer.s PASS (Fast PRs) " && no_posts'
check "…HANDOFF.md is not touched: byte for byte as it was" cmp -s "$HH" "$W/hh/before"
# Her ruling 24 Nov 2026: a small PR (under 200 changed lines) gets no engineering line, even with no
# reviewer or under her bypass; a size that cannot be read counts as big (the cases above have none).
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"Small fix.\nReview class: none — a small internal fix only","labels":[],"comments":[],"additions":120,"deletions":79}' > "$FAKE/pr-meta"
run_land approvalprep
check "a 199-line Fast PR with no reviewer: rc 0, merged, NO engineering line, says the live check still runs" eval '[ "$RC" -eq 0 ] && merge_called && [ "$(due_lines)" -eq 0 ] && has "engineering check: not needed (199 changed lines"'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"Small fix.\nReview class: none — a small internal fix only","labels":[],"comments":[],"additions":120,"deletions":80}' > "$FAKE/pr-meta"
run_land approvalprep
check "a 200-line Fast PR with no reviewer: ONE engineering line" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 1 ]'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"Small fix.\nReview class: none — a small internal fix only","labels":[],"comments":[],"additions":5,"deletions":5}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=ship it now please'
check "a 10-line PR under her bypass: rc 0, NO engineering line" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 0 ]'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"Review class: none — wording of a log line only\nShip-ready: PASS — hostile-review session_01REVIEW looked at the diff at @HEAD@; Engineering: PASS","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "a PR with a fresh reviewer's Ship-ready PASS for its head: rc 0, no ENG-CHECK line" eval '[ "$RC" -eq 0 ] && merge_called && [ "$(due_lines)" -eq 0 ]'
handoff_fixture; rm -f "$HH"; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
check "no HANDOFF.md at all: the line is still in the list, and land creates no HANDOFF.md" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 1 ] && [ ! -e "$HH" ]'
handoff_fixture; mkdir -p "$W/hh/Work/tasks"; printf '# Post-land checks\n\n- ENG-CHECK DUE seq23/other#3 0000000 — an older line\n- FORM-PROOF DONE seq23/approvalprep#7 1111111 — forms: x → https://x' > "$LAND_DUE_FILE"; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
check "a list that already has lines (the last with no line end): the new line is added at the END on its own line, the old ones exactly as they were" eval '[ "$RC" -eq 0 ] && [ "$(due_lines)" -eq 2 ] && tail -1 "$LAND_DUE_FILE" | grep -q "^- ENG-CHECK DUE seq23/approvalprep#7 $MERGESHA " && [ "$(sed -n 3p "$LAND_DUE_FILE")" = "- ENG-CHECK DUE seq23/other#3 0000000 — an older line" ] && [ "$(sed -n 4p "$LAND_DUE_FILE")" = "- FORM-PROOF DONE seq23/approvalprep#7 1111111 — forms: x → https://x" ] && [ "$(wc -l < "$LAND_DUE_FILE" | tr -d " ")" -eq 5 ]'
# Outage: the list cannot be written. The PR IS landed; the land must not end a silent 0.
handoff_fixture; mkdir -p "$W/hh/Work/tasks"; printf '# Post-land checks\n\n' > "$LAND_DUE_FILE"; chmod 555 "$W/hh/Work/tasks"; chmod 444 "$LAND_DUE_FILE"; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
chmod 755 "$W/hh/Work/tasks"; chmod 644 "$LAND_DUE_FILE"
check "the list unwritable: merged, but exit 4, never 0" eval 'merge_called && [ "$RC" -eq 4 ] && [ "$(due_lines)" -eq 0 ]'
check "…NAMED STOP [ENG_CHECK_NOT_NOTED] saying it LANDED, naming the list, with the line to add by hand" eval 'has "NAMED STOP [ENG_CHECK_NOT_NOTED] #7 LANDED" && has "was NOT written to $LAND_DUE_FILE" && has "  - ENG-CHECK DUE seq23/approvalprep#7 $MERGESHA"'
check "…and HANDOFF.md is still byte for byte as it was" cmp -s "$HH" "$W/hh/before"
check "…and still nothing posted to Open Loops" no_posts
# Failures under her bypass: refused with their STOPPED line, non-zero, no line, nothing posted.
handoff_fixture; fixture approvalprep; echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
echo '[{"name":"test","bucket":"fail","link":"https://github.com/o/r/actions/runs/555/job/1"}]' > "$FAKE/checks"
run_land approvalprep '--owner=land it deploy it finish it'
check "a red PR under --owner: refused rc 1 with STOPPED, not merged, no line, nothing posted" eval '[ "$RC" -eq 1 ] && has "STOPPED" && ! merge_called && [ "$(due_lines)" -eq 0 ] && no_posts'
fixture approvalprep; echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
echo 401 > "$FAKE/head"
echo '[{"name":"Cloudflare Pages","bucket":"pass","link":"https://dash.cloudflare.com/x/fe13d725-4827-bc619"}]' > "$FAKE/checks"
run_land approvalprep '--owner=land it deploy it finish it'
check "auth failed (401) under --owner: exit 75 'STOPPED: could not verify (auth)', not merged, no line, nothing posted" eval '[ "$RC" -eq 75 ] && has "STOPPED: could not verify (auth)" && ! merge_called && [ "$(due_lines)" -eq 0 ] && no_posts'
fixture approvalprep; echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
echo ratelimit > "$FAKE/checks"
OUT="$(cd "$W/approvalprep" && PATH="$BIN:$PATH" LAND_SURFACES="$HERE/../land-surfaces.json" LAND_RETRY_SECS=0 LAND_RATE_WAIT=1 bash "$LAND" 7 '--owner=land it deploy it finish it' 2>&1)"; RC=$?
check "rate limited past the bound under --owner: exit 75 'STOPPED: could not verify (rate limit)', not merged, no line, nothing posted" eval '[ "$RC" -eq 75 ] && has "STOPPED: could not verify (rate limit)" && ! merge_called && [ "$(due_lines)" -eq 0 ] && no_posts'
# The land path never names the intake at all (the old poster block is gone, not kept beside the new line).
check "land and land-after name no Open Loops poster or intake" eval '! grep -nE "open-loops|open_loops|/intake|OPEN_LOOPS" "$HERE/../land" "$HERE/../land-after"'
# Forms (her words 23 Nov 2026: "after theee fixes u need to test them"): no Forms: line is refused by name; her
# bypass records it instead of stopping; a touched form notes FORM-PROOF and starts post-land-check on that PR.
printf '#!/bin/bash\necho "$*" >> "%s/plc-calls"\n' "$W" > "$W/plc"; chmod +x "$W/plc"; export LAND_POST_CHECK="$W/plc"
form_lines() { in_list '^- FORM-PROOF DUE '; }
handoff_fixture; fixture approvalprep; rm -f "$W/plc-calls"; touch "$FAKE/no-forms"
echo '{"files":[{"path":"README.md"}],"labels":[],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "forms: no Forms: line on a PR whose diff touches no form is NOT stopped for it: no FORMS_UNDECLARED, no FORM-PROOF line, no form test" eval '! has "FORMS_UNDECLARED" && has "the diff touches no form, so no form test runs" && [ "$(form_lines)" -eq 0 ] && [ ! -s "$W/plc-calls" ]'
handoff_fixture; fixture approvalprep; rm -f "$W/plc-calls"; touch "$FAKE/no-forms"
echo '{"files":[{"path":"README.md"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
sleep 1
check "forms under her bypass, diff touches no form: lands rc 0, NO FORM-PROOF line, no form test started" eval '[ "$RC" -eq 0 ] && merge_called && [ "$(form_lines)" -eq 0 ] && has "the diff touches no form, so no form test runs" && [ ! -s "$W/plc-calls" ]'
# The same bypass on a PR whose head adds a page with a <form>: the form test is owed and started.
handoff_fixture; fixture approvalprep; rm -f "$W/plc-calls"; touch "$FAKE/no-forms"
git -C "$W/pusher" checkout -q pr; mkdir -p "$W/pusher/site"; echo '<form method="post" action="/api/lead"></form>' > "$W/pusher/site/contact.html"
git -C "$W/pusher" add -A; git -C "$W/pusher" commit -qm "a form"; HEADSHA="$(git -C "$W/pusher" rev-parse HEAD)"; export HEADSHA
git -C "$W/pusher" push -q -f origin HEAD:refs/pull/7/head; git -C "$W/pusher" checkout -q main
echo '{"files":[{"path":"site/contact.html"}],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
sleep 1
check "forms under her bypass, diff touches a form: ONE FORM-PROOF DUE line naming the file" eval '[ "$RC" -eq 0 ] && merge_called && [ "$(form_lines)" -eq 1 ] && due_list | grep -q "^- FORM-PROOF DUE seq23/approvalprep#7 $MERGESHA — forms: undeclared (landed under her bypass; the diff touches site/contact.html)"'
check "…and post-land-check was started for that PR alone" eval 'grep -qx -- "--now seq23/approvalprep#7" "$W/plc-calls"'
# The same PR with NO bypass and no Forms: line: the diff touches a form, so this one IS stopped, by name, not merged.
handoff_fixture; fixture approvalprep; rm -f "$W/plc-calls"; touch "$FAKE/no-forms"
git -C "$W/pusher" checkout -q pr; mkdir -p "$W/pusher/site"; echo '<form method="post" action="/api/lead"></form>' > "$W/pusher/site/contact.html"
git -C "$W/pusher" add -A; git -C "$W/pusher" commit -qm "a form"; HEADSHA="$(git -C "$W/pusher" rev-parse HEAD)"; export HEADSHA
git -C "$W/pusher" push -q -f origin HEAD:refs/pull/7/head; git -C "$W/pusher" checkout -q main
echo '{"files":[{"path":"site/contact.html"}],"labels":[],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "forms: no Forms: line on a PR whose diff touches a form is refused rc 1 by NAMED STOP [FORMS_UNDECLARED] naming the file, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [FORMS_UNDECLARED] the diff touches a form (site/contact.html)" && has "Forms: none — " && ! merge_called && [ "$(form_lines)" -eq 0 ]'
handoff_fixture; fixture approvalprep; rm -f "$W/plc-calls"; touch "$FAKE/no-forms"
echo '{"files":[{"path":"functions/api/lead.js"}],"labels":[],"body":"Forms: request form — preview: TEST submission 200, row recTEST stored\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the lead handler fix | tests/lead.test.js goes red |","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
sleep 1
check "a touched form proven on the preview: lands rc 0, FORM-PROOF DUE names it, post-land-check started" eval '[ "$RC" -eq 0 ] && merge_called && due_list | grep -q "^- FORM-PROOF DUE seq23/approvalprep#7 $MERGESHA — forms: request form;" && grep -qx -- "--now seq23/approvalprep#7" "$W/plc-calls"'
handoff_fixture; fixture approvalprep; rm -f "$W/plc-calls"
run_land approvalprep
sleep 1
check "Forms: none lands with no FORM-PROOF line and starts nothing" eval '[ "$RC" -eq 0 ] && [ "$(form_lines)" -eq 0 ] && [ ! -f "$W/plc-calls" ]'
rm -f "$FAKE/no-forms"; unset LAND_POST_CHECK
# Outcome and Not built (her order 24 Nov 2026, after Noelle landed green and acted on 0 of 11 decisions): no Outcome,
# no Not built, an Outcome with no check or no expect, and "Outcome: none" on a plist are each refused by name and
# not merged; a real Outcome lands and writes ONE OUTCOME-CHECK DUE line carrying the task slug; her bypass is never
# blocked by them and still writes a check the checker infers. The Not built section is printed word for word.
outcome_lines() { in_list '^- OUTCOME-CHECK DUE '; }
OMP='\n## Mutation proof\n| Mutation | Red |\n|---|---|\n| undo the plist schedule fix | tests/test-launchd-central.sh goes red |'
export LAND_TODAY=2026-11-24 LAND_TASK=noelle-levers
handoff_fixture; fixture approvalprep; touch "$FAKE/no-outcome"
echo '{"files":[{"path":"README.md"}],"labels":[],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "outcome: no Outcome line is refused rc 1 by NAMED STOP [OUTCOME_UNDECLARED] saying what to add, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [OUTCOME_UNDECLARED]" && has "Outcome: none — " && has "expect: >= <N>" && ! merge_called && [ "$(outcome_lines)" -eq 0 ]'
handoff_fixture; fixture approvalprep; rm -f "$FAKE/no-outcome"; touch "$FAKE/no-notbuilt"
echo '{"files":[{"path":"README.md"}],"labels":[],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "not built: no '## Not built' section is refused rc 1 by NAMED STOP [NOT_BUILT_UNDECLARED], not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [NOT_BUILT_UNDECLARED]" && has "Nothing cut." && ! merge_called'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"README.md"}],"labels":[],"body":"Fixes it.\n\n## Not built\n\n## Mutation proof\nnone","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "not built: an EMPTY '## Not built' section is refused the same way" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [NOT_BUILT_UNDECLARED]" && ! merge_called'
handoff_fixture; fixture approvalprep; rm -f "$FAKE/no-notbuilt"
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"Moves the run to 23:15.'"$OMP"'","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "outcome: 'Outcome: none' on a PR that changes a launchd plist is refused by name, naming the plist, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [OUTCOME_UNDECLARED]" && has "launchd/com.seq.noelle.plist" && ! merge_called && [ "$(outcome_lines)" -eq 0 ]'
handoff_fixture; fixture approvalprep; touch "$FAKE/no-outcome"
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"Outcome: Noelle acts on her decisions — check: grep -c acted ~/Library/Logs/noelle.log'"$OMP"'","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "outcome: an Outcome with a check but no 'expect: >= N' is refused, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [OUTCOME_UNDECLARED]" && has "no '"'"'expect: >= <N>'"'"'" && ! merge_called'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"Outcome: Noelle acts on her decisions every night'"$OMP"'","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "outcome: an Outcome with no 'check:' command is refused, not merged" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [OUTCOME_UNDECLARED]" && has "no '"'"'check: <one read and its pipes>'"'"'" && ! merge_called'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"Outcome: Noelle acts on her decisions — check: grep -c acted ~/Library/Logs/noelle.log — expect: >= 3\n\n## Not built\n- the job-target lever (G1)\n- G19, the sales reader'"$OMP"'","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "outcome: a real Outcome lands rc 0 and writes ONE OUTCOME-CHECK DUE line with the task slug, day, floor, outcome and check" eval '[ "$RC" -eq 0 ] && merge_called && [ "$(outcome_lines)" -eq 1 ] && due_list | grep -qF -- "- OUTCOME-CHECK DUE seq23/approvalprep#7 $MERGESHA — task:noelle-levers by:2026-11-25 expect:>=3 — outcome: Noelle acts on her decisions — check: grep -c acted ~/Library/Logs/noelle.log"'
check "…and prints the Not built section word for word between its markers" eval 'sed -n "/^--- NOT BUILT (PR #7, word for word) ---$/,/^--- END NOT BUILT ---$/p" <<<"$OUT" | sed "1d;\$d" | diff - <(printf "%s\n" "- the job-target lever (G1)" "- G19, the sales reader") >/dev/null'
run_land approvalprep
check "…a re-run on the merged PR adds no second OUTCOME-CHECK line" eval '[ "$(outcome_lines)" -eq 1 ]'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"Outcome: Noelle acts — check: echo ok && curl -s -d x=1 https://e.x/api | wc -l — expect: >= 1\n\n## Not built\nNothing cut.'"$OMP"'","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep
check "outcome: a check that is more than one read (curl -d after &&) is refused rc 1 by NAMED STOP [OUTCOME_CHECK_NOT_READ_ONLY], naming it, not merged, no DUE line" eval '[ "$RC" -eq 1 ] && has "NAMED STOP [OUTCOME_CHECK_NOT_READ_ONLY]" && has "& or &&" && ! merge_called && [ "$(outcome_lines)" -eq 0 ]'
handoff_fixture; fixture approvalprep
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"Outcome: Noelle acts — check: gh issue create -t x -b y — expect: >= 1\n\n## Not built\nNothing cut.'"$OMP"'","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
check "…under her bypass: never blocked, says the check was refused, and writes no DUE line carrying that command" eval '[ "$RC" -eq 0 ] && merge_called && has "outcome check refused, never run" && has "Outcome: UNDECLARED (owner bypass)" && ! due_list | grep -q "gh issue create"'
handoff_fixture; fixture approvalprep; touch "$FAKE/no-outcome" "$FAKE/no-notbuilt"
echo '{"files":[{"path":"launchd/com.seq.noelle.plist"}],"labels":[],"body":"","comments":[]}' > "$FAKE/pr-meta"
run_land approvalprep '--owner=land it deploy it finish it'
check "outcome under her bypass: never blocked; records UNDECLARED and writes a check the checker infers" eval '[ "$RC" -eq 0 ] && merge_called && has "Outcome: UNDECLARED (owner bypass)" && due_list | grep -qF -- "- OUTCOME-CHECK DUE seq23/approvalprep#7 $MERGESHA — task:noelle-levers by:2026-11-25 expect:infer — outcome: UNDECLARED (owner bypass) — check: infer" && sed -n "/^--- NOT BUILT/,/^--- END/p" <<<"$OUT" | grep -qx "UNDECLARED (owner bypass)"'
rm -f "$FAKE/no-outcome" "$FAKE/no-notbuilt"; unset LAND_TODAY LAND_TASK
unset BOSS_OPEN_LOOPS_TOKEN OPEN_LOOPS_URL
export LAND_DUE_FILE="$W/post-land-checks.md"

# Rule 0: this must have examined something.
[ "$passes" -ge 160 ] || { echo "FAIL: only $passes checks ran — the harness examined too little"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-flow: $fails failure(s), $passes passed"; exit 1; }
echo "test-land-flow: $passes checks passed — land leaves her tree alone, never reads could-not-check as an answer, never races a repo's own promote run, runs the suite itself after a large change, and ships a small one on the fast check unless the suite is known red"
