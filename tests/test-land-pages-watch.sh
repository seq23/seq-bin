#!/bin/bash
# land must not call a self-deploying repo landed until EVERY one of its Cloudflare builds succeeded.
#
# 25 Sep 2026, local-guides-generator #48: main's workflows were green, land printed "nothing to
# run", and the base Cloudflare Pages project's production build had failed on the merge commit.
# 12 Oct 2026, local-guides-generator #61: land printed "every Cloudflare build succeeded" with one of
# the five projects reported — Cloudflare posts each check-run only when that build finishes, so the
# four still queued were absent and read as done. This evals the pages_watch block out of `land`
# verbatim against a fake `gh` that answers the commits list and each commit's check-runs from
# fixtures, with `sleep` advancing the clock, and checks every outcome: all five succeeded, one
# reported and four queued (declared list, and discovered from history alone), one failed, one
# still running, a declared repo where nothing posts, the deadline derived from recent builds, and
# no Cloudflare check-run anywhere. It also pins the local-guides-generator route to its five.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- pages_watch begin/,/^# --- pages_watch end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the pages_watch block"; exit 1; }
ROUTES="$(sed -n '/^# --- routes begin/,/^# --- routes end/p' "$LAND")"
[ -n "$ROUTES" ] || { echo "FAIL: land no longer carries the routes block"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# fake gh: `gh api <path> --jq <filter>`; commits?sha=main -> $FX/list.json, commits/<sha>/check-runs
# -> $FX/runs-<sha>.json (absent = no check-runs).
cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
[ "$1" = "api" ] || exit 1
path="${2%%\?*}"; [ "$3" = "--jq" ] || exit 1
case "$path" in
  */commits) f="$FX/list.json" ;;
  */check-runs) s="${path%/check-runs}"; f="$FX/runs-${s##*/}.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || f="$FX/none.json"
jq -r "$4" < "$f"
SH
chmod +x "$WORK/bin/gh"

P5="local-guides-generator-uscis-medical local-guides-generator-pi local-guides-generator-dentistry local-guides-generator-trt local-guides-generator-neuro"
cr() { printf '{"name":"%s","status":"%s","conclusion":%s,"completed_at":%s}' "$1" "$2" "$3" "${4:-null}"; }
runs() { local IFS=,; printf '{"check_runs":[%s]}' "$*"; }
five_done() { # $1 conclusion for pi, rest success; completed at 12:05 on a 12:00 commit
  local p out=() co
  for p in $P5; do co='"success"'; [ "$p" = local-guides-generator-pi ] && co="${1:-\"success\"}"
    out+=("$(cr "Cloudflare Pages: $p" completed "$co" '"2026-10-12T12:05:00Z"')"); done
  runs "${out[@]}"
}

run_case() { # name want-rc want-substring pages_projects [wait-secs]
  local name="$1" want="$2" sub="$3" pp="$4" ws="${5-0}" out rc
  out="$(env PATH="$WORK/bin:$PATH" FX="$FX" PAGES_APPEAR_SECS=0 ${ws:+PAGES_WAIT_SECS=$ws} bash -c '
    sleep() { SECONDS=$((SECONDS + 100)); }
    eval "$1"
    pages_watch deadbeef "$2"' _ "$BLOCK" "$pp")" && rc=0 || rc=$?
  if [ "$rc" != "$want" ]; then echo "  FAIL $name: rc $rc, want $want (out: $out)"; return 1; fi
  if [ -n "$sub" ] && [[ "$out" != *"$sub"* ]]; then echo "  FAIL $name: output lacks '$sub' (out: $out)"; return 1; fi
  echo "  ok   $name → $rc${sub:+ ($sub)}"
}
fails=0; n=0
check() { n=$((n+1)); run_case "$@" || fails=$((fails+1)); }
newfx() { FX="$(mktemp -d "$WORK/fx.XXXX")"; echo '{"check_runs":[]}' > "$FX/none.json"; echo '[]' > "$FX/list.json"; }
history5() { # main = deadbeef (merge) then parent1 committed 12:00, all five built by 12:05 (300 s)
  printf '[{"sha":"deadbeef","commit":{"committer":{"date":"2026-10-12T13:00:00Z"}}},{"sha":"parent1","commit":{"committer":{"date":"2026-10-12T12:00:00Z"}}}]' > "$FX/list.json"
  five_done > "$FX/runs-parent1.json"
}

newfx; history5; five_done > "$FX/runs-deadbeef.json"
check "all five succeeded" 0 "Cloudflare Pages: local-guides-generator-neuro — success" "$P5"
n_ok="$(PATH="$WORK/bin:$PATH" FX="$FX" PAGES_APPEAR_SECS=0 PAGES_WAIT_SECS=0 bash -c 'sleep(){ :; }; eval "$1"; pages_watch deadbeef "$2"' _ "$BLOCK" "$P5" | grep -c ' — success$' || true)"
n=$((n+1)); if [ "$n_ok" = 5 ]; then echo "  ok   one line per project → 5 lines"; else echo "  FAIL one line per project: $n_ok success lines, want 5"; fails=$((fails+1)); fi

