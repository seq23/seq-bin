#!/bin/bash
# shellcheck disable=SC2034,SC2329  # workflow vars and last_duration are used by the queue block eval'd below
# The merge queue (land's `queue` block): a post-merge run in flight on main is waited for before
# merging, and a land within 30 minutes of another prints the batch warning. Drives the block
# verbatim against a stub `gh`; no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="${LAND_UNDER_TEST:-$HERE/../land}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'SH'
#!/bin/bash
case "$*" in
  "run list --workflow e2e --branch main --status in_progress"*) [ -f "$STATE/done" ] && echo "" || printf '901\te2e\t%s\n' abcdef1234567 ;;
  "run list"*) echo "" ;;
  "api repos/{owner}/{repo}/actions/runs/901"*) n=$(cat "$STATE/views" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STATE/views"
                   if [ "$n" -ge 3 ]; then touch "$STATE/done"; echo success; else echo ""; fi ;;
  "pr list"*) echo "${RECENT_OUT:-}" ;;
  *) echo "" ;;
esac
SH
printf '#!/bin/bash\necho "$1" >> "$STATE/sleeps"\n' > "$W/bin/sleep"; chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" STATE="$W"
eval "$(sed -n '/^# --- run_conclusion begin/,/^# --- run_conclusion end/p;/^# --- queue begin/,/^# --- queue end/p' "$LAND")"
type queue_wait >/dev/null 2>&1 || { echo "FAIL: no queue block in land"; exit 1; }
last_duration() { echo 600; }
fail=0
E2E_WF="e2e"; DEPLOY_WF=""; PROMOTE_WF="deploy.yml"
out="$(queue_wait)"; rc=$?
{ [ $rc -eq 0 ] && grep -q "e2e run 901 on main abcdef1 is still running" <<<"$out" && grep -q "finished: success" <<<"$out"; } || { echo "FAIL: in-flight run not waited for: $out"; fail=1; }
[ "$(cat "$W/views")" -ge 3 ] || { echo "FAIL: merged before the run finished"; fail=1; }
# 22 Nov 2026 hostile review F1: one read per poll, a minute apart (it was two run views every 20 s,
# ~700 REST per e2e wait). 3 reads = 2 pending + 1 done, so 2 sleeps, each 60 s.
[ "$(cat "$W/views")" -eq 3 ] && [ "$(sort -u "$W/sleeps" | paste -sd, -)" = 60 ] && [ "$(wc -l < "$W/sleeps" | tr -d ' ')" -eq 2 ] \
  || { echo "FAIL: the wait is not one read per 60 s poll: $(cat "$W/views") reads, sleeps $(paste -sd, - < "$W/sleeps")"; fail=1; }
# no post-merge workflow on the route: nothing to wait for
E2E_WF=""; DEPLOY_WF=""; rm -f "$W/views" "$W/done"
[ -z "$(queue_workflows)" ] || { echo "FAIL: a route with no e2e/deploy workflow still queues"; fail=1; }
# ceiling: a run that never finishes is a named stop, never a cancel
E2E_WF="e2e"; last_duration() { echo 1; }
cat > "$W/bin/date" <<'SH'
#!/bin/bash
if [ "$1" = "+%s" ]; then n=$(cat "$STATE/clock" 2>/dev/null || echo 1000); echo $((n+400)) > "$STATE/clock"; echo $n; else /bin/date "$@"; fi
SH
chmod +x "$W/bin/date"
cat > "$W/bin/gh" <<'SH'
#!/bin/bash
case "$*" in "run list --workflow e2e --branch main --status in_progress"*) printf '902\te2e\t%s\n' 1234567abcdef ;; "run cancel"*) touch "$STATE/cancelled" ;; *) echo "" ;; esac
SH
chmod +x "$W/bin/gh"
out="$(queue_wait)"; rc=$?
{ [ $rc -eq 1 ] && grep -q "QUEUE_RUN_PAST_CEILING" <<<"$out" && [ ! -f "$W/cancelled" ]; } || { echo "FAIL: ceiling not a named stop (rc $rc): $out"; fail=1; }
rm -f "$W/bin/date"
# A REFUSED READ IS NOT "STILL RUNNING": land's own rate helpers (gates block) and a rate_wait that records each wait
eval "$(sed -n '/^# --- gates begin/,/^# --- gates end/p' "$LAND")"
rate_wait() { is_rate_limit "$1" || return 1; echo x >> "$W/rate-waits"; return 0; }
waits() { cat "$W/rate-waits" 2>/dev/null | grep -c .; }
cat > "$W/bin/gh" <<'SH'
#!/bin/bash
refuse() { echo "HTTP 403: API rate limit exceeded for installation ID 1." >&2; exit 1; }
case "$*" in
  "api rate_limit"*) echo $(( $(/bin/date +%s) + 600 )) ;;
  "run list --workflow e2e --branch main --status in_progress"*) [ -f "$STATE/list-403" ] && refuse; [ -f "$STATE/finished" ] && exit 0; printf '903\te2e\t%s\n' abcdef1234567 ;;
  "run list"*) echo "" ;;
  "api repos/{owner}/{repo}/actions/runs/903"*) n=$(cat "$STATE/v403" 2>/dev/null || echo 0); [ "$n" -gt 0 ] && { echo $((n-1)) > "$STATE/v403"; refuse; }
                   if [ -f "$STATE/view-done" ]; then touch "$STATE/finished"; echo success; else touch "$STATE/view-done"; echo ""; fi ;;
  *) echo "" ;;
