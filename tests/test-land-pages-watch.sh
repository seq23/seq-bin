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
# no Cloudflare check-run anywhere. It also pins the local-guides-generator route to its six
# projects (senior-living added 25 Oct 2026, fd341ba, which left this pin at five and main red), and
# checks the route's own "(N projects" text against the list it declares, so the two cannot drift.
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
  */commits/*) f="$FX/commit-${path##*/}.json"; [ -f "$f" ] || exit 1 ;;
  'repos/{owner}/{repo}') [ "$4" = .id ] && echo 42 || echo seq23/site; exit 0 ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || f="$FX/none.json"
jq -r "$4" < "$f"
SH
chmod +x "$WORK/bin/gh"
# fake Cloudflare: wrangler is a no-op, curl answers the Pages projects list from $FX/cf.json (absent =
# the API is unreachable), and the OAuth token exists only when $FX/token is present.
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/wrangler"
cat > "$WORK/bin/curl" <<'SH'
#!/bin/bash
[ -f "$FX/cf.json" ] || exit 7
cat "$FX/cf.json"
SH
chmod +x "$WORK/bin/wrangler" "$WORK/bin/curl"

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
  out="$(env PATH="$WORK/bin:$PATH" FX="$FX" HOME="$FX/home" PAGES_APPEAR_SECS=0 ${ws:+PAGES_WAIT_SECS=$ws} bash -c '
    sleep() { SECONDS=$((SECONDS + 100)); }
    eval "$1"
    pages_watch deadbeef "$2"' _ "$BLOCK" "$pp")" && rc=0 || rc=$?
  if [ "$rc" != "$want" ]; then echo "  FAIL $name: rc $rc, want $want (out: $out)"; return 1; fi
  if [ -n "$sub" ] && [[ "$out" != *"$sub"* ]]; then echo "  FAIL $name: output lacks '$sub' (out: $out)"; return 1; fi
  echo "  ok   $name → $rc${sub:+ ($sub)}"
}
fails=0; n=0
check() { n=$((n+1)); run_case "$@" || fails=$((fails+1)); }
newfx() { FX="$(mktemp -d "$WORK/fx.XXXX")"; echo '{"check_runs":[]}' > "$FX/none.json"; echo '[]' > "$FX/list.json"; mkdir -p "$FX/home"; }
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

# BUILD WATCH PATHS (3 Nov 2026, heygetonmylevel #12): the merge changed only a workflow file, the one
# Pages project builds only on questions/*, so Cloudflare never started a build and land waited for
# the "Cloudflare Pages" run it saw on an earlier commit until it STOPPED with main green.
watchfx() { # $1 = changed files (comma list) of the merge commit; history: parent1 built "Cloudflare Pages"
  newfx
  printf '[{"sha":"deadbeef","commit":{"committer":{"date":"2026-11-03T14:22:50Z"}}},{"sha":"parent1","commit":{"committer":{"date":"2026-11-03T12:28:33Z"}}}]' > "$FX/list.json"
  runs "$(cr 'Cloudflare Pages' completed '"success"' '"2026-11-03T12:28:55Z"')" > "$FX/runs-parent1.json"
  jq -n --arg f "$1" '{files: ($f | split(",") | map({filename: .}))}' > "$FX/commit-deadbeef.json"
  mkdir -p "$FX/home/.wrangler/config"; echo 'oauth_token = "t"' > "$FX/home/.wrangler/config/default.toml"
  printf '%s' '{"success":true,"result_info":{"total_pages":1},"result":[{"name":"site-learn","source":{"type":"github","config":{"owner":"seq23","repo_name":"site","production_branch":"main","path_includes":["questions/*","scripts/learn-build.mjs"],"path_excludes":[]}}},{"name":"other","source":{"type":"github","config":{"owner":"seq23","repo_name":"elsewhere","production_branch":"main"}}}]}' > "$FX/cf.json"
}
watchfx .github/workflows/search-loop.yml
check "workflow-only merge, watch paths unreached, nothing posted: no deploy needed" 3 "Cloudflare Pages — no deploy needed" ""
watchfx .github/workflows/search-loop.yml; runs "$(cr 'Cloudflare Pages' completed '"failure"')" > "$FX/runs-deadbeef.json"
check "a build that started and failed is still FAILED, watch paths or not" 1 "Cloudflare Pages — FAILED (failure)" ""
watchfx .github/workflows/search-loop.yml,questions/how-to/index.html
check "a merge inside the watch paths still waits for its build" 1 "Cloudflare Pages — not yet reported (queued) — TIMED OUT" ""
# PAUSED GIT BUILDS (8 Nov 2026, authority-backlink-network): founderoperatorlibrary moved to another
# account and its old Git-connected project had production builds switched off, so it never posts again.
watchfx .github/workflows/search-loop.yml,questions/how-to/index.html; sed -i.bak 's/"path_excludes":\[\]}/"path_excludes":[],"production_deployments_enabled":false}/' "$FX/cf.json"
check "a project whose Git production builds are paused is never waited for" 3 "Cloudflare Pages — no deploy needed" ""
watchfx .github/workflows/search-loop.yml; rm "$FX/cf.json"
check "watch paths unreadable: fail closed, still waits" 1 "Cloudflare Pages — not yet reported (queued) — TIMED OUT" ""
# RENAMED REPO (8 Nov 2026): Cloudflare still records authority-backlink-network as "authority-network",
# so matching on the name found no project; the repo id survives the rename.
watchfx .github/workflows/search-loop.yml; sed -i.bak 's/"repo_name":"site",/"repo_name":"old-name","repo_id":42,/' "$FX/cf.json"
check "a renamed repo's project is found by repo id: no deploy needed" 3 "Cloudflare Pages — no deploy needed" ""
# DEAD OAUTH (8 Nov 2026): wrangler's login expired, so watch paths read as unknown everywhere. The
# vault's token (a fake npm here, only inside ~/GitHub/boss-os) still reads the Pages list.
watchfx .github/workflows/search-loop.yml; rm "$FX/home/.wrangler/config/default.toml"; mkdir -p "$FX/home/GitHub/boss-os"
printf '#!/bin/bash\ncase "$PWD" in */GitHub/boss-os) printf vault-token ;; *) exit 1 ;; esac\n' > "$WORK/bin/npm"; chmod +x "$WORK/bin/npm"
check "no wrangler login, vault token reads the watch paths: no deploy needed" 3 "Cloudflare Pages — no deploy needed" ""
rm "$WORK/bin/npm"
watchfx .github/workflows/search-loop.yml; rm "$FX/home/.wrangler/config/default.toml"
check "no wrangler login: fail closed, still waits" 1 "not yet reported (queued) — TIMED OUT" ""

