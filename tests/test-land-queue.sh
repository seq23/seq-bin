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
  "run view 901"*) n=$(cat "$STATE/views" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STATE/views"
                   if [ "$n" -ge 3 ]; then touch "$STATE/done"; echo success; else echo ""; fi ;;
  "pr list"*) echo "${RECENT_OUT:-}" ;;
  *) echo "" ;;
esac
SH
printf '#!/bin/bash\nexit 0\n' > "$W/bin/sleep"; chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" STATE="$W"
eval "$(sed -n '/^# --- queue begin/,/^# --- queue end/p' "$LAND")"
type queue_wait >/dev/null 2>&1 || { echo "FAIL: no queue block in land"; exit 1; }
last_duration() { echo 600; }
fail=0
E2E_WF="e2e"; DEPLOY_WF=""; PROMOTE_WF="deploy.yml"
out="$(queue_wait)"; rc=$?
{ [ $rc -eq 0 ] && grep -q "e2e run 901 on main abcdef1 is still running" <<<"$out" && grep -q "finished: success" <<<"$out"; } || { echo "FAIL: in-flight run not waited for: $out"; fail=1; }
[ "$(cat "$W/views")" -ge 3 ] || { echo "FAIL: merged before the run finished"; fail=1; }
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
