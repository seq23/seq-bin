#!/bin/bash
# ci-status, test-quiet and pr-brief against a fake gh: a red always names its check and a line, an outage
# or an empty check list is "couldn't check" (never green), a failing test keeps its exit code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# The fake gh answers from files the case writes: $W/checks (JSON, or the word OUTAGE), $W/log, $W/view.
cat > "$W/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"--watch"*) exit 0 ;;
  "pr checks"*) if grep -qx OUTAGE "$W/checks"; then echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; fi
                if grep -qx EMPTY "$W/checks"; then echo "no checks reported on the 'x' branch" >&2; exit 1; fi
                cat "$W/checks" ;;
  "run view"*) [ -f "$W/log" ] && cat "$W/log" || exit 1 ;;
  "pr view"*) if [ -f "$W/view" ]; then cat "$W/view"; else echo "HTTP 502" >&2; exit 1; fi ;;
  *) echo "fake gh: unexpected call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$W/bin/gh"
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
cs() { PATH="$W/bin:$PATH" "$ROOT/ci-status" o/r 7 "$@" 2>&1; }
chk() { # name want_rc got_rc out must_match [must_not_match]
  if [ "$2" = "$3" ] && grep -qE -- "$5" <<<"$4" && { [ -z "${6:-}" ] || ! grep -qiE -- "$6" <<<"$4"; }; then ok "$1"; else bad "$1 (rc $3: $4)"; fi
}

echo '[{"name":"validate","bucket":"pass","link":"","workflow":"v"},{"name":"lint","bucket":"skipping","link":"","workflow":"v"},{"name":"deploy","bucket":"pass","link":"","workflow":"v"}]' > "$W/checks"
out="$(cs)"; chk "all green is N/N green, exit 0" 0 $? "$out" '^3/3 green$'

printf 'validate\tRun tests\t2026-11-28T10:00:00.1Z   ok   first\nvalidate\tRun tests\t2026-11-28T10:00:01.0Z   FAIL test-land-flow: merged nothing\nvalidate\tRun tests\t2026-11-28T10:00:02.0Z ##[error]Process completed with exit code 1.\n' > "$W/log"
echo '[{"name":"validate","bucket":"fail","link":"https://github.com/o/r/actions/runs/1/job/42","workflow":"v"},{"name":"deploy","bucket":"pass","link":"","workflow":"v"}]' > "$W/checks"
out="$(cs)"; chk "red names its check and the first failing line, exit 1" 1 $? "$out" '^first red: validate — FAIL test-land-flow: merged nothing \(https://' 'green'
out="$(cs --full)"; chk "--full shows every check and the whole failed log" 1 $? "$out" 'ok   first'

rm -f "$W/log"
out="$(cs)"; chk "red with an unreadable log still names its check" 1 $? "$out" '^first red: validate — its failed log could not be read' 'green'
echo '[{"name":"vercel","bucket":"cancel","link":"https://vercel.com/x","workflow":""}]' > "$W/checks"
out="$(cs)"; chk "a cancelled outside check is red, named" 1 $? "$out" '^first red: vercel — no Actions log' 'green'

echo OUTAGE > "$W/checks"
out="$(cs)"; chk "gh outage is couldn't check, exit 75, never green" 75 $? "$out" "^couldn't check: gh did not answer.*502" 'green'
echo EMPTY > "$W/checks"
out="$(cs)"; chk "no checks reported is couldn't check, never green" 75 $? "$out" "^couldn't check: (gh did not answer|no checks)" 'green'
echo '[]' > "$W/checks"
out="$(cs)"; chk "an empty list is couldn't check, never 0/0 green" 75 $? "$out" "^couldn't check: no checks reported" 'green'
echo '[{"name":"a","bucket":"pass","link":"","workflow":""},{"name":"b","bucket":"mystery","link":"","workflow":""}]' > "$W/checks"
out="$(cs)"; chk "an unknown bucket is couldn't check, never green" 75 $? "$out" "^couldn't check: 1 of 2" '^[0-9]+/[0-9]+ green'
echo '[{"name":"a","bucket":"pass","link":"","workflow":""},{"name":"e2e","bucket":"pending","link":"","workflow":""}]' > "$W/checks"
out="$(cs)"; chk "pending names what is running, exit 2" 2 $? "$out" '^pending: 1 of 2 still running \(e2e\); 1 green$'
echo '[{"name":"a","bucket":"pass","link":"","workflow":""}]' > "$W/checks"
out="$(cs --wait 5)"; chk "--wait ends on the one line" 0 $? "$out" '^1/1 green$'
out="$(PATH="$W/bin:$PATH" "$ROOT/ci-status" o/r 2>&1)"; chk "no PR number is a usage stop" 64 $? "$out" 'usage'

