#!/bin/bash
# A workflow missing from the probe's repo-wide run list is NOT a workflow that never ran.
#
# 26 Oct 2026: ci-sweep-probe.sh read `gh run list --branch main --limit 80` for the whole repo.
# On busy repos those 80 runs reached back only to the previous evening, so daily crons that had
# run green that afternoon (local-guides-generator Ingestion Sync / Rotating Refresh, p-n-p Daily
# Authority Cycle) were absent and reported SILENT|NEVER_RAN — lanes no fix could ever clear.
# This drives the probe's REAL network path against a fake `gh` (no network, no credentials):
#   window  — repo-wide list omits the cron, its own run list has a green run → GREEN, exit 0
#   never   — repo-wide list omits it and its own run list is empty → still SILENT|NEVER_RAN, exit 1
#   broken  — its own run list cannot be read → PENDING|RUNS_UNREADABLE, never SILENT, exit 2
# RULE 0: zero cases examined is not a pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/ci-sweep-probe.sh"
[ -x "$PROBE" ] || { echo "FAIL: $PROBE missing"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ago() { date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ; }
export FAKE_RECENT; FAKE_RECENT="$(ago 1)"     # inside the window: Validate's run, the human commit
export FAKE_YESTERDAY; FAKE_YESTERDAY="$(ago 20)" # the cron's green run, outside the newest-80 list

mkdir -p "$TMP/bin" "$TMP/gh/r/.github/workflows"
git -C "$TMP/gh/r" init -q
git -C "$TMP/gh/r" remote add origin https://github.com/seq23/r.git
echo 'on: push' > "$TMP/gh/r/.github/workflows/validate.yml"
echo 'on: {schedule: [{cron: "0 17 * * *"}]}' > "$TMP/gh/r/.github/workflows/ingestion.yml"

cat > "$TMP/bin/sleep" <<'S'
#!/bin/bash
exit 0
S
cat > "$TMP/bin/triggers" <<'S'
#!/bin/bash
printf 'YES\tschedule tick inside the window\n'
S
cat > "$TMP/bin/grid" <<'S'
#!/bin/bash
exit 0
S
cat > "$TMP/bin/gh" <<'S'
#!/bin/bash
# Fake gh for test-probe-window.sh. FAKE_MODE picks what the cron's OWN run list answers.
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo list") echo '[{"name":"r","isArchived":false,"defaultBranchRef":{"name":"main"}}]' ;;
  "workflow list") echo '[{"name":"Validate","state":"active","path":".github/workflows/validate.yml"},{"name":"Ingestion Sync","state":"active","path":".github/workflows/ingestion.yml"}]' ;;
  "run list")
    case " $* " in
      *" --workflow ingestion.yml "*)
        case "$FAKE_MODE" in
          window) printf '[{"workflowName":"Ingestion Sync","conclusion":"success","status":"completed","createdAt":"%s","databaseId":7}]\n' "$FAKE_YESTERDAY" ;;
          never)  echo '[]' ;;
          broken) echo 'HTTP 502' >&2; exit 1 ;;
        esac ;;
      *" --workflow "*) echo '[]' ;;
      *) printf '[{"workflowName":"Validate","conclusion":"success","status":"completed","createdAt":"%s","databaseId":9}]\n' "$FAKE_RECENT" ;;
    esac ;;
  "api "*)
    case "$2" in
      *"commits?path="*) echo '[{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}]' ;;
      *"commits?since="*) printf '[{"sha":"abc","committer":{"type":"User"},"commit":{"committer":{"date":"%s","email":"a@b.c","name":"Person"}}}]\n' "$FAKE_RECENT" ;;
      *"/commits/"*) echo 'README.md' ;;
      *) echo '[]' ;;
    esac ;;
  *) echo '[]' ;;
esac
S
chmod +x "$TMP/bin/"*

n=0; fails=0
case_() { # mode want_rc grep_for_line
  local mode="$1" want="$2" pat="$3" rc
  PATH="$TMP/bin:$PATH" FAKE_MODE="$mode" CI_SWEEP_GITHUB_DIR="$TMP/gh" CI_SWEEP_OWNER=seq23 \
    CI_SWEEP_TRIGGERS_BIN="$TMP/bin/triggers" CI_SWEEP_GRID_LANES_BIN="$TMP/bin/grid" \
    "$PROBE" >"$TMP/out" 2>"$TMP/err"; rc=$?
  n=$((n+1))
  if [ "$rc" = "$want" ] && grep -qE "$pat" "$TMP/out"; then echo "  ok   $mode → $rc ($(grep -E "$pat" "$TMP/out" | cut -f1,3,4 | tr '\t' ' '))"
  else echo "  FAIL $mode → rc $rc (want $want), wanted a line matching '$pat'; got:"; sed 's/^/         /' "$TMP/out"; fails=$((fails+1)); fi
}
case_ window 0 '^GREEN	r	Ingestion Sync	'
case_ never  1 '^SILENT	r	Ingestion Sync	.*NEVER_RAN'
case_ broken 2 '^PENDING	r	Ingestion Sync	.*RUNS_UNREADABLE'

[ "$n" -gt 0 ] || { echo "FAIL: examined zero cases"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-probe-window: $fails failure(s)"; exit 1; }
echo "test-probe-window: $n cases pass"
