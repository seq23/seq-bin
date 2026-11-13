#!/bin/bash
# The probe leaves the last of the hour's GitHub calls to land (13 Nov 2026).
#   low   — 100 calls left, then 4000 after one wait → the probe waits once, THEN reads the repo list
#   high  — 4000 left → no wait, reads at once
#   blind — rate_limit cannot be read → no wait (the reads have their own stops)
# Driven against a fake `gh` and a fake `sleep`; the fake repo list is empty, so the probe ends on
# its own NAMED STOP [NO_REPO_LIST] right after the part under test. RULE 0: three cases or fail.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/ci-sweep-probe.sh"
[ -x "$PROBE" ] || { echo "FAIL: $PROBE missing"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/gh"
printf '#!/bin/bash\necho sleep >> "$CALLS"\nexit 0\n' > "$TMP/bin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/triggers"
cat > "$TMP/bin/gh" <<'S'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api rate_limit")
    echo rate >> "$CALLS"
    case "$FAKE_RATE" in
      blind) echo 'HTTP 502' >&2; exit 1 ;;
      high)  echo 4000 ;;
      low)   if [ "$(grep -c rate "$CALLS")" -le 1 ]; then echo 100; else echo 4000; fi ;;
    esac ;;
  "repo list") echo repolist >> "$CALLS" ;;
esac
exit 0
S
chmod +x "$TMP/bin/"*
cases=0; fail=0
run() { # <mode> <expected call order>
  export CALLS="$TMP/calls-$1"; : > "$CALLS"
  out="$(FAKE_RATE="$1" PATH="$TMP/bin:$PATH" CI_SWEEP_TRIGGERS_BIN="$TMP/bin/triggers" CI_SWEEP_GITHUB_DIR="$TMP/gh" "$PROBE" 2>&1)"
  got="$(tr '\n' ' ' < "$CALLS" | sed 's/ $//')"
  cases=$((cases + 1))
  if [ "$got" = "$2" ]; then echo "ok   $1: $got"; else echo "FAIL $1: calls were [$got], expected [$2]"; echo "$out" | tail -3; fail=1; fi
}
run low   "rate sleep rate repolist"
run high  "rate repolist"
run blind "rate repolist"
[ "$cases" -eq 3 ] || { echo "FAIL: $cases of 3 cases ran"; exit 1; }
exit "$fail"