# --- test-quiet -----------------------------------------------------------------------------------------
export TEST_QUIET_DIR="$W/tq"
out="$("$ROOT/test-quiet" bash -c 'for i in 1 2 3; do echo "  ok   case $i"; done; echo "PASS test-x (3)"')"
chk "a passing run is one line with its last line and a log path" 0 $? "$out" '^passed \(exit 0\): PASS test-x \(3\) \[4 lines\] — log /'
logp="${out##*log }"; [ -s "$logp" ] && grep -q 'case 2' "$logp" && ok "the log file holds the whole output" || bad "the log file holds the whole output ($logp)"
out="$("$ROOT/test-quiet" bash -c 'echo "  ok   a"; echo "  FAIL b: wanted 1 got 2"; echo "  FAIL c"; echo "FAIL test-x (2)"; exit 3')"
chk "a failing run keeps its exit code and names the FIRST failure" 3 $? "$out" '^FAILED \(exit 3\): first failure: FAIL b: wanted 1 got 2 — log /' '^passed'
out="$("$ROOT/test-quiet" bash -c 'echo something odd; exit 1')"
chk "a failure with no marker shows its last line" 1 $? "$out" '^FAILED \(exit 1\): first failure: something odd'
out="$("$ROOT/test-quiet" true)"
chk "a run that printed nothing says so" 0 $? "$out" 'printed nothing'
out="$(TEST_QUIET_SECS=1 "$ROOT/test-quiet" sleep 5)"
chk "a run past its bound is TIMED OUT, exit 124" 124 $? "$out" '^TIMED OUT \(exit 124\)'
out="$("$ROOT/test-quiet" --full bash -c 'echo line-one; echo line-two')"
chk "--full prints the whole output too" 0 $? "$out" 'line-one'

# --- pr-brief -------------------------------------------------------------------------------------------
cat > "$W/view" <<'EOF'
{"number":7,"title":"A change","state":"OPEN","isDraft":false,"author":{"login":"seq23"},"headRefOid":"abc1234def","headRefName":"b","baseRefName":"main","additions":10,"deletions":2,"changedFiles":2,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","comments":[{"author":{"login":"rev"},"body":"Ship-ready: PASS — r looked at x at abc1234; Engineering: PASS"}],"files":[{"path":"a.sh","additions":9,"deletions":1},{"path":"b.md","additions":1,"deletions":1}]}
EOF
out="$(PATH="$W/bin:$PATH" "$ROOT/pr-brief" o/r 7)"; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <<<"$out" | tr -d ' ')" = 5 ] && grep -q '^checks: 1/1 green$' <<<"$out" && grep -q 'a PASS line names head abc1234' <<<"$out" && grep -q '^files: a.sh (+9/−1), b.md' <<<"$out" \
  && ok "pr-brief is 5 lines: head, size, checks, review, files" || bad "pr-brief 5 lines (rc $rc: $out)"
echo OUTAGE > "$W/checks"
out="$(PATH="$W/bin:$PATH" "$ROOT/pr-brief" o/r 7)"
grep -q "^checks: couldn't check" <<<"$out" && ok "pr-brief carries ci-status's couldn't check" || bad "pr-brief outage ($out)"
rm -f "$W/view"
out="$(PATH="$W/bin:$PATH" "$ROOT/pr-brief" o/r 7)"; chk "an unreadable PR is couldn't read, exit 75" 75 $? "$out" "^couldn't read o/r#7"

[ "$fails" -eq 0 ] && echo "PASS test-quiet-helpers" || { echo "FAIL test-quiet-helpers ($fails)"; exit 1; }