# The route that broke must declare all six, so discovery can never come back empty for it.
# Exact pin: adding or removing a project is a deliberate edit here as well as in land.
P_ROUTE="$P5 local-guides-generator-senior-living"
got="$(NAME=local-guides-generator bash -c 'eval "$1"; echo "$PAGES_PROJECTS"' _ "$ROUTES" | tr ' ' '\n' | sed '/^$/d' | sort | paste -sd' ' -)"
want="$(echo "$P_ROUTE" | tr ' ' '\n' | sort | paste -sd' ' -)"
n=$((n+1)); if [ "$got" = "$want" ]; then echo "  ok   local-guides-generator route declares its 6 Pages projects"
else echo "  FAIL local-guides-generator route PAGES_PROJECTS='$got', want '$want' (zero discovered is never a pass)"; fails=$((fails+1)); fi

# Every route that declares PAGES_PROJECTS and states "(N projects" in SELF must declare exactly N.
# fd341ba had to edit the count, the list and this pin by hand; the count and the list now prove each other.
counted=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  out="$(NAME="$repo" bash -c 'eval "$1"; printf "%s\n%s\n" "${SELF:-}" "${PAGES_PROJECTS:-}"' _ "$ROUTES")"
  self="$(printf '%s\n' "$out" | sed -n 1p)"; projects="$(printf '%s\n' "$out" | sed -n 2p)"
  [ -n "$projects" ] || continue
  stated="$(printf '%s\n' "$self" | sed -nE 's/.*\(([0-9]+) projects.*/\1/p')"
  [ -n "$stated" ] || continue
  declared="$(printf '%s\n' $projects | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  counted=$((counted+1)); n=$((n+1))
  if [ "$stated" = "$declared" ]; then echo "  ok   $repo route says $stated projects and declares $declared"
  else echo "  FAIL $repo route says $stated projects but declares $declared distinct PAGES_PROJECTS"; fails=$((fails+1)); fi
done < <(printf '%s\n' "$ROUTES" | grep -oE '^ *[a-z0-9._-]+\) ' | tr -d ' )')
[ "$counted" -gt 0 ] || { echo "FAIL: no route states a project count alongside PAGES_PROJECTS (examined zero)"; exit 1; }

[ "$n" -gt 0 ] || { echo "FAIL: examined zero cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-land-pages-watch: $fails failure(s)"; exit 1; }
echo "test-land-pages-watch: $n cases pass"
