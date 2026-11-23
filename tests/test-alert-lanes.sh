#!/bin/bash
# ci-sweep-alert-lanes.sh turns GitHub's security findings on the Divine 10 repos into sweep lanes
# (23 Nov 2026, her words: "every repo that is a divine 10 business should get locked down and an
# audit"). Driven against a fake `gh` (no network, no credentials). It must:
#   - make each of the 3 alert types (code scanning, secret scanning, Dependabot) a RED lane
#     carrying its count, and the ruleset a RED lane when a rule is gone;
#   - never call an unread list clean: 403/404 is RED (scanner off or no access), a rate limit,
#     5xx or a reply that is not JSON is PENDING (unknown), and CodeQL with no completed analysis
#     is RED NO_CODEQL_ANALYSIS even with 0 alerts;
#   - never print a leaked secret's value, never say "run #" (FIXED-UNVERIFIED would dispatch it);
#   - honour CI_SWEEP_ONLY_REPOS, read every page, and stop by name on a missing or empty config;
#   - and the real ci-sweep-security.json is the 12 repos, with the ruleset and no person bypass.
# RULE 0: zero assertions run is a failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANES="$ROOT/ci-sweep-alert-lanes.sh"
[ -x "$LANES" ] || { echo "FAIL: $LANES missing or not executable"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
SECRET_VALUE='sk-proj-FAKEVALUE-must-never-reach-a-lane-0123456789'
export SECRET_VALUE

cat > "$TMP/config.json" <<'J'
{"ruleset":{"name":"main rules","rules":[{"type":"deletion"},{"type":"non_fast_forward"}],"bypass_actors":[]},
 "repos":[{"repo":"seq23/alpha","protect":true},{"repo":"seq23/lovable","protect":false,"why_not":"Lovable"}]}
J

# Fake gh: FAKE_<KIND> picks the answer for one kind of read; the default is a clean repo.
#   seeded | clean | 403 | 404 | rate | 502 | garbage   (FAKE_ANALYSES: ok | empty | ...)
cat > "$TMP/bin/gh" <<'S'
#!/bin/bash
[ "$1" = api ] || exit 1
slurp=0; path=""
for a in "$@"; do case "$a" in --slurp) slurp=1 ;; api|--paginate) ;; *) path="$a" ;; esac; done
case "$path" in
  */code-scanning/analyses*) mode="${FAKE_ANALYSES:-ok}" ;;
  */code-scanning/alerts*)   mode="${FAKE_CODE:-clean}" ;;
  */secret-scanning/alerts*) mode="${FAKE_SECRET:-clean}" ;;
  */dependabot/alerts*)      mode="${FAKE_DEPS:-clean}" ;;
  */rules/branches/*)        mode="${FAKE_RULES:-ok}" ;;
  repos/*)                   mode="${FAKE_REPO:-ok}" ;;
  *) echo "fake gh: unexpected $path" >&2; exit 1 ;;
esac
fail() { echo "{\"message\":\"$2\"}"; echo "gh: $2 (HTTP $1)" >&2; exit 1; }
case "$mode" in
  403) fail 403 "Resource not accessible by integration" ;;
  404) fail 404 "Not Found" ;;
  rate) fail 403 "API rate limit exceeded for user" ;;
  502) fail 502 "Bad Gateway" ;;
  garbage) echo '<html>unicorn</html>'; exit 0 ;;
esac
case "$path" in
  */code-scanning/analyses*) [ "$mode" = empty ] && body='[]' || body='[{"id":11}]' ;;
  */code-scanning/alerts*)
    if [ "$mode" = seeded ]; then
      body='[{"number":7,"rule":{"id":"js/xss","security_severity_level":"high"},"most_recent_instance":{"location":{"path":"src/a.js","start_line":3}}},
             {"number":9,"rule":{"id":"actions/missing-workflow-permissions","severity":"warning","security_severity_level":"medium"},"most_recent_instance":{"location":{"path":".github/workflows/ci.yml","start_line":1}}}]'
    else body='[]'; fi ;;
  */secret-scanning/alerts*)
    if [ "$mode" = seeded ]; then
      body="[{\"number\":1,\"secret_type\":\"openai_api_key\",\"secret_type_display_name\":\"OpenAI API Key\",\"secret\":\"$SECRET_VALUE\",\"publicly_leaked\":true,\"html_url\":\"https://github.com/seq23/alpha/security/secret-scanning/1\"}]"
    else body='[]'; fi ;;
  */dependabot/alerts*)
    if [ "$mode" = seeded ]; then
      body='[{"number":3,"dependency":{"package":{"name":"next"},"manifest_path":"package-lock.json"},"security_advisory":{"severity":"critical"},"security_vulnerability":{"first_patched_version":{"identifier":"14.2.35"}}},
             {"number":4,"dependency":{"package":{"name":"tar"},"manifest_path":"package-lock.json"},"security_advisory":{"severity":"high"},"security_vulnerability":{"first_patched_version":null}}]'
    elif [ "$mode" = paged ]; then
      [ "$slurp" = 1 ] && { echo '[[{"number":1,"dependency":{"package":{"name":"a"},"manifest_path":"p"},"security_advisory":{"severity":"low"},"security_vulnerability":{}}],[{"number":2,"dependency":{"package":{"name":"b"},"manifest_path":"p"},"security_advisory":{"severity":"low"},"security_vulnerability":{}}]]'; exit 0; }
      body='[{"number":1}]'
    else body='[]'; fi ;;
  */rules/branches/*)
    case "$mode" in
      ok) body='[{"type":"deletion","ruleset_id":1},{"type":"non_fast_forward","ruleset_id":1},{"type":"deletion","ruleset_id":2}]' ;;
      partial) body='[{"type":"deletion","ruleset_id":1}]' ;;
      none) body='[]' ;;
    esac ;;
  repos/*) body='{"default_branch":"main"}' ;;
esac
if [ "$slurp" = 1 ]; then printf '[%s]\n' "$body"; else printf '%s\n' "$body"; fi
S
chmod +x "$TMP/bin/gh"

n=0; fails=0
run() { PATH="$TMP/bin:$PATH" CI_SWEEP_SECURITY_CONFIG="${CFG:-$TMP/config.json}" "$LANES" >"$TMP/out" 2>"$TMP/err"; echo $? >"$TMP/rc"; }
has() { # <description> <ERE that must match one line of the output>
  n=$((n+1))
  if grep -qE "$2" "$TMP/out"; then echo "  ok   $1"; else echo "  FAIL $1 — no line matches '$2'; got:"; sed 's/^/         /' "$TMP/out" "$TMP/err"; fails=$((fails+1)); fi
}
hasnt() {
  n=$((n+1))
  if grep -qE "$2" "$TMP/out" "$TMP/err"; then echo "  FAIL $1 — found '$2':"; grep -E "$2" "$TMP/out" "$TMP/err" | sed 's/^/         /'; fails=$((fails+1)); else echo "  ok   $1"; fi
}
rc_is() { n=$((n+1)); if [ "$(cat "$TMP/rc")" = "$2" ]; then echo "  ok   $1"; else echo "  FAIL $1 — rc $(cat "$TMP/rc"), want $2"; sed 's/^/         /' "$TMP/err"; fails=$((fails+1)); fi; }
T=$'\t'

echo "=== every open alert type is fix work ==="
FAKE_CODE=seeded FAKE_SECRET=seeded FAKE_DEPS=seeded run
rc_is "exits 0 after printing" 0
has "code scanning: RED with its count and the rule and file" "^RED${T}alpha${T}security: code-scanning${T}alpha\|security\|code-scanning\|2\|[0-9]+${T}2 open .*js/xss src/a.js:3"
has "secret scanning: RED naming the key type and alert URL" "^RED${T}alpha${T}security: secret-scanning${T}alpha\|security\|secret-scanning\|1\|.*OpenAI API Key \(publicly leaked\) https://github.com/seq23/alpha/security/secret-scanning/1"
has "Dependabot: RED with severity, package and fixed version" "^RED${T}alpha${T}security: dependabot${T}alpha\|security\|dependabot\|2\|.*1 critical.*next critical in package-lock.json \(fixed in 14.2.35\).*tar high .*\(no fix yet\)"
has "the Lovable repo's alerts are read too" "^RED${T}lovable${T}security: secret-scanning${T}"
has "the ruleset is GREEN when both rules are live" "^GREEN${T}alpha${T}security: ruleset${T}alpha\|security\|ruleset\|OK"
hasnt "a leaked secret's value never reaches a lane or the log" "$SECRET_VALUE"
hasnt "no lane says 'run #' (FIXED-UNVERIFIED would try to dispatch it)" 'run #'
hasnt "a protect=false repo gets no ruleset lane" "^[A-Z]+${T}lovable${T}security: ruleset"
n=$((n+1)); if [ "$(grep -c . "$TMP/out")" = 7 ]; then echo "  ok   exactly 7 lanes (4 + 3)"; else echo "  FAIL $(grep -c . "$TMP/out") lanes, want 7"; fails=$((fails+1)); fi

echo "=== a fix changes the lane's signature (that is the sweep's progress) ==="
cp "$TMP/out" "$TMP/before"
FAKE_CODE=clean FAKE_SECRET=seeded FAKE_DEPS=seeded run
has "fixed code scanning is GREEN" "^GREEN${T}alpha${T}security: code-scanning${T}alpha\|security\|code-scanning\|0"
n=$((n+1)); if [ "$(grep -F 'alpha|security|dependabot' "$TMP/before" | cut -f4)" = "$(grep -F 'alpha|security|dependabot' "$TMP/out" | cut -f4)" ]; then echo "  ok   an unchanged alert set keeps its signature"; else echo "  FAIL an unchanged alert set changed signature"; fails=$((fails+1)); fi

echo "=== clean is GREEN only when read ==="
run
for k in code-scanning secret-scanning dependabot; do has "clean $k is GREEN" "^GREEN${T}alpha${T}security: $k${T}alpha\|security\|$k\|0${T}"; done
hasnt "a clean repo has no RED or PENDING" "^(RED|PENDING)${T}"

echo "=== CodeQL with no completed analysis is not clean ==="
FAKE_ANALYSES=empty run
has "empty analyses → RED NO_CODEQL_ANALYSIS" "^RED${T}alpha${T}security: code-scanning${T}alpha\|security\|code-scanning\|NO_CODEQL_ANALYSIS${T}NAMED STOP \[NO_CODEQL_ANALYSIS\]"
hasnt "empty analyses never print a GREEN code-scanning lane" "^GREEN${T}[a-z]+${T}security: code-scanning"

echo "=== an unread list is never clean ==="
for kind in ANALYSES CODE SECRET DEPS; do
  case "$kind" in ANALYSES|CODE) lane=code-scanning ;; SECRET) lane=secret-scanning ;; DEPS) lane=dependabot ;; esac
  for m in 403 404; do
    env "FAKE_$kind=$m" bash -c "$(declare -f run); TMP='$TMP' LANES='$LANES' run"
    # GitHub answers 404 on analyses when CodeQL never ran, so off/refused analyses is NO_CODEQL_ANALYSIS.
    stop=SCANNING_OFF_OR_NO_ACCESS; [ "$kind" = ANALYSES ] && stop=NO_CODEQL_ANALYSIS
    has "$kind $m → RED $stop" "^RED${T}alpha${T}security: $lane${T}alpha\|security\|$lane\|$stop${T}NAMED STOP"
    hasnt "$kind $m → no GREEN $lane" "^GREEN${T}alpha${T}security: $lane${T}"
  done
  env "FAKE_$kind=rate" bash -c "$(declare -f run); TMP='$TMP' LANES='$LANES' run"
  has "$kind rate limit → PENDING ALERTS_RATE_LIMITED" "^PENDING${T}alpha${T}security: $lane${T}alpha\|security\|$lane\|ALERTS_RATE_LIMITED${T}NAMED STOP"
  for m in 502 garbage; do
    env "FAKE_$kind=$m" bash -c "$(declare -f run); TMP='$TMP' LANES='$LANES' run"
    has "$kind $m → PENDING ALERTS_UNREADABLE" "^PENDING${T}alpha${T}security: $lane${T}alpha\|security\|$lane\|ALERTS_UNREADABLE${T}NAMED STOP"
    hasnt "$kind $m → no GREEN $lane" "^GREEN${T}alpha${T}security: $lane${T}"
  done
done

echo "=== the ruleset ==="
FAKE_RULES=partial run
has "a missing rule → RED RULESET_MISSING naming it" "^RED${T}alpha${T}security: ruleset${T}alpha\|security\|ruleset\|MISSING:non_fast_forward${T}NAMED STOP \[RULESET_MISSING\]"
FAKE_RULES=none run
has "no rules → RED naming both" "^RED${T}alpha${T}security: ruleset${T}alpha\|security\|ruleset\|MISSING:deletion,non_fast_forward"
FAKE_RULES=403 run
has "rules unreadable (403) → RED, not GREEN" "^RED${T}alpha${T}security: ruleset${T}alpha\|security\|ruleset\|SCANNING_OFF_OR_NO_ACCESS"
FAKE_REPO=502 run
has "default branch unreadable → PENDING, not GREEN" "^PENDING${T}alpha${T}security: ruleset${T}alpha\|security\|ruleset\|ALERTS_UNREADABLE"

echo "=== every page is read ==="
FAKE_DEPS=paged run
has "two pages of Dependabot alerts count as 2" "^RED${T}alpha${T}security: dependabot${T}alpha\|security\|dependabot\|2\|"

echo "=== scope and config ==="
CI_SWEEP_ONLY_REPOS=lovable run
n=$((n+1)); if [ "$(grep -c . "$TMP/out")" = 3 ] && ! grep -q "${T}alpha${T}" "$TMP/out"; then echo "  ok   CI_SWEEP_ONLY_REPOS reads only that repo"; else echo "  FAIL CI_SWEEP_ONLY_REPOS not honoured"; cat "$TMP/out"; fails=$((fails+1)); fi
CFG="$TMP/missing.json" run
rc_is "a missing config is NAMED STOP exit 3" 3
n=$((n+1)); if grep -q 'NO_SECURITY_CONFIG' "$TMP/err"; then echo "  ok   …named NO_SECURITY_CONFIG"; else echo "  FAIL no NO_SECURITY_CONFIG"; fails=$((fails+1)); fi
echo '{"ruleset":{"rules":[]},"repos":[]}' > "$TMP/empty.json"
CFG="$TMP/empty.json" run
rc_is "a config with zero repos is NAMED STOP exit 3, not a clean fleet" 3

echo "=== the real ci-sweep-security.json ==="
REAL="$ROOT/ci-sweep-security.json"
n=$((n+1))
if jq -e '
  (.repos|length) == 12 and
  ([.repos[].repo]|sort) == (["aplayer-mode","approvalprep","dailystory","dream-wedding-builder","heygetonmylevel","how-we-know","keepmyproof","local-guides-citation-velocity","local-guides-generator","peace-be-still","sprylabs-hpc-site","whisperalmanac-site"]|map("seq23/"+.)) and
  ([.ruleset.rules[].type]|sort) == ["deletion","non_fast_forward"] and
  .ruleset.bypass_actors == [] and .ruleset.enforcement == "active" and
  .ruleset.conditions.ref_name.include == ["~DEFAULT_BRANCH"] and
  all(.repos[]; .protect == true or ((.why_not // "")|length) > 20)' "$REAL" >/dev/null; then
  echo "  ok   12 Divine 10 repos, deletion + non_fast_forward on the default branch, no bypass, every unprotected repo says why"
else echo "  FAIL $REAL is not the 12 repos / ruleset / no-bypass / written reasons"; fails=$((fails+1)); fi

[ "$n" -ge 40 ] || { echo "FAIL: only $n assertions ran"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-alert-lanes: $fails of $n failed"; exit 1; }
echo "test-alert-lanes: $n assertions pass"