newfx; history5; runs "$(cr 'Cloudflare Pages: local-guides-generator-pi' completed '"success"')" > "$FX/runs-deadbeef.json"
check "#61: one reported, four queued (declared)" 1 "local-guides-generator-neuro — not yet reported (queued) — TIMED OUT" "$P5"
check "#61: one reported, four queued (history only)" 1 "local-guides-generator-trt — not yet reported (queued) — TIMED OUT" ""
check "deadline = 4x slowest recent build (300 s)" 1 "TIMED OUT at the 1200s deadline" "$P5" ""

newfx; runs "$(cr 'Cloudflare Pages: a' completed '"success"')" > "$FX/runs-deadbeef.json"
check "nothing declared, nothing in history, one posted" 0 "Cloudflare Pages: a — success" ""
newfx; runs "$(cr 'Cloudflare Pages: a' in_progress null)" > "$FX/runs-deadbeef.json"
check "deadline floor 600 s with no history" 1 "TIMED OUT at the 600s deadline" "" ""

# Live shape of 12 Oct: newest earlier commit superseded mid-queue (one run, never completed), the
# one before built the five, and an older one also built the since-retired base project. Only the
# newest COMPLETE commit defines the set, so the retired base project is not waited on.
newfx
printf '[{"sha":"deadbeef","commit":{"committer":{"date":"2026-10-12T13:00:00Z"}}},{"sha":"partial","commit":{"committer":{"date":"2026-10-12T12:30:00Z"}}},{"sha":"parent1","commit":{"committer":{"date":"2026-10-12T12:00:00Z"}}},{"sha":"old","commit":{"committer":{"date":"2026-10-12T11:00:00Z"}}}]' > "$FX/list.json"
runs "$(cr 'Cloudflare Pages: local-guides-generator-neuro' in_progress null)" > "$FX/runs-partial.json"
five_done > "$FX/runs-parent1.json"
runs "$(cr 'Cloudflare Pages: local-guides-generator' completed '"success"' '"2026-10-12T11:01:00Z"')" > "$FX/runs-old.json"
five_done > "$FX/runs-deadbeef.json"
check "retired project and superseded commit are not the set" 0 "local-guides-generator-pi — success" ""
newfx; history5; runs "$(cr 'Cloudflare Pages: local-guides-generator-pi' completed '"success"')" "$(cr 'Cloudflare Pages: local-guides-generator-neuro' completed '"success"')" > "$FX/runs-deadbeef.json"
check "two of five reported (history only) is never success" 1 "local-guides-generator-dentistry — not yet reported (queued) — TIMED OUT" ""

newfx; history5; five_done '"failure"' > "$FX/runs-deadbeef.json"
check "one failed" 1 "local-guides-generator-pi — FAILED (failure)" "$P5"
newfx; runs "$(cr 'Workers Builds: w' completed '"failure"')" > "$FX/runs-deadbeef.json"
check "workers build failed" 1 "Workers Builds: w — FAILED (failure)" ""
newfx; runs "$(cr 'Cloudflare Pages: slow' in_progress null)" > "$FX/runs-deadbeef.json"
check "still running at deadline" 1 "Cloudflare Pages: slow — in_progress — TIMED OUT" ""
newfx
check "declared projects, nothing posted: a wait, never rc 2" 1 "local-guides-generator-pi — not yet reported (queued) — TIMED OUT" "$P5"
newfx; runs "$(cr validate completed '"failure"')" > "$FX/runs-deadbeef.json"
check "no cloudflare check" 2 "" ""
newfx
check "no checks at all" 2 "" ""

# The route that broke must declare all five, so discovery can never come back empty for it.
got="$(NAME=local-guides-generator bash -c 'eval "$1"; echo "$PAGES_PROJECTS"' _ "$ROUTES" | tr ' ' '\n' | sed '/^$/d' | sort | paste -sd' ' -)"
want="$(echo "$P5" | tr ' ' '\n' | sort | paste -sd' ' -)"
n=$((n+1)); if [ "$got" = "$want" ]; then echo "  ok   local-guides-generator route declares its 5 Pages projects"
else echo "  FAIL local-guides-generator route PAGES_PROJECTS='$got', want '$want' (zero discovered is never a pass)"; fails=$((fails+1)); fi

[ "$n" -gt 0 ] || { echo "FAIL: examined zero cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-pages-watch: $fails failure(s)"; exit 1; }
echo "test-land-pages-watch: $n cases pass"
