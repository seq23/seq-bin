#!/bin/bash
# pr-watch, driven for real against a fake gh, a fake land-after, a fake banner and a HANDOFF fixture, with the
# real mac-window deciding the window (23 Nov 2026 brief, "how it breaks"; each case goes red when its guard
# is undone, see the PR's Mutation proof):
#   outage     the PR list down or rate-limited -> "couldn't check", exit 3, never "none stuck"; one PR unreadable
#              -> its own "couldn't check" line and exit 2, the rest still judged; land-after "could not verify" -> unknown
#   doubles    a PR a live land holds is never started again; one banner per PR per day; a sheet that FAILED at this
#              head is not started again; at most 3 lands a run
#   edges      a draft is ignored; pending or green under 30 min is not stuck (a recent check counts as movement);
#              Dependabot or another author is reported only; a hold label is left alone; no checks at all = green
#   data loss  only read verbs reach gh; the HANDOFF block is replaced, never stacked, the rest kept byte for byte
#   window     07:00-09:59 and 22:00 CT read nothing at all
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PW="${PR_WATCH_UNDER_TEST:-$HERE/../pr-watch}"
[ -x "$PW" ] || { echo "FAIL: no pr-watch at $PW"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME/Work/tasks"
F="$W/fake"; BIN="$W/bin"; mkdir -p "$F" "$BIN"
export FAKE_DIR="$F" PATH="$BIN:$PATH" TMPDIR="$W"
export PR_WATCH_LAND_AFTER="$W/fake-land-after" PR_WATCH_NOTIFY="$W/fake-notify" PR_WATCH_MAC_WINDOW="$HERE/../mac-window"
export PR_WATCH_STATE="$W/state" PR_WATCH_HANDOFF="$W/HANDOFF.md"
NOW=1795456800   # 2026-11-23 12:00 CT (18:00Z), inside the LIGHT window
export PR_WATCH_NOW_EPOCH=$NOW MAC_WINDOW_NOW=12:00
pass=0; failn=0
check() { local d="$1"; shift; if "$@"; then pass=$((pass + 1)); echo "  ok  $d"; else failn=$((failn + 1)); echo "  FAIL $d"; fi; }

cat > "$BIN/gh" <<'SH'
#!/bin/bash
F="$FAKE_DIR"; echo "$*" >> "$F/gh-log"
case "$1 $2" in
  "search prs")
    case "$(cat "$F/list-mode" 2>/dev/null)" in
      down) echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1 ;;
      ratelimit) echo "HTTP 403: API rate limit exceeded for user ID 1. (https://api.github.com/search/issues)" >&2; exit 1 ;;
      junk) echo "<html>502 Bad Gateway</html>"; exit 0 ;;
    esac
    cat "$F/list" 2>/dev/null || echo '[]' ;;
  "pr view")  k="${5//\//_}-$3"; [ -f "$F/view-$k" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; cat "$F/view-$k" ;;
  "pr checks") k="${5//\//_}-$3"
    case "$(cat "$F/checks-$k" 2>/dev/null || echo DOWN)" in
      DOWN) echo "error connecting to api.github.com: dial tcp: i/o timeout" >&2; exit 1 ;;
      NONE) echo "no checks reported on the 'feat' branch" >&2; exit 1 ;;
      *) cat "$F/checks-$k" ;;
    esac ;;
  "run view") cat "$F/joblog" 2>/dev/null ;;
  *) echo "fake gh: a call pr-watch must never make: $*" >&2; echo "FORBIDDEN $*" >> "$F/forbidden"; exit 1 ;;
esac
SH
cat > "$W/fake-land-after" <<'SH'
#!/bin/bash
F="$FAKE_DIR"
if [ "$1" = --holds ]; then [ -f "$F/held-${2//\//_}-$3" ] && { echo 4242; exit 0; }; exit 1; fi
echo "$*" >> "$F/la-log"; k="${3//\//_}-$1"
case "$(cat "$F/la-$k" 2>/dev/null || echo ok)" in
  ok) case " $* " in *" --dry-run "*) echo "land-after: would land $3#$1 (sheet x); --dry-run, nothing started" ;;
        *) echo "land-after: started (pid 9) — log x" ;; esac; exit 0 ;;
  review) echo "land-after: REFUSED — $3#$1 needs a reviewer: needs a review (it says Review class: money) and changes code (src/pay.ts), and no fresh reviewer's Ship-ready PASS line stands for it: a fresh reviewer looks at the diff, its tests and their mutation proof at head abc12345 and posts the line as a PR comment by the repo's owner account (a later VERDICT: fail voids a PASS in the body); nothing started. All 1 thing(s) to fix, each with its line:"
          echo "  1. [REVIEW_PASS_MISSING] PR #$1 needs a review (it says Review class: money) and changes code (src/pay.ts)"; echo "       add: Ship-ready: PASS — <fresh reviewer, its session or run id> looked at <the real output> at abc12345; Engineering: PASS"; exit 4 ;;
  unverified) echo "land-after: could not verify $3#$1 (HTTP 502); nothing started"; exit 75 ;;
  refuse) echo "land-after: REFUSED — no checkout of $3 here or at ~/GitHub/x"; exit 1 ;;
