#!/bin/bash
# shellcheck disable=SC2016,SC2034  # commands are passed as strings for land's eval; vars are read by the eval'd block
# A local deploy says why it failed, runs one at a time, and never starts on a full disk (22 Nov 2026:
# boss-os and aplayer-mode#103 landed together, two full `npm ci` runs filled the disk, and both
# STOPPED with "read the error, it explains itself" over no error: the install ran --silent, the
# deploy ran under `npm run -s`). Evals land's deploy_at block verbatim against a real temp git repo,
# a fake npm and a fake df. No real install, no real overlap of two npm ci runs: both are faked.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="${LAND_UNDER_TEST:-$HERE/../land}"
W="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
BLOCK="$(sed -n '/^# --- deploy_at begin/,/^# --- deploy_at end/p' "$LAND")"
grep -q '^deploy_at()' <<<"$BLOCK" || { echo "FAIL test-land-local-ship: land has no deploy_at block"; exit 1; }
fails=0; passes=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"; passes=$((passes+1)); else echo "  FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo "no: $1"; }

# A real repo with a lockfile at its sha, and no node_modules here, so deploy_at must install.
REPO="$W/repo"; mkdir -p "$REPO" "$W/bin" "$W/tmp"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
echo '{"name":"x","version":"1.0.0"}' > "$REPO/package.json"; echo '{"lockfileVersion":3}' > "$REPO/package-lock.json"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init; SHA="$(git -C "$REPO" rev-parse HEAD)"

# fake npm: FAKE_NPM=ok (prints a line), silent2 (prints nothing, exit 2), or fixture:<name>:<rc> (prints
# tests/fixtures/npm/<name>.out, output captured from REAL npm 11 on 22 Nov 2026, and exits rc)
cat > "$W/bin/npm" <<'SH'
#!/bin/bash
echo "npm $*" >> "$W/npm-calls"
case "${FAKE_NPM:-ok}" in
  ok) echo "added 1 package" ;;
  silent2) exit 2 ;;
  fixture:*) f="${FAKE_NPM#fixture:}"; cat "$FIX/${f%%:*}.out"; exit "${f##*:}" ;;
esac
SH
# fake df: FAKE_DF_KB is the free KB on the temp volume; "fail" = df errors with no output
cat > "$W/bin/df" <<'SH'
#!/bin/bash
[ "${FAKE_DF_KB:-}" = fail ] && { echo "df: /x: No such file or directory" >&2; exit 1; }
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3s1s1 239362496 13000000 ${FAKE_DF_KB:-99999999} 34% /"
SH
chmod +x "$W/bin/npm" "$W/bin/df"
FIX="$HERE/fixtures/npm"; export W FIX

# One deploy, in its own bash process (two land runs are two processes): prints "<rc>|<DEPLOY_WHY>".
cat > "$W/run.sh" <<'SH'
#!/bin/bash
set -uo pipefail
eval "$BLOCK"
cd "$REPO" || exit 9
REPO_DIR="$REPO"; NAME="$1"
deploy_at "$SHA" "$2" > "$W/out-$1" 2>&1; rc=$?
printf '%s|%s\n' "$rc" "$DEPLOY_WHY"
SH
chmod +x "$W/run.sh"
export BLOCK REPO SHA
run() { # name command -> "<rc>|<why>"
  PATH="$W/bin:$PATH" TMPDIR="$W/tmp" LAND_DEPLOY_LOCK="$W/lock/deploy.lock" LAND_DEPLOY_POLL=1 "$W/run.sh" "$@"
}
wts() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }

