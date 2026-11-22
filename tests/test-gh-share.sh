#!/bin/bash
# ~/bin/gh, the shared GitHub allowance (22 Nov 2026: agents polling one by one spent the account's 5,000
# REST calls an hour twice in a morning, and land could not read CI). Each case drives the wrapper in
# front of a fake gh that counts its calls, and fails if the wrapper is removed or broken.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/fake-gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
if [ "$1 $2" = "api rate_limit" ]; then [ -n "${FAKE_RL_FAIL:-}" ] && exit 1; echo "$FAKE_REM $FAKE_RESET ${FAKE_GQL_REM:-4000} ${FAKE_GQL_RESET:-$FAKE_RESET}"; exit 0; fi
# a run that finishes on its FAKE_DONE_AT-th look, and checks that stop pending on theirs
polls=$(grep -c "^$1 $2" "$FAKE_LOG")
if [ "$1 $2" = "run view" ] && [ -n "${FAKE_DONE_AT:-}" ]; then
  case " $* " in *" --json "*) [ "$polls" -ge "$FAKE_DONE_AT" ] && echo "completed ${FAKE_CONCL:-success}" || echo "in_progress "; exit 0 ;;
                 *" --exit-status "*) echo "run done"; [ "${FAKE_CONCL:-success}" = success ]; exit $? ;; esac
fi
if [ "$1 $2" = "pr checks" ] && [ -n "${FAKE_DONE_AT:-}" ]; then
  if [ "$polls" -lt "$FAKE_DONE_AT" ]; then printf 'lint\t%s\t1s\turl\t\nbuild\tpending\t0\turl\t\n' "${FAKE_EARLY:-pass}"; exit 8; fi
  printf 'lint\tpass\t1s\turl\t\nbuild\t%s\t2s\turl\t\n' "${FAKE_CONCL:-pass}"; [ "${FAKE_CONCL:-pass}" = pass ] && exit 0 || exit 1
fi
[ -n "${FAKE_SLOW:-}" ] && [ "$1" = pr ] && [ "$2" = view ] && sleep "$FAKE_SLOW"   # a read in flight
n=$(wc -l < "$FAKE_LOG" | tr -d ' ')
echo "answer-$n for $*"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/fake-gh"
export GH_SHARE_REAL="$T/fake-gh" FAKE_LOG="$T/calls" FAKE_REM=4000 FAKE_RESET=$(( $(date +%s) + 600 ))
pass=0
fail() { echo "FAIL: $*"; exit 1; }
fresh() { rm -rf "$T/share" "$T/calls"; touch "$T/calls"; export GH_SHARE_DIR="$T/share"; unset GH_SHARE_WATCH_SECS FAKE_DONE_AT FAKE_CONCL FAKE_EARLY FAKE_RL_FAIL GH_SHARE_TTL GH_SHARE_FLOOR GH_SHARE_MAX_WAIT GH_SHARE_PER_CALLER GH_SHARE_UNTIL GH_SHARE_SWEEP_EVERY FAKE_RC FAKE_GQL_REM FAKE_GQL_RESET FAKE_SLOW; export FAKE_REM=4000 FAKE_RESET=$(( $(date +%s) + 600 )); }
real_calls() { grep -vc '^api rate_limit' "$T/calls"; }
GH_UNDER_TEST="${GH_SHARE_UNDER_TEST:-$HERE/gh}"
gh() { "$GH_UNDER_TEST" "$@" </dev/null; }

# 1. ten agents asking the same thing inside the TTL cost GitHub one call
fresh
first="$(gh run view 123 --json conclusion)"; for _ in 1 2 3 4 5 6 7 8 9; do again="$(gh run view 123 --json conclusion)"; done
[ "$(real_calls)" = 1 ] || fail "10 identical reads made $(real_calls) GitHub calls, want 1"
[ "$first" = "$again" ] || fail "a cached read answered differently: '$first' vs '$again'"
pass=$((pass + 1))

# 2. never served stale past its TTL: an expired answer is fetched again, and a failed fetch is returned
fresh; export GH_SHARE_TTL=1
gh pr checks 7 >/dev/null; sleep 2
out="$(FAKE_RC=1 gh pr checks 7)"; rc=$?
[ "$rc" = 1 ] || fail "an expired entry with a failed fetch returned rc $rc, want the failure (1)"
grep -q answer-1 <<<"$out" && fail "the old (expired) answer was served after a failed fetch"
out="$(gh pr checks 7)"; grep -q answer-1 <<<"$out" && fail "the failure left the old answer in the cache"
pass=$((pass + 1))

