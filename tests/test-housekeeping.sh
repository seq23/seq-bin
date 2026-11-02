#!/bin/bash
# Behaviour test for housekeeping.sh against a fake HOME and a stub Open Loops intake (no Boss OS, no
# vault). Proves: an old unsaved edit opens a row with paths and counts only; a clean checkout closes
# its row; a running agent's worktree is left alone; a held-back backup folder is her row; a backup
# stop in today's log is Claude's row; a 2,001-word CLAUDE.md opens the monthly rules row once; a
# failed post or a missing token is a named stop with a non-zero exit.
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/housekeeping.sh"
T=$(mktemp -d)
export HOME="$T" HOUSEKEEPING_NO_VAULT=1 HOUSEKEEPING_TODAY=2026-11-02 BOSS_OPEN_LOOPS_TOKEN=olt_test
G=(git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false)
fail=0; bad(){ echo "FAIL: $1"; fail=1; }

# The stub intake: records each body as one line; answers 500 while $T/down exists.
cat > "$T/stub.mjs" <<'JS'
import http from "node:http"; import fs from "node:fs";
const dir = process.argv[2];
http.createServer((req, res) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => {
  if (fs.existsSync(`${dir}/down`)) { res.writeHead(500); return res.end("down"); }
  fs.appendFileSync(`${dir}/posts.jsonl`, b + "\n");
  res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ ok: true, data: { action: JSON.parse(b).cleared ? "closed" : "opened" } }));
}); }).listen(0, "127.0.0.1", function () { fs.writeFileSync(`${dir}/port`, String(this.address().port)); });
JS
node "$T/stub.mjs" "$T" & STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "FAIL: stub intake did not start"; exit 1; }
OPEN_LOOPS_URL="http://127.0.0.1:$(cat "$T/port")/intake"; export OPEN_LOOPS_URL

mkrepo(){ mkdir -p "$1"; "${G[@]}" -C "$1" init -q; echo base > "$1/a.txt"; "${G[@]}" -C "$1" add a.txt; "${G[@]}" -C "$1" commit -qm base; }
mkrepo "$T/bin"; mkrepo "$T/GitHub/dirty"; mkrepo "$T/GitHub/clean"; mkrepo "$T/GitHub/.wt-agent"
echo "PRIVATE-CONTENT-NEVER-POSTED" > "$T/GitHub/dirty/a.txt"; touch -t 202001010000 "$T/GitHub/dirty/a.txt"
echo new > "$T/GitHub/dirty/b.txt"; touch -t 202001020000 "$T/GitHub/dirty/b.txt"
echo old > "$T/GitHub/.wt-agent/a.txt"; touch -t 202001010000 "$T/GitHub/.wt-agent/a.txt"; echo fresh > "$T/GitHub/.wt-agent/c.txt"
mkdir -p "$T/.claude" "$T/Library/Application Support/drive-backup" "$T/Library/Logs/drive-backup"
for _ in $(seq 1 100); do printf 'word '; done > "$T/.claude/CLAUDE.md"
printf 'Misc/dump\n' > "$T/Library/Application Support/drive-backup/needs-decision.txt"
echo "NAMED STOP: DRIVE_BACKUP_FAILED — see the log" > "$T/Library/Logs/drive-backup/2026-11-02.log"

row(){ grep "\"stop\":\"$1\"" "$T/posts.jsonl"; }
opened(){ row "$1" | grep -qv '"cleared":true'; }
cleared(){ row "$1" | grep -q '"cleared":true'; }

