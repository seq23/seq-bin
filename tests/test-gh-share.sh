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
if [ "$1 $2" = "api rate_limit" ]; then echo "$FAKE_REM $FAKE_RESET"; exit 0; fi
n=$(wc -l < "$FAKE_LOG" | tr -d ' ')
echo "answer-$n for $*"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/fake-gh"
export GH_SHARE_REAL="$T/fake-gh" FAKE_LOG="$T/calls" FAKE_REM=4000 FAKE_RESET=$(( $(date +%s) + 600 ))
pass=0
fail() { echo "FAIL: $*"; exit 1; }
fresh() { rm -rf "$T/share" "$T/calls"; touch "$T/calls"; export GH_SHARE_DIR="$T/share"; unset GH_SHARE_TTL GH_SHARE_FLOOR GH_SHARE_MAX_WAIT GH_SHARE_PER_CALLER FAKE_RC; }
real_calls() { grep -vc '^api rate_limit' "$T/calls"; }
gh() { "$HERE/gh" "$@" </dev/null; }

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
t0=$(date +%s); gh pr merge 5 --squash >/dev/null; rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 1 ] || fail "a merge was held at a spent allowance (rc $rc, $((t1 - t0)) s)"
grep -q '^pr merge 5' "$T/calls" || fail "the merge never reached gh"
gh api -X POST repos/x/y/dispatches -f event_type=go >/dev/null || fail "a dispatch (POST) was held"
pass=$((pass + 1))

# 6. a reset beyond the bounded wait is a named stop, exit 75, never a hang or a fake answer
fresh; export FAKE_REM=0 FAKE_RESET=$(( $(date +%s) + 3000 )) GH_SHARE_MAX_WAIT=60
out="$(gh run list 2>"$T/err")"; rc=$?
[ "$rc" = 75 ] && grep -q 'NAMED STOP \[GH_ALLOWANCE_SPENT\]' "$T/err" && [ -z "$out" ] || fail "spent allowance: rc $rc, want 75 + named stop and no answer"
pass=$((pass + 1))

# 7. watchers back off: no --interval gets 30; a shorter one is raised to 30; a longer one is kept
fresh; export FAKE_REM=4000
gh run watch 55 >/dev/null; gh pr checks 3 --watch --interval 5 >/dev/null; gh pr checks 4 --watch -i 90 >/dev/null
grep -q '^run watch 55 --interval 30$' "$T/calls" || fail "gh run watch did not get --interval 30: $(cat "$T/calls")"
grep -q '^pr checks 3 --watch --interval 30$' "$T/calls" || fail "--interval 5 was not raised to 30"
grep -q '^pr checks 4 --watch -i 90$' "$T/calls" || fail "a longer interval was changed"
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

echo "test-gh-share: $pass cases passed — one shared cache, never stale, waits for the reset, writes never held, watchers back off, a share per poller"