echo "== the STOPPED line carries the real error"
: > "$W/npm-calls"; rm -f "$W/ran"
r="$(FAKE_NPM=silent2 run a 'touch "$W/ran"')"
check "a silent install failure is refused" 2 "${r%%|*}"
check "  ... and says which step, its exit code and that it printed nothing" yes "$(has "$r" "npm ci in the deploy worktree at ${SHA:0:7} exited 2: it printed nothing")"
check "  ... and the deploy command never ran" no "$([ -e "$W/ran" ] && echo yes || echo no)"
check "  ... and the install is not silenced (--loglevel=error, never --silent)" "npm ci --no-audit --no-fund --loglevel=error" "$(head -1 "$W/npm-calls")"
# 22 Nov 2026 review F1: npm's filler (bare "npm error", usage, "Run npm help", "A complete log") hid the cause.
filler() { grep -qE 'A complete log|Run "npm help|--install-strategy|Clean install a project|npm error \||\| \||> ' <<<"$1" && echo "no: $1" || echo yes; }
r="$(FAKE_NPM=fixture:ci-mismatch:1 run a 'true')"
check "real npm ci lockfile mismatch: npm's code and the package it names" yes "$(has "$r" "1|npm ci in the deploy worktree at ${SHA:0:7} exited 1: npm error code EUSAGE | ")"
check "  ... and the line that names the cause" yes "$(has "$r" "Missing: left-pad@1.3.0 from lock file")"
check "  ... and none of npm's filler" yes "$(filler "$r")"
r="$(FAKE_NPM=fixture:install-enospc:228 run a 'true')"
check "real npm ENOSPC: code and 'no space left on device'" yes "$(has "$r" "exited 228: npm error code ENOSPC | nospc ENOSPC: no space left on device")"
check "  ... and none of npm's filler or its path/errno fields" yes "$(grep -qE 'errno|syscall|npm error path' <<<"$r" && echo "no: $r" || filler "$r")"
r="$(run a 'cat "$FIX/nested-run.out"; exit 2')"
check "real nested npm run failure: the tool's own error first" yes "$(has "$r" "the deploy command exited 2: src/index.ts(3,7): error TS2304: Cannot find name foo. | npm error Lifecycle script \`typecheck\` failed")"
check "  ... and no '> ' script headers or filler" yes "$(filler "$r")"
r="$(run a 'cat "$FIX/nested-run-quiet.out"; exit 2')"
check "real nested npm run with its output hidden: npm's own block, its code and workspace" yes "$(has "$r" "exited 2: npm error Lifecycle script \`typecheck\` failed with error: | code 2 | workspace @apm/api@1.0.0")"
r="$(run a 'cat "$FIX/missing-script.out"; exit 1')"
check "real short npm error (missing script): its lines, without 'A complete log'" '1|the deploy command exited 1: npm error Missing script: "deploy" | To see a list of scripts, run: | npm run' "$r"
r="$(run a 'for i in 1 2 3 4 5 6; do echo "step $i"; done; exit 3')"
check "a long tool failure (no npm block) keeps its LAST 3 lines" "3|the deploy command exited 3: step 4 | step 5 | step 6" "$r"
r="$(run a 'echo building; printf "\033[31mX [ERROR] Could not resolve @apm/ai\033[0m\n" >&2; exit 4')"
check "a failing deploy command: its exit code and its stderr, colours stripped" "4|the deploy command exited 4: building | X [ERROR] Could not resolve @apm/ai" "$r"
check "  ... and its output still reached the terminal" yes "$(grep -q 'Could not resolve' "$W/out-a" && echo yes || echo no)"
r="$(run a 'exit 5')"
check "a deploy command that prints nothing says so" "5|the deploy command exited 5: it printed nothing" "$r"
r="$(run a 'echo shipped')"
check "a good deploy: exit 0 and no reason" "0|" "$r"
check "  ... and its worktree and capture file are gone" "1 0" "$(wts) $(find "$W/tmp" -maxdepth 1 -name 'land-deploy.*' | wc -l | tr -d ' ')"

echo "== every caller puts the reason in its STOPPED line"
CALLS="$(grep -E 'deploy_at "[^"]+" "\$(DEPLOY|STAGING)" \|\| die' "$LAND")"
check "land has deploy callers to check (not zero)" yes "$([ "$(grep -c . <<<"$CALLS")" -ge 4 ] && echo yes || echo "no: $(grep -c . <<<"$CALLS")")"
check "every deploy_at || die names \$DEPLOY_WHY" 0 "$(grep -vc 'DEPLOY_WHY' <<<"$CALLS")"
# 22 Nov 2026 review F2: the reason comes first. land-after keeps a STOPPED line's first 600 characters, and
# an opening of "#PR IS MERGED and $GREEN, but ..." (130-200 characters) pushed the reason past it.
DIES="$(grep -E '\|\| die "[^"]*\$\{?DEPLOY_WHY' "$LAND")"
check "deploy and D1 STOPPED lines to check (not zero)" yes "$([ "$(grep -c . <<<"$DIES")" -ge 6 ] && echo yes || echo "no: $(grep -c . <<<"$DIES")")"
late="$(while IFS= read -r l; do o="${l#*|| die \"}"; o="${o%%\$\{DEPLOY_WHY*}"; o="${o%%\$DEPLOY_WHY*}"
          o="$(sed -E 's/\$\{[A-Za-z0-9_]+:0:7\}/abc1234/g' <<<"$o")"   # a short sha prints 7 characters
          { [ "${#o}" -gt 80 ] || grep -q 'GREEN' <<<"$o"; } && printf '%s; ' "$o"; done <<<"$DIES")"
check "every one puts the reason within its first 80 characters, before \$GREEN" "" "$late"
check "no STOPPED line says 'read the error, it explains itself'" 0 "$(grep -v '^#' "$LAND" | grep -c 'read the error, it explains itself')"
# The D1 list reads its own output; DEPLOY_WHY must survive it (a $( ) subshell would drop it).
D1="$(sed -n '/^# --- d1 begin/,/^# --- d1 end/p' "$LAND")"
why="$( eval "$BLOCK"; eval "$D1"; D1_PREMERGE=db; deploy_at() { DEPLOY_WHY="NAMED STOP [DISK_LOW] test"; return 1; }
        d1_none_pending abc >/dev/null 2>&1; printf '%s' "$DEPLOY_WHY" )"
check "a failed D1 list hands its reason to the caller" "NAMED STOP [DISK_LOW] test" "$why"
why="$( eval "$BLOCK"; eval "$D1"; D1_PREMERGE=db; deploy_at() { echo "1 pending: 0026.sql"; return 0; }
        d1_none_pending abc >/dev/null 2>&1; printf '%s' "$DEPLOY_WHY" )"
check "a D1 list with a migration pending says what wrangler said" yes "$(has "$why" "1 pending: 0026.sql")"

echo "== no deploy route silences npm"
ROUTES="$(sed -n '/^# --- routes begin/,/^# --- routes end/p' "$LAND")"
names="$(grep -oE '^  [a-z0-9][a-z0-9._-]*\)' <<<"$ROUTES" | tr -d ' )' | sort -u)"
check "the routes block lists repos (not zero)" yes "$([ "$(grep -c . <<<"$names")" -ge 10 ] && echo yes || echo no)"
loud=0; silenced=""
for n in $names; do
  cmds="$( die() { :; }; NAME="$n"; DEPLOY=""; STAGING=""; eval "$ROUTES" >/dev/null 2>&1; printf '%s\n%s' "$DEPLOY" "$STAGING" )"
  if grep -qE 'npm (run )?(-s|--silent|--loglevel[= ]silent)( |$)' <<<"$cmds"; then silenced="$silenced $n"; fi
  grep -q 'loglevel=error' <<<"$cmds" && loud=$((loud+1))
done
check "no route's deploy or staging command runs npm silenced" "" "$silenced"
check "  ... and the vault-run routes (boss-os, aplayer-mode) say --loglevel=error" yes "$([ "$loud" -ge 2 ] && echo yes || echo "no: $loud")"

echo "== free space is read before any install"
: > "$W/npm-calls"; rm -f "$W/ran"
r="$(FAKE_DF_KB=2097152 run a 'touch "$W/ran"')"
check "2 GB free: refused, named" yes "$(has "$r" "1|NAMED STOP [DISK_LOW] only 2 GB free")"
check "  ... nothing installed, nothing deployed, no worktree" "0 no 1" "$(grep -c . "$W/npm-calls") $([ -e "$W/ran" ] && echo yes || echo no) $(wts)"
r="$(FAKE_DF_KB=fail run a 'touch "$W/ran"')"
check "free space unreadable: refused, never 'enough'" yes "$(has "$r" "1|NAMED STOP [DISK_UNREADABLE]")"
check "  ... nothing installed, nothing deployed" "0 no" "$(grep -c . "$W/npm-calls") $([ -e "$W/ran" ] && echo yes || echo no)"
r="$(FAKE_DF_KB=4194303 run a 'true')"
check "one KB under the 4 GB floor: refused" yes "$(has "$r" "1|NAMED STOP [DISK_LOW]")"
r="$(FAKE_DF_KB=4194304 run a 'true')"
check "exactly the 4 GB floor: goes ahead" "0|" "$r"
# node_modules linked from this checkout (same lockfile): nothing is installed, so free space is not read.
mkdir "$REPO/node_modules"; : > "$W/npm-calls"
r="$(FAKE_DF_KB=2097152 run a 'echo shipped')"
check "2 GB free but node_modules linked (no install): goes ahead" "0|" "$r"
check "  ... and npm never ran" 0 "$(grep -c . "$W/npm-calls")"
rmdir "$REPO/node_modules"

echo "== one local deploy at a time on this Mac"
mkdir -p "$W/lock"; rm -rf "$W/busy"; : > "$W/overlap"
CMD='mkdir "$W/busy" 2>/dev/null || echo OVERLAP >> "$W/overlap"; sleep 2; rmdir "$W/busy" 2>/dev/null; true'
run a "$CMD" > "$W/r1" & p1=$!
sleep 0.3
run b "$CMD" > "$W/r2" & p2=$!
wait "$p1" "$p2"
check "two overlapping lands: both deployed" "0| 0|" "$(cat "$W/r1") $(cat "$W/r2")"
check "  ... one after the other, never at once" 0 "$(grep -c OVERLAP "$W/overlap")"
check "  ... and the second said it was waiting" yes "$(grep -q 'waiting: another local deploy' "$W/out-b" && echo yes || echo no)"
# A deploy that holds the lock past the wait: the second stops, named, and runs nothing.
hold() { exec perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; print "held\n"; $| = 1; sleep $ARGV[1]' "$W/lock/deploy.lock" "$1"; }
hold 30 > "$W/held" & hp=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$W/held" 2>/dev/null && break; sleep 0.2; done
rm -f "$W/ran"
r="$(LAND_DEPLOY_WAIT=2 run a 'touch "$W/ran"')"
check "the lock held past the wait: refused, named" yes "$(has "$r" "1|NAMED STOP [DEPLOY_SLOT_BUSY]")"
check "  ... and nothing was deployed" no "$([ -e "$W/ran" ] && echo yes || echo no)"
# The holder dies (power cut, kill -9): no stale lock, the next deploy goes at once.
kill -9 "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
s=$SECONDS; r="$(LAND_DEPLOY_WAIT=2 run a 'true')"
check "a killed holder leaves no stale lock" "0|" "$r"
check "  ... and the next deploy did not wait" yes "$([ $((SECONDS - s)) -lt 2 ] && echo yes || echo "no: $((SECONDS - s)) s")"
# A deploy that leaves a child running (a wrangler or esbuild daemon) must not keep the lock.
r="$(run a 'sleep 6 >/dev/null 2>&1 & echo started')"
s=$SECONDS; r2="$(LAND_DEPLOY_WAIT=3 run b 'true')"
check "a child the deploy left running does not hold the lock" "0| 0|" "$r $r2"
check "  ... and the next deploy did not wait" yes "$([ $((SECONDS - s)) -lt 2 ] && echo yes || echo "no: $((SECONDS - s)) s")"
# 22 Nov 2026 review F3: a child that keeps the deploy's OUTPUT open (no redirect) keeps tee alive; a tee that
# inherited fd 9 kept the lock after its land died, and the next land waited, then stopped DEPLOY_SLOT_BUSY.
PATH="$W/bin:$PATH" TMPDIR="$W/tmp" LAND_DEPLOY_LOCK="$W/lock/deploy.lock" "$W/run.sh" a 'sleep 7 & echo started; sleep 7' > "$W/r3" & lp=$!
for _ in $(seq 1 50); do grep -q started "$W/out-a" 2>/dev/null && break; sleep 0.1; done
kill -9 "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
s=$SECONDS; r="$(LAND_DEPLOY_WAIT=3 run b 'true')"
check "its land killed, a child still holding the deploy's output: the lock is free" "0|" "$r"
check "  ... and the next deploy did not wait" yes "$([ $((SECONDS - s)) -lt 2 ] && echo yes || echo "no: $((SECONDS - s)) s")"
r="$(LAND_DEPLOY_LOCK="$W/ro/x/deploy.lock" PATH="$W/bin:$PATH" TMPDIR="$W/tmp" bash -c 'mkdir -p "$W/ro"; chmod 500 "$W/ro"; "$W/run.sh" a true')"
chmod 700 "$W/ro" 2>/dev/null
if [ "$(id -u)" = 0 ]; then echo "  skip the unopenable lock (root writes anywhere)"; else
check "a lock that cannot be opened: refused, never 'free'" yes "$(has "$r" "1|NAMED STOP [DEPLOY_LOCK_UNAVAILABLE]")"; fi

echo
if [ "$fails" -gt 0 ]; then echo "FAIL test-land-local-ship: $fails failed, $passes passed"; exit 1; fi
[ "$passes" -ge 30 ] || { echo "FAIL test-land-local-ship: only $passes checks ran"; exit 1; }
echo "PASS test-land-local-ship: $passes checks"
