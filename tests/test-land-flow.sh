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
  "run view 555 "*) echo "$HEADSHA"; exit 0 ;;
  "pr view "*mergeStateStatus*) echo "MERGEABLE/CLEAN"; exit 0 ;;
  "pr merge "*) : > "$FAKE_DIR/merged"; exit 0 ;;
  "pr view "*"--json state "*) merged && echo MERGED || echo OPEN; exit 0 ;;
  "pr view "*mergeCommit*) echo "$MERGESHA"; exit 0 ;;
  "run list "*) echo 900; exit 0 ;;
  "run watch "*) exit 0 ;;
  "run view 900 "*conclusion*) echo success; exit 0 ;;
  "run view 900 "*status*) echo completed; exit 0 ;;
  "api "*) exit 0 ;;   # no Cloudflare check-runs posted
  *) echo "fake gh: unhandled: $a" >&2; exit 1 ;;
esac
SH
chmod +x "$BIN"/*
export FAKE_DIR="$FAKE" HEADSHA MERGESHA

# fixture NAME: a bare origin whose main has moved on (the merge) past a clone at $W/NAME, and the
# merge commit rewrites artifacts/a.json — the file the owner has dirty in case 1.
fixture() {
  local name="$1"
  rm -rf "$W/origin.git" "${W:?}/${name:?}" "$W/pusher" "$FAKE"; mkdir -p "$FAKE"
  git init -q --bare -b main "$W/origin.git"
  git clone -q "$W/origin.git" "$W/pusher" 2>/dev/null
  mkdir -p "$W/pusher/artifacts"; echo '{"v":1}' > "$W/pusher/artifacts/a.json"; echo one > "$W/pusher/other.txt"
  echo '{"lockfileVersion":3}' > "$W/pusher/package-lock.json"   # identical lockfile: deploy_at shares her node_modules
  git -C "$W/pusher" add artifacts other.txt package-lock.json; git -C "$W/pusher" commit -qm base; git -C "$W/pusher" push -q origin HEAD:main
  git clone -q "$W/origin.git" "$W/$name"
  echo '{"v":2}' > "$W/pusher/artifacts/a.json"; git -C "$W/pusher" commit -qam "the merged PR"; git -C "$W/pusher" push -q origin HEAD:main
  ORIGIN_MAIN="$(git -C "$W/pusher" rev-parse HEAD)"
}
run_land() { # name -> sets OUT, RC
  OUT="$(cd "$W/$1" && PATH="$BIN:$PATH" LAND_RETRY_SECS=0 PAGES_APPEAR_SECS=0 bash "$LAND" 7 2>&1)"; RC=$?
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

# Rule 0: this must have examined something.
[ "$passes" -ge 30 ] || { echo "FAIL: only $passes checks ran — the harness examined too little"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-flow: $fails failure(s), $passes passed"; exit 1; }
echo "test-land-flow: $passes checks passed — land leaves her tree alone and never reads could-not-check as an answer"
