#!/bin/bash
# land must not call a self-deploying repo landed while its Cloudflare build failed.
#
# 25 Sep 2026, local-guides-generator #48: main's workflows were green, land printed "nothing to
# run", and the base Cloudflare Pages project's production build had failed on the merge commit.
# This evals the pages_watch block out of `land` verbatim against a fake `gh` that answers the
# check-runs API from a fixture, and checks every outcome: all succeeded, one failed, one still
# running at the deadline, and no Cloudflare check-run at all (only unrelated runs).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- pages_watch begin/,/^# --- pages_watch end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the pages_watch block"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# fake gh: `gh api <path> --jq <filter>` answers with the fixture in $FIXTURE through jq.
cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
[ "$1" = "api" ] || exit 1
shift; shift
[ "$1" = "--jq" ] || exit 1
jq -r "$2" < "$FIXTURE"
SH
chmod +x "$WORK/bin/gh"

run_case() { # name fixture-json want-rc [want-substring]
  local name="$1" json="$2" want="$3" sub="${4:-}" out rc
  printf '%s' "$json" > "$WORK/fx.json"
  out="$(PATH="$WORK/bin:$PATH" FIXTURE="$WORK/fx.json" PAGES_APPEAR_SECS=0 PAGES_WAIT_SECS=0 bash -c '
    sleep() { :; }
    eval "$1"
    pages_watch deadbeef' _ "$BLOCK")" && rc=0 || rc=$?
  if [ "$rc" != "$want" ]; then echo "  FAIL $name: rc $rc, want $want (out: $out)"; return 1; fi
  if [ -n "$sub" ] && [[ "$out" != *"$sub"* ]]; then echo "  FAIL $name: output lacks '$sub' (out: $out)"; return 1; fi
  echo "  ok   $name → $rc${sub:+ ($sub)}"
}
cr() { printf '{"name":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3"; }
fails=0; n=0
check() { n=$((n+1)); run_case "$@" || fails=$((fails+1)); }

check "all succeeded" "{\"check_runs\":[$(cr 'Cloudflare Pages: a' completed '"success"'),$(cr 'Cloudflare Pages: b' completed '"success"'),$(cr validate completed '"success"')]}" 0
check "one failed" "{\"check_runs\":[$(cr 'Cloudflare Pages: a' completed '"success"'),$(cr 'Cloudflare Pages: base' completed '"failure"')]}" 1 "Cloudflare Pages: base (failure)"
check "workers build failed" "{\"check_runs\":[$(cr 'Workers Builds: w' completed '"failure"')]}" 1 "Workers Builds: w (failure)"
check "still running at deadline" "{\"check_runs\":[$(cr 'Cloudflare Pages: slow' in_progress null)]}" 1 "Cloudflare Pages: slow"
check "no cloudflare check" "{\"check_runs\":[$(cr validate completed '"failure"')]}" 2
check "no checks at all" '{"check_runs":[]}' 2

[ "$n" -gt 0 ] || { echo "FAIL: examined zero cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-pages-watch: $fails failure(s)"; exit 1; }
echo "test-land-pages-watch: $n cases pass"