esac
SH
cat > "$W/fake-notify" <<'SH'
#!/bin/bash
[ "$1" = --banner ] || { echo "fake notify: not a banner call: $*" >&2; exit 9; }
printf '%s | %s | %s\n' "$2" "$3" "$4" >> "$FAKE_DIR/banners"
SH
chmod +x "$BIN/gh" "$W/fake-land-after" "$W/fake-notify"

iso() { jq -rn --argjson t $((NOW - $1 * 60)) '$t | todate'; }   # $1 minutes ago, as GitHub writes it
reset() {
  rm -rf "${F:?}"/* "${W:?}/state" "${HOME:?}/Work/tasks"/*; echo '[]' > "$F/list"
  printf '# HANDOFF\n\nstart-here text\n\n## Today\n<!-- TODAY:START -->\n<!-- day:2026-11-23 -->\n_Monday 23 November 2026_\n\n<!-- JOBS:START -->\n### Jobs\n- none open\n<!-- JOBS:END -->\n\n- ENG-CHECK DUE seq23/x#1 abc — a line land wrote\n\n### Session note — 11:00\nnotes\n<!-- TODAY:END -->\n\n## Later\nkept\n' > "$PR_WATCH_HANDOFF"
}
# pr <owner/repo> <n> <author> <draft> <commit min ago> <checks: pass|fail|pending|none|down|json> [check min ago] [labels csv]
pr() {
  local repo="$1" n="$2" author="$3" draft="$4" cmin="$5" ck="$6" chk="${7:-$5}" labels="${8:-}" k="${1//\//_}-$2" lb
  jq --arg r "$repo" --argjson n "$n" --arg a "$author" --argjson d "$draft" \
     '. + [{repository: {name: ($r | split("/")[1]), nameWithOwner: $r}, number: $n, title: "PR \($n) title", author: {login: $a}, isDraft: $d, url: "https://github.com/\($r)/pull/\($n)"}]' \
     "$F/list" > "$F/list.n" && mv "$F/list.n" "$F/list"
  lb="$(jq -cn --arg l "$labels" '$l | split(",") | map(select(. != "") | {name: .})')"
  jq -n --arg d "$(iso "$cmin")" --argjson lb "$lb" '{headRefOid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", commits: [{committedDate: $d}], labels: $lb}' > "$F/view-$k"
  case "$ck" in
    pass) jq -n --arg s "$(iso "$((chk + 5))")" --arg c "$(iso "$chk")" '[{name: "ci", bucket: "pass", startedAt: $s, completedAt: $c, link: "https://x/actions/runs/1/job/2"}]' ;;
    fail) jq -n --arg s "$(iso "$((chk + 5))")" --arg c "$(iso "$chk")" '[{name: "ci", bucket: "pass", startedAt: $s, completedAt: $c, link: "l"}, {name: "Unit and integration tests (shard 4/4)", bucket: "fail", startedAt: $s, completedAt: $c, link: "https://github.com/seq23/boss-os/actions/runs/45205253986/job/137799094125"}]' ;;
    pending) jq -n --arg s "$(iso "$chk")" '[{name: "e2e", bucket: "pending", startedAt: $s, completedAt: "0001-01-01T00:00:00Z", link: "l"}]' ;;
    none) echo NONE ;; down) echo DOWN ;;
    *) printf '%s' "$ck" ;;
  esac > "$F/checks-$k"
}
run() { (cd "$W" && "$PW" "$@") > "$W/out" 2>&1; RC=$?; }
has() { grep -qF -- "$1" "$W/out"; }
hf() { grep -qF -- "$1" "$PR_WATCH_HANDOFF"; }
block() { sed -n '/<!-- STUCK-PRS:START -->/,/<!-- STUCK-PRS:END -->/p' "$PR_WATCH_HANDOFF"; }
la_started() { grep -q "^$1 --repo $2\( \|$\)" "$F/la-log" 2>/dev/null && ! grep "^$1 --repo $2" "$F/la-log" | grep -q -- --dry-run; }
reads_only() { [ ! -s "$F/forbidden" ] && ! grep -vE '^(search prs|pr view|pr checks|run view) ' "$F/gh-log" | grep -q .; }

echo "=== outage: the list unreadable is couldn't check, never none stuck ==="
for m in down ratelimit junk; do
  reset; echo "$m" > "$F/list-mode"
  run
  check "list $m: exit 3, NAMED STOP [PR_LIST_FAILED]" eval '[ "$RC" -eq 3 ] && has "NAMED STOP [PR_LIST_FAILED]"'
  check "…HANDOFF says couldn't check, never none stuck" eval 'block | grep -q "couldn.t check" && ! block | grep -q "none stuck"'
  check "…the OUTPUT line says couldn't check" has "OUTPUT pr-watch: couldn't check"
  [ "$m" = ratelimit ] && check "rate limit: the reason names it" eval 'block | grep -q "rate limit"'
done
run
check "a second outage run the same day: still exit 3, ONE banner" eval '[ "$RC" -eq 3 ] && [ "$(wc -l < "$F/banners")" -eq 1 ]'

echo "=== green, the owner's own, quiet 45 min: land started; and the doubles ==="
reset; pr seq23/dailystory 184 seq23 false 45 pass 40
run
check "rc 0, land-after started for it" eval '[ "$RC" -eq 0 ] && la_started 184 seq23/dailystory'
check "…HANDOFF line says land started, in ONE block right under the Jobs list" eval 'hf "seq23/dailystory#184 green** 40 min: land started" && [ "$(grep -c "STUCK-PRS:START" "$PR_WATCH_HANDOFF")" -eq 1 ] && grep -A2 "JOBS:END" "$PR_WATCH_HANDOFF" | grep -q "STUCK-PRS:START"'
check "…one banner naming it" eval '[ "$(wc -l < "$F/banners")" -eq 1 ] && grep -q "dailystory#184" "$F/banners"'
check "…the census line" has "OUTPUT pr-watch: 1 open checked, 1 stuck, 1 lands started, 0 couldn't check"
cp "$PR_WATCH_HANDOFF" "$W/h1"
: > "$F/held-seq23_dailystory-184"; : > "$F/la-log"; : > "$F/gh-log"
run
check "held by a live land: never started again, not even read" eval '[ ! -s "$F/la-log" ] && ! grep -q "^pr view 184" "$F/gh-log"'
check "…and no second banner that day" eval '[ "$(wc -l < "$F/banners")" -eq 1 ]'
check "…the block was replaced, not stacked; everything else byte for byte" eval '[ "$(grep -c "STUCK-PRS:START" "$PR_WATCH_HANDOFF")" -eq 1 ] && diff <(sed "/STUCK-PRS:START/,/STUCK-PRS:END/d" "$W/h1") <(sed "/STUCK-PRS:START/,/STUCK-PRS:END/d" "$PR_WATCH_HANDOFF") >/dev/null && hf "ENG-CHECK DUE seq23/x#1" && hf "### Session note — 11:00" && hf "## Later"'
rm -f "$F/held-seq23_dailystory-184"; pr seq23/aplayer-mode 101 seq23 false 60 pass 60; echo review > "$F/la-seq23_aplayer-mode-101"
run
check "a later run: a banner names only the PR new today" eval '[ "$(wc -l < "$F/banners")" -eq 2 ] && tail -1 "$F/banners" | grep -q "aplayer-mode#101" && ! tail -1 "$F/banners" | grep -q "dailystory#184"'
check "review class with no PASS (land-after exit 4): needs a reviewer, with the reason only" eval 'hf "aplayer-mode#101 needs a reviewer** (green 60 min): needs a review (it says Review class: money) and changes code (src/pay.ts), and no fresh reviewer" && hf "Ship-ready PASS line stands for it (" && ! hf "a fresh reviewer looks at" && ! hf "add: Ship-ready" && ! hf "thing(s) to fix"'
reset; pr seq23/dailystory 184 seq23 false 45 pass 40
printf 'STATUS: FAIL seq23/dailystory#184 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-11-23 — land: deploy failed; log x\nGoal: y\n' > "$HOME/Work/tasks/ds.md"
run
check "a sheet that FAILED at this head: reported, never started again" eval '[ ! -s "$F/la-log" ] && hf "land FAILED at this head" && hf "$HOME/Work/tasks/ds.md"'
printf 'STATUS: building seq23/dailystory#184 - 2026-11-23\n' > "$HOME/Work/tasks/ds.md"
run
check "a builder's own sheet naming the PR: the land goes onto it (--task)" grep -q "^184 --repo seq23/dailystory --task ds" "$F/la-log"
reset; for i in 1 2 3 4; do pr seq23/r$i "$i" seq23 false 50 pass 50; done
run
check "four green: three lands started, the fourth queued for the next run" eval '[ "$(grep -c . "$F/la-log")" -eq 3 ] && hf "seq23/r4#4 green** 50 min: queued for the next run"'

echo "=== edges ==="
reset
pr seq23/a 1 seq23 true 90 pass 90            # draft
pr seq23/b 2 seq23 false 90 pending 10        # pending under 30 min
pr seq23/c 3 seq23 false 90 pending 45        # pending 45 min
pr seq23/d 4 seq23 false 10 pass 5            # green, commit 10 min ago
pr seq23/e 5 seq23 false 120 pass 10          # old commit, but its checks finished 10 min ago (a re-run or a push)
pr seq23/f 6 app/dependabot false 90 pass 90  # another author
pr seq23/g 7 seq23 false 90 pass 90 hold      # a hold label
pr seq23/h 8 seq23 false 90 none              # no checks at all
run
check "rc 0" [ "$RC" -eq 0 ]
check "a draft is ignored: never read, never counted" eval '! grep -q "^pr view 1 -R seq23/a" "$F/gh-log" && ! hf "seq23/a#1" && has "OUTPUT pr-watch: 7 open checked"'
check "pending under 30 min: not stuck" eval '! hf "seq23/b#2"'
check "pending 45 min: reported, nothing started" eval 'hf "seq23/c#3 checks pending** 45 min: e2e" && ! grep -q "^3 " "$F/la-log" 2>/dev/null'
check "green with a commit 10 min ago: not stuck" eval '! hf "seq23/d#4"'
check "an old commit whose checks finished 10 min ago: not stuck" eval '! hf "seq23/e#5"'
check "Dependabot's PR: reported only, never landed" eval 'hf "seq23/f#6 green** 90 min, by app/dependabot: reported only" && ! grep -q "^6 " "$F/la-log" 2>/dev/null'
check "a hold label: left alone" eval 'hf "seq23/g#7 green** 90 min, labelled hold" && ! grep -q "^7 " "$F/la-log" 2>/dev/null'
check "no checks at all: green, land-after decides" la_started 8 seq23/h
check "only read verbs ever reached gh (never close, push, comment, edit, merge)" reads_only

echo "=== red: the failing check and its first failing line (boss-os #552's shape) ==="
reset; pr seq23/boss-os 552 seq23 false 200 fail 190
printf 'Unit\tRun tests\t2026-11-23T15:00:00.1Z \033[31m×\033[0m phase 3: nothing new goes public without a PASS > every sender carries a PASS 7ms\nUnit\tRun tests\t2026-11-23T15:00:00.2Z ##[error]Process completed with exit code 1.\n' > "$F/joblog"
run
check "red: one line with the check name, the first failing line and the link" eval 'hf "seq23/boss-os#552 red** 3 h: \`Unit and integration tests (shard 4/4)\` — × phase 3: nothing new goes public" && hf "/job/137799094125"'
check "…ANSI codes and timestamps stripped" eval '! grep -q $'"'"'\033'"'"' "$PR_WATCH_HANDOFF" && ! hf "2026-11-23T15:00"'
check "…never landed" eval '[ ! -s "$F/la-log" ]'
: > "$F/gh-log"; run
check "…the failing line is read once per head (cached)" eval '! grep -q "^run view" "$F/gh-log" && hf "× phase 3"'

echo "=== outage per PR: unknown, never judged ==="
reset; pr seq23/ok 1 seq23 false 45 pass 40; pr seq23/bad 2 seq23 false 45 down; pr seq23/unv 3 seq23 false 45 pass 40
echo unverified > "$F/la-seq23_unv-3"
run
check "a PR whose checks cannot be read: exit 2, its own couldn't check line" eval '[ "$RC" -eq 2 ] && hf "couldn'"'"'t check** seq23/bad#2"'
check "…the rest still judged (the readable one's land started)" la_started 1 seq23/ok
check "land-after could not verify (exit 75): couldn't check, never started or green" eval 'hf "couldn'"'"'t check** seq23/unv#3 — land-after could not verify"'
check "…and the census counts them" has "2 couldn't check"
reset; pr seq23/ok 1 seq23 false 45 pass 40; rm -f "$F/view-seq23_ok-1"
run
check "a PR whose head cannot be read: exit 2, couldn't check" eval '[ "$RC" -eq 2 ] && hf "couldn'"'"'t check** seq23/ok#1 — its head could not be read"'
reset; for i in 1 2 3; do pr seq23/m "$i" seq23 false 50 pass 50; done
PR_WATCH_LIMIT=3 run
check "a list cut at its limit: exit 2, never a full answer" eval '[ "$RC" -eq 2 ] && hf "the list stopped at 3 PRs"'

echo "=== the window: 07:00-09:59 and 22:00 CT read nothing ==="
for t in 07:00 08:00 09:59 22:00; do
  reset; pr seq23/dailystory 184 seq23 false 45 pass 40; cp "$PR_WATCH_HANDOFF" "$W/h0"
  MAC_WINDOW_NOW=$t run
  check "$t: exit 0, OUTSIDE_WINDOW, no gh call, no land, HANDOFF untouched, no banner" eval '[ "$RC" -eq 0 ] && has "OUTSIDE_WINDOW" && [ ! -s "$F/gh-log" ] && [ ! -s "$F/la-log" ] && cmp -s "$W/h0" "$PR_WATCH_HANDOFF" && [ ! -s "$F/banners" ]'
done
reset; PR_WATCH_MAC_WINDOW=/nonexistent run
check "a window that cannot be read: NAMED STOP, exit 3, nothing read" eval '[ "$RC" -eq 3 ] && has "MAC_WINDOW_UNREAD" && [ ! -s "$F/gh-log" ]'

echo "=== --dry-run: reads and classifies, starts and writes nothing ==="
reset; pr seq23/dailystory 184 seq23 false 45 pass 40; cp "$PR_WATCH_HANDOFF" "$W/h0"
MAC_WINDOW_NOW=08:00 run --dry-run
check "dry run (even at 08:00): land-after only with --dry-run, would land printed" eval '[ "$RC" -eq 0 ] && grep -q "^184 --repo seq23/dailystory --dry-run" "$F/la-log" && has "would start land-after (dry run)"'
check "…HANDOFF untouched, no banner, no state written" eval 'cmp -s "$W/h0" "$PR_WATCH_HANDOFF" && [ ! -s "$F/banners" ] && [ ! -e "$W/state" ]'

echo "=== none stuck, and a HANDOFF with no Today ==="
reset; pr seq23/d 4 seq23 false 10 pass 5
run
check "nothing stuck: 'none stuck (1 open PRs checked)'" eval '[ "$RC" -eq 0 ] && block | grep -q "none stuck (1 open PRs checked)"'
printf '# HANDOFF\nonly a pinned block\n' > "$PR_WATCH_HANDOFF"; run
check "a HANDOFF with no Today gets one, the pinned text kept" eval 'hf "<!-- TODAY:START -->" && hf "only a pinned block" && block | grep -q "none stuck"'
mkdir -p "$W/ro"; chmod 500 "$W/ro"; PR_WATCH_HANDOFF="$W/ro/HANDOFF.md" run; chmod 700 "$W/ro"
check "an unwritable HANDOFF: NAMED STOP [HANDOFF_NOT_WRITTEN], exit 4, never a silent 0" eval '[ "$RC" -eq 4 ] && has "HANDOFF_NOT_WRITTEN"'

echo "=== the banner sender (ci-sweep-notify.sh --banner) ==="
NB="$HERE/../ci-sweep-notify.sh"
o="$(CI_SWEEP_NOTIFY_DRY=1 "$NB" --banner "Stuck PRs" "2 stuck" 'boss-os#552 red')"; r=$?; ok=0
[ "$r" -eq 0 ] && [ "$o" = '[notify:dry] banner: "Stuck PRs: 2 stuck" / "boss-os#552 red"' ] && ok=1
check "--banner: one banner, files no issue" [ "$ok" -eq 1 ]
o="$(CI_SWEEP_NOTIFY_DRY=1 "$NB" --banner "Stuck PRs" "" "")"; r=$?; ok=0
[ "$r" -eq 2 ] && [[ "$o" == *NO_BANNER_TEXT* ]] && ok=1
check "--banner with no body: exit 2, NO_BANNER_TEXT" [ "$ok" -eq 1 ]

echo
echo "pr-watch: $pass passed, $failn failed"
[ "$pass" -gt 0 ] || { echo "FAIL: zero checks ran"; exit 1; }
[ "$failn" -eq 0 ]