# 3. pending checks (rc 8) are a real answer and are shared; a failed list (rc 1) is not kept
fresh
FAKE_RC=8 gh pr checks 9 >/dev/null; rc1=$?; gh pr checks 9 >/dev/null; rc2=$?
[ "$rc1$rc2" = 88 ] && [ "$(real_calls)" = 1 ] || fail "pending checks not shared with their rc 8 ($rc1/$rc2, $(real_calls) calls)"
FAKE_RC=1 gh pr checks 10 >/dev/null; gh pr checks 10 >/dev/null
[ "$(real_calls)" = 3 ] || fail "a failed answer was cached ($(real_calls) calls, want 3)"
pass=$((pass + 1))

# 4. allowance at the floor: a read waits for the reset in one bounded sleep, then runs
fresh; export FAKE_REM=0 FAKE_RESET=$(( $(date +%s) - 3 ))   # reset is "now" (+5 s margin -> ~2 s wait)
t0=$(date +%s); out="$(gh api repos/x/y/actions/runs 2>"$T/err")"; rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && grep -q '^answer' <<<"$out" || fail "the held read did not run after the reset (rc $rc)"
[ $((t1 - t0)) -ge 1 ] || fail "the read at 0 allowance did not wait for the reset"
grep -q 'waits' "$T/err" || fail "the wait was not said on stderr"
pass=$((pass + 1))

# 5. a write is never held: a merge at 0 allowance goes straight through
fresh; export FAKE_REM=0 FAKE_RESET=$(( $(date +%s) + 3000 ))
t0=$(date +%s); timeout 10 "$GH_UNDER_TEST" pr merge 5 --squash </dev/null >/dev/null; rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 1 ] || fail "a merge was held at a spent allowance (rc $rc, $((t1 - t0)) s)"
grep -q '^pr merge 5' "$T/calls" || fail "the merge never reached gh"
gh api -X POST repos/x/y/dispatches -f event_type=go >/dev/null || fail "a dispatch (POST) was held"
pass=$((pass + 1))

# 6. a reset beyond the bounded wait is a named stop, exit 75, never a hang or a fake answer
fresh; export FAKE_REM=0 FAKE_RESET=$(( $(date +%s) + 3000 )) GH_SHARE_MAX_WAIT=60
out="$(timeout 10 "$GH_UNDER_TEST" run list </dev/null 2>"$T/err")"; rc=$?
[ "$rc" = 75 ] && grep -q 'NAMED STOP \[GH_ALLOWANCE_SPENT\]' "$T/err" && [ -z "$out" ] || fail "spent allowance: rc $rc, want 75 + named stop and no answer"
pass=$((pass + 1))