# Run 1: dirty old checkout, clean checkout, agent worktree, held-back folder, failed backup.
out=$(bash "$S" 2>&1); rc=$?
[ $rc -eq 0 ] || bad "run 1 exit $rc: $out"
opened UNSAVED_GITHUB_DIRTY || bad "old unsaved edits opened no row"
row UNSAVED_GITHUB_DIRTY | grep -q 'Unsaved edits in ~/GitHub/dirty (2 files, oldest 2019-12-31\|Unsaved edits in ~/GitHub/dirty (2 files, oldest 2020-01-01' || bad "row title lacks path, count or oldest date: $(row UNSAVED_GITHUB_DIRTY)"
row UNSAVED_GITHUB_DIRTY | grep -q '"owner":"claude".*"business":"personal".*"next_date":"2026-11-03"' || bad "row owner/business/next_date wrong"
grep -q PRIVATE-CONTENT "$T/posts.jsonl" && bad "file contents were posted"
cleared UNSAVED_GITHUB_CLEAN || bad "clean checkout did not clear its row"
cleared UNSAVED_BIN || bad "clean ~/bin did not clear its row"
row UNSAVED_GITHUB_WT_AGENT >/dev/null && bad "running agent's worktree was posted"
opened BACKUP_BIG_FOLDER || bad "held-back folder opened no row"
row BACKUP_BIG_FOLDER | grep -q '"owner":"sequoia"' || bad "held-back folder row is not hers"
row BACKUP_BIG_FOLDER | grep -q 'Misc/dump' || bad "held-back folder row does not name the folder"
opened BACKUP_FAILED || bad "backup stop in today's log opened no row"
row BACKUP_FAILED | grep -q '"owner":"claude"' || bad "backup stop row is not Claude's"
cleared BACKUP_TOO_SLOW || bad "absent backup stop not cleared"
row RULES_CLEANUP_2026_11 >/dev/null && bad "rules row posted at 100 words on the 2nd"
[ -n "$(git -C "$T/GitHub/dirty" status --short)" ] || bad "the job changed the dirty checkout"

# Run 1b: 2,500 words is at the limit, not over it (her call 2 Nov 2026: the trigger is 2,500) → no row.
for _ in $(seq 1 2500); do printf 'word '; done > "$T/.claude/CLAUDE.md"
: > "$T/posts.jsonl"; bash "$S" >/dev/null 2>&1 || bad "run 1b exit non-zero"
row RULES_CLEANUP_2026_11 >/dev/null && bad "rules row posted at 2,500 words"

# Run 2: CLAUDE.md at 2,501 words → the month's rules row, once.
for _ in $(seq 1 2501); do printf 'word '; done > "$T/.claude/CLAUDE.md"
: > "$T/posts.jsonl"; bash "$S" >/dev/null 2>&1 || bad "run 2 exit non-zero"
opened RULES_CLEANUP_2026_11 || bad "2,501-word CLAUDE.md opened no rules row"
row RULES_CLEANUP_2026_11 | grep -q 'over 2,500 words, 2,501 words' || bad "rules row title wrong: $(row RULES_CLEANUP_2026_11)"
: > "$T/posts.jsonl"; bash "$S" >/dev/null 2>&1 || bad "run 3 exit non-zero"
row RULES_CLEANUP_2026_11 >/dev/null && bad "rules row posted twice in one month"

# Run 4: everything saved, folder decided, backup clean → every row closes.
"${G[@]}" -C "$T/GitHub/dirty" checkout -q -- a.txt; rm "$T/GitHub/dirty/b.txt"
rm "$T/Library/Application Support/drive-backup/needs-decision.txt"; echo "drive-backup OK" > "$T/Library/Logs/drive-backup/2026-11-02.log"
: > "$T/posts.jsonl"; bash "$S" >/dev/null 2>&1 || bad "run 4 exit non-zero"
cleared UNSAVED_GITHUB_DIRTY || bad "saved checkout did not clear its row"
opened UNSAVED_GITHUB_DIRTY && bad "saved checkout still posted as unsaved"
cleared BACKUP_BIG_FOLDER || bad "decided folder did not clear its row"
cleared BACKUP_FAILED || bad "clean backup did not clear the failure row"

# Run 5: Boss OS down → named stop, non-zero. Run 6: no token → named stop, non-zero.
touch "$T/down"; out=$(bash "$S" 2>&1); rc=$?; rm "$T/down"
[ $rc -ne 0 ] || bad "failed post exited 0"
grep -q 'NAMED STOP \[OPEN_LOOPS_POST_FAILED\]' <<<"$out" || bad "failed post gave no named stop"
out=$(BOSS_OPEN_LOOPS_TOKEN='' bash "$S" 2>&1); rc=$?
[ $rc -ne 0 ] || bad "missing token exited 0"
grep -q 'NAMED STOP \[OPEN_LOOPS_TOKEN_MISSING\]' <<<"$out" || bad "missing token gave no named stop"

[ $fail -eq 0 ] && echo "test-housekeeping: ok"
exit $fail