esac
SH
chmod +x "$W/bin/gh"
cat > "$W/bin/date" <<'SH'
#!/bin/bash
if [ "$1" = "+%s" ]; then n=$(cat "$STATE/clock" 2>/dev/null || echo 1000); echo $((n+100)) > "$STATE/clock"; echo $n; else /bin/date "$@"; fi
SH
chmod +x "$W/bin/date"; last_duration() { echo 600; }
# the run view refused every time: one wait for the reset, one more ask, then rc 75 naming the reset, never a blind wait
rm -f "$W/rate-waits" "$W/view-done" "$W/clock" "$W/finished"; echo 99 > "$W/v403"
out="$(queue_wait 2>&1)"; rc=$?
{ [ $rc -eq 75 ] && grep -q "NAMED STOP \[QUEUE_UNREADABLE\]" <<<"$out" && grep -q "allowance resets at" <<<"$out" && [ "$(waits)" -eq 1 ]; } \
  || { echo "FAIL: a refused run view was read as still running (rc $rc, $(waits) waits): $out"; fail=1; }
# refused once: waits for the reset, asks again, and the queue goes on to the run's real end
rm -f "$W/rate-waits" "$W/view-done" "$W/clock" "$W/finished"; echo 1 > "$W/v403"
out="$(queue_wait 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && grep -q "finished: success" <<<"$out" && [ "$(waits)" -eq 1 ]; } || { echo "FAIL: one refusal then an answer did not carry on (rc $rc): $out"; fail=1; }
# the run list refused: unknown, never "nothing in flight"
rm -f "$W/rate-waits" "$W/view-done" "$W/clock" "$W/finished" "$W/v403"; touch "$W/list-403"
out="$(queue_wait 2>&1)"; rc=$?
{ [ $rc -eq 75 ] && grep -q "QUEUE_UNREADABLE" <<<"$out"; } || { echo "FAIL: a refused run list read as nothing in flight (rc $rc): $out"; fail=1; }
# a 5xx is no rate limit: no wait, rc 75 at once
rm -f "$W/list-403" "$W/rate-waits"
printf '#!/bin/bash\necho "HTTP 502: Bad Gateway" >&2; exit 1\n' > "$W/bin/gh"
out="$(queue_wait 2>&1)"; rc=$?
{ [ $rc -eq 75 ] && [ ! -e "$W/rate-waits" ] && ! grep -q "resets at" <<<"$out"; } || { echo "FAIL: a 502 in the queue was not could-not-verify (rc $rc): $out"; fail=1; }
rm -f "$W/bin/date"
# recent lands
cat > "$W/bin/gh" <<'SH'
#!/bin/bash
echo "${RECENT_OUT:-}"
SH
chmod +x "$W/bin/gh"
export RECENT_OUT="#429" ; [ "$(recent_lands 431)" = "#429" ] || { echo "FAIL: recent land not reported"; fail=1; }
RECENT_OUT="" ; [ -z "$(recent_lands 431)" ] || { echo "FAIL: warning with no recent land"; fail=1; }
[ $fail -eq 0 ] && echo "test-land-queue: ok"
exit $fail