# 7. a watcher polls THROUGH the wrapper (22 Nov 2026: an exec'd watch polled GitHub uncounted): the real gh
#    never sees "run watch" or "--watch", every poll is a logged read, the interval floor holds, and gh's
#    exit codes come back (a failed run with --exit-status, failed checks, --fail-fast on an early fail)
fresh; export GH_SHARE_WATCH_SECS=1 GH_SHARE_TTL=0 FAKE_DONE_AT=3
t0=$(date +%s); gh run watch 55 --interval 0 >/dev/null; rc=$?; t1=$(date +%s)
grep -qE 'run watch|--watch|--interval' "$T/calls" && fail "the real gh was handed a watch: $(cat "$T/calls")"
[ "$rc" = 0 ] && [ "$(grep -c '^run view 55 --json' "$T/calls")" = 3 ] || fail "run watch: rc $rc, $(grep -c '^run view 55 --json' "$T/calls") polls, want 0 and 3"
[ "$(grep -c ' miss run view' "$T/share/calls.log")" = 4 ] || fail "run watch polls not each logged as a read: $(cat "$T/share/calls.log")"
[ $((t1 - t0)) -ge 2 ] || fail "--interval 0 was not raised to the floor (3 polls in $((t1 - t0)) s)"
fresh; export GH_SHARE_WATCH_SECS=1 GH_SHARE_TTL=0 FAKE_DONE_AT=2 FAKE_CONCL=failure
gh run watch 56 --exit-status >/dev/null; rc=$?
[ "$rc" = 1 ] || fail "run watch --exit-status on a failed run returned $rc, want 1"
fresh; export GH_SHARE_WATCH_SECS=1 GH_SHARE_TTL=0 FAKE_DONE_AT=3
out="$(gh pr checks 3 --watch --interval 5)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^pr checks 3$' "$T/calls")" = 3 ] && grep -q 'build.pass' <<<"$out" || fail "pr checks --watch: rc $rc, $(grep -c '^pr checks 3$' "$T/calls") polls: $out"
[ "$(grep -c ' miss pr checks' "$T/share/calls.log")" = 3 ] || fail "pr checks --watch polls not each logged as a read"
fresh; export GH_SHARE_WATCH_SECS=1 GH_SHARE_TTL=0 FAKE_DONE_AT=3 FAKE_CONCL=fail
gh pr checks 4 --watch >/dev/null; rc=$?; [ "$rc" = 1 ] || fail "pr checks --watch on failed checks returned $rc, want 1"
fresh; export GH_SHARE_WATCH_SECS=1 GH_SHARE_TTL=0 FAKE_DONE_AT=5 FAKE_EARLY=fail
gh pr checks 5 --watch --fail-fast >/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(grep -c '^pr checks 5$' "$T/calls")" = 1 ] || fail "--fail-fast did not stop at the first fail (rc $rc, $(grep -c '^pr checks 5$' "$T/calls") polls)"
fresh; export GH_SHARE_WATCH_SECS=1 FAKE_DONE_AT=9 FAKE_REM=0 FAKE_RESET=$(( $(date +%s) + 3000 )) GH_SHARE_MAX_WAIT=60
timeout 10 "$GH_UNDER_TEST" run watch 57 </dev/null >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 75 ] && grep -q GH_ALLOWANCE_SPENT "$T/err" && [ "$(real_calls)" = 0 ] || fail "a watch at a spent allowance polled anyway (rc $rc, $(real_calls) calls)"
pass=$((pass + 1))

# 8. one poller cannot take more than its share: over it, it waits (bounded) before GitHub sees it
fresh; export GH_SHARE_PER_CALLER=2 GH_SHARE_TTL=0 GH_SHARE_MAX_WAIT=2
( gh api a >/dev/null; gh api b >/dev/null; gh api c >/dev/null 2>"$T/err" )
grep -q 'its share is 2' "$T/err" || fail "the third read of a 2-call share was not held"
pass=$((pass + 1))

# 9. fail toward working: no cache dir -> plain pass-through; GH_SHARE_OFF=1 -> plain pass-through
fresh; mkdir -p "$T/ro"; chmod 500 "$T/ro"; export GH_SHARE_DIR="$T/ro/share"
gh run view 1 >/dev/null && gh run view 1 >/dev/null; chmod 700 "$T/ro"
[ "$(real_calls)" = 2 ] || fail "with no cache dir the reads did not pass through ($(real_calls) calls)"
fresh; GH_SHARE_OFF=1 gh run view 1 >/dev/null; GH_SHARE_OFF=1 gh run view 1 >/dev/null
[ "$(real_calls)" = 2 ] || fail "GH_SHARE_OFF=1 still cached"
pass=$((pass + 1))

# 10. every call is logged, so calls per hour are measured
fresh; gh run view 2 >/dev/null; gh run view 2 >/dev/null; gh pr merge 2 >/dev/null
[ "$(awk '{print $3}' "$T/share/calls.log" | sort | paste -sd, -)" = "hit,miss,write" ] || fail "calls.log: $(cat "$T/share/calls.log")"
pass=$((pass + 1))

# 11. a write drops every kept answer: land's "did it merge?" read after the merge reaches GitHub
fresh
gh pr view 6 --json state >/dev/null; gh pr view 6 --json state >/dev/null
[ "$(real_calls)" = 1 ] || fail "the second read inside the TTL was not shared ($(real_calls) calls)"
FAKE_RC=3 gh pr merge 6 --squash >/dev/null; rc=$?
[ "$rc" = 3 ] || fail "the write's own exit code was lost (rc $rc, want 3)"
out="$(gh pr view 6 --json state)"
[ "$(real_calls)" = 3 ] && ! grep -q answer-1 <<<"$out" || fail "a read after a merge was answered from before it ($(real_calls) calls): $out"
pass=$((pass + 1))

# 12. (review F1) the branch is in the key: two worktrees of one repo on different branches never share
#     "this branch's PR" (land with no number picks its PR this way)
fresh; git init -q --bare "$T/remote.git"
for b in feat-a feat-b; do git clone -q "$T/remote.git" "$T/$b" 2>/dev/null; git -C "$T/$b" checkout -q -b "$b"; done
a1="$(cd "$T/feat-a" && gh pr view --json number -q .number)"; b1="$(cd "$T/feat-b" && gh pr view --json number -q .number)"
[ "$(real_calls)" = 2 ] && [ "$a1" != "$b1" ] || fail "feat-b was answered with feat-a's PR ($(real_calls) calls: '$a1' / '$b1')"
(cd "$T/feat-a" && gh pr view --json number -q .number >/dev/null)
[ "$(real_calls)" = 2 ] || fail "the same branch asking again inside the TTL was not shared ($(real_calls) calls)"
pass=$((pass + 1))

# 13. the GraphQL budget is guarded too: pr reads wait on it, REST reads do not; far away -> stop, rc 75
fresh; export FAKE_GQL_REM=0 FAKE_GQL_RESET=$(( $(date +%s) - 3 ))
gh pr checks 21 >/dev/null 2>"$T/err"; grep -q 'graphql allowance is down to 0' "$T/err" || fail "a pr read at a spent GraphQL budget did not wait: $(cat "$T/err")"
gh run view 21 >/dev/null 2>"$T/err"; [ ! -s "$T/err" ] || fail "a REST read waited on the GraphQL budget: $(cat "$T/err")"
fresh; export FAKE_GQL_REM=0 FAKE_GQL_RESET=$(( $(date +%s) + 3000 )) GH_SHARE_MAX_WAIT=60
out="$(timeout 10 "$GH_UNDER_TEST" pr view 3 </dev/null 2>"$T/err")"; rc=$?
[ "$rc" = 75 ] && [ -z "$out" ] && grep -q 'rate limit: NAMED STOP \[GH_ALLOWANCE_SPENT\]' "$T/err" || fail "spent GraphQL budget: rc $rc, want 75 + 'rate limit:' stop"
pass=$((pass + 1))

# 14. one owner of waiting: a wait that would pass the caller's deadline (GH_SHARE_UNTIL) is not slept;
#     it comes back at once as "rate limit:" (land matches that) with rc 75, for the reset and the share
fresh; export FAKE_REM=0 FAKE_RESET=$(( $(date +%s) + 120 )) GH_SHARE_UNTIL=$(( $(date +%s) + 10 ))
t0=$(date +%s); out="$(timeout 20 "$GH_UNDER_TEST" run list </dev/null 2>"$T/err")"; rc=$?; t1=$(date +%s)
[ "$rc" = 75 ] && [ $((t1 - t0)) -le 2 ] && grep -q "^rate limit: .*past the caller's deadline" "$T/err" || fail "a reset past GH_SHARE_UNTIL: rc $rc after $((t1 - t0)) s: $(cat "$T/err")"
fresh; export GH_SHARE_PER_CALLER=1 GH_SHARE_TTL=0 GH_SHARE_UNTIL=$(( $(date +%s) + 10 ))
# (both reads under one `timeout`: one process group, so one caller; a broken cap is red in 20 s, not a hang)
t0=$(date +%s); timeout 20 bash -c '"$1" api a </dev/null >/dev/null; "$1" api b </dev/null >/dev/null 2>"$2"; echo $? > "$3"' _ "$GH_UNDER_TEST" "$T/err" "$T/rc"; t1=$(date +%s)
[ "$(cat "$T/rc")" = 75 ] && [ $((t1 - t0)) -le 3 ] && grep -q '^rate limit: .*its share is 1' "$T/err" || fail "a share hold past GH_SHARE_UNTIL: rc $(cat "$T/rc") after $((t1 - t0)) s"
pass=$((pass + 1))

# 15. calls.log keeps the last 48 h, not forever
fresh; mkdir -p "$T/share"; { echo "$(( $(date +%s) - 259200 )) 1 miss old"; echo "$(( $(date +%s) - 3600 )) 1 miss recent"; } > "$T/share/calls.log"
GH_SHARE_SWEEP_EVERY=1 gh run view 15 >/dev/null
! grep -q ' old$' "$T/share/calls.log" && grep -q ' recent$' "$T/share/calls.log" && grep -q ' miss run view' "$T/share/calls.log" || fail "calls.log not trimmed to 48 h: $(cat "$T/share/calls.log")"
pass=$((pass + 1))

# 16. a read in flight across a write is returned but not kept (it may be from before the merge)
fresh
( FAKE_SLOW=2 gh pr view 16 --json state > "$T/slow" 2>&1 ) & slow=$!
sleep 1; gh pr merge 16 --squash >/dev/null; wait "$slow"
gh pr view 16 --json state >/dev/null
grep -qx "answer-[0-9]* for pr view 16 --json state" "$T/slow" || fail "the read in flight across the merge lost its own answer: $(cat "$T/slow")"
[ "$(real_calls)" = 3 ] || fail "a read that straddled a merge was kept and served after it ($(real_calls) calls, want 3)"
pass=$((pass + 1))

# 17. a new commit in this checkout (a push) is a new key: the answer from before it is never reused
fresh; git init -q "$T/c17"; git -C "$T/c17" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
(cd "$T/c17" && gh pr checks >/dev/null)
git -C "$T/c17" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
(cd "$T/c17" && gh pr checks >/dev/null)
[ "$(real_calls)" = 2 ] || fail "checks after a new commit were answered from before it ($(real_calls) calls, want 2)"
pass=$((pass + 1))

# 18. gh api graphql is held at a spent GraphQL budget like any pr read (never cached)
fresh; export FAKE_GQL_REM=0 FAKE_GQL_RESET=$(( $(date +%s) + 3000 )) GH_SHARE_MAX_WAIT=60
out="$(timeout 10 "$GH_UNDER_TEST" api graphql -f query='{viewer{login}}' </dev/null 2>"$T/err")"; rc=$?
[ "$rc" = 75 ] && grep -q 'GH_ALLOWANCE_SPENT' "$T/err" || fail "api graphql at a spent GraphQL budget: rc $rc, want 75"
fresh; gh api graphql -f query=q >/dev/null; gh api graphql -f query=q >/dev/null
[ "$(real_calls)" = 2 ] || fail "api graphql was cached ($(real_calls) calls, want 2)"
pass=$((pass + 1))

# 19. OUTAGE: an allowance that cannot be read is a stop (rc 75, named), never a read sent uncounted;
#     a write still goes through (the floor is the writes')
fresh; export FAKE_RL_FAIL=1
out="$(timeout 15 "$GH_UNDER_TEST" run list </dev/null 2>"$T/err")"; rc=$?
[ "$rc" = 75 ] && [ -z "$out" ] && [ "$(real_calls)" = 0 ] && grep -q '^rate limit: NAMED STOP \[GH_ALLOWANCE_UNKNOWN\]' "$T/err" || fail "unreadable allowance: rc $rc, $(real_calls) reads sent: $(cat "$T/err")"
timeout 10 "$GH_UNDER_TEST" pr merge 19 --squash </dev/null >/dev/null || fail "a merge was held when the allowance was unreadable"
pass=$((pass + 1))

# 20. login shells find the wrapper (22 Nov 2026: launchd's `bash -lc`, Codex's `zsh -lc` and every script they
#     ran got Homebrew's gh, since path_helper and `brew shellenv` put /opt/homebrew/bin ahead of ~/bin)
H20="$T/home"; mkdir -p "$H20/bin"; printf '#!/bin/sh\n' > "$H20/bin/gh"; chmod +x "$H20/bin/gh"
printf 'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"\n' > "$H20/.zprofile"   # what brew shellenv does
mkdir -p "$T/hb"; INSTALL="${GH_SHARE_INSTALL_UNDER_TEST:-$HERE/install-gh-share.sh}"
GH_SHARE_HOME="$H20" "$INSTALL" --check >/dev/null 2>&1 && fail "--check passed before the line was installed"
GH_SHARE_HOME="$H20" "$INSTALL" >/dev/null || fail "install-gh-share.sh did not leave login shells on the wrapper"
for sh in /bin/bash /bin/zsh; do
  got="$(env -i HOME="$H20" PATH=/usr/bin:/bin "$sh" -lc 'command -v gh')"
  [ "$got" = "$H20/bin/gh" ] || fail "$sh -lc finds '$got', not the wrapper"
done
grep -q '^export PATH="/opt/homebrew/bin' "$H20/.zprofile" || fail "the installer dropped what .zprofile already had"
GH_SHARE_HOME="$H20" "$INSTALL" >/dev/null; [ "$(grep -c 'gh-share:' "$H20/.zprofile")" = 1 ] || fail "a second install added the line twice"
pass=$((pass + 1))

echo "test-gh-share: $pass cases passed — one shared cache, never stale, waits for the reset, writes never held and drop the cache, watchers poll through it, a share per poller, an unreadable allowance stops, login shells find it"
