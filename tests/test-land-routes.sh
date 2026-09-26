#!/bin/bash
# land must know how every West Peek web property reaches production.
#
# West Peek OS's "web property change" lane (23 Sep 2026) plans, builds and lands a partner's
# requested change in the right repo, and its LAND step is `land <pr>`. A repo with no row in the
# routes case below makes land STOP ("no deploy route recorded") after the work is done — the lane
# would build a fix and then refuse to ship it. This evals the routes block out of `land` verbatim
# for each site repo and checks it yields a real route (a deploy command or a stated self-deploy),
# and that an unknown repo still stops rather than guessing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
BLOCK="$(sed -n '/^# --- routes begin/,/^# --- routes end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the routes block"; exit 1; }

# The site repos the web property change lane targets (plus the grid sites added 25 Sep 2026),
# and the route each must resolve to.
# "self" = deploys itself on merge (DEPLOY empty, SELF set); anything else = the DEPLOY command.
SITES='
westpeek-live|self
join-west-peek-main|self
west-peek-pitch-lab|self
west-peek-network-os|self
secondaries|self
founder-dilution-dashboard|self
west-peek-os|npm run deploy:production
boss-os|npm run deploy:production
horse-legal-guide-velocity|self
WPP-llm|self
approvalprep|self
dream-wedding-builder|self
authority-backlink-network|self
p-n-p|self
justbeingmercedes|self
local-guides-generator|self
sheila-creator-dashboard|npm run deploy:production
'
route_for() { # repo -> "self" | deploy command | "DIED: msg"
  # shellcheck disable=SC2034  # NAME is read by the eval'd routes block
  ( NAME="$1"; DEPLOY=""; SELF=""
    die() { echo "DIED: $*"; exit 0; }
    eval "$BLOCK"
    if [ -n "$DEPLOY" ]; then echo "$DEPLOY"; elif [ -n "$SELF" ]; then echo self; else echo "EMPTY"; fi )
}
fails=0; n=0
while IFS='|' read -r repo want; do
  [ -n "$repo" ] || continue
  n=$((n+1))
  got="$(route_for "$repo")"
  if [ "$got" = "$want" ]; then echo "  ok   $repo → $got"; else echo "  FAIL $repo: expected '$want', got '$got'"; fails=$((fails+1)); fi
done <<< "$SITES"
[ "$n" -gt 0 ] || { echo "FAIL: examined zero site repos"; exit 1; }
got="$(route_for no-such-repo-xyz)"
case "$got" in DIED:*) echo "  ok   unknown repo stops: ${got#DIED: }" ;; *) echo "  FAIL unknown repo did not stop: '$got'"; fails=$((fails+1)) ;; esac
# 26 Sep 2026: the build-first repo carries a staging command and names its full e2e workflow,
# so land deploys staging on every merge and holds production for a green e2e on the sha.
# shellcheck disable=SC2034  # NAME is read by the eval'd routes block
staged="$( ( NAME=sheila-creator-dashboard; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$STAGING|$E2E_WF" ) )"
if [ "$staged" = "npm run deploy:staging|e2e" ]; then echo "  ok   sheila-creator-dashboard stages (npm run deploy:staging) and waits for e2e"
else echo "  FAIL sheila-creator-dashboard route: expected 'npm run deploy:staging|e2e', got '$staged'"; fails=$((fails+1)); fi
# 26 Sep 2026: boss-os names its full e2e workflow (no staging target), so land holds production
# for a green `e2e` on the sha and `land --promote boss-os` ships it. And a route with E2E_WF must
# not take the "wait for the Deploy run" branch: that deploy.yml fires on e2e now, and the newest
# Deploy run on main would be an older commit's. Proven by reading the guard out of land itself.
# shellcheck disable=SC2034  # NAME is read by the eval'd routes block
bossed="$( ( NAME=boss-os; DEPLOY=""; SELF=""; STAGING=""; E2E_WF=""; die() { exit 1; }; eval "$BLOCK"; echo "$STAGING|$E2E_WF" ) )"
if [ "$bossed" = "|e2e" ]; then echo "  ok   boss-os waits for e2e (no staging target)"
else echo "  FAIL boss-os route: expected '|e2e', got '$bossed'"; fails=$((fails+1)); fi
# The guard reads deploy.yml from origin/main (never the working tree: her checkout may be on any
# branch, #14) AND skips routes with E2E_WF (deploy.yml fires on e2e, not CI, #18). Both, on one line.
if grep -q '^if git cat-file -e origin/main:.github/workflows/deploy.yml 2>/dev/null && \[ -z "\$E2E_WF" \]; then' "$LAND" \
   && ! grep -q 'if \[ -f ".github/workflows/deploy.yml" \]' "$LAND"; then
  echo "  ok   a route with E2E_WF never waits for a Deploy run on green main, and deploy.yml is read from origin/main"
else echo "  FAIL land waits for a Deploy run even when the route names E2E_WF, or reads deploy.yml from the working tree instead of origin/main"; fails=$((fails+1)); fi
# The three self-deploying repos that moved to build-first say so in their SELF sentence, so the
# "5/5" line an operator reads names staging and the promote path, not "on push to main".
for r in secondaries founder-dilution-dashboard justbeingmercedes; do
  # shellcheck disable=SC2034
  self="$( ( NAME="$r"; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$SELF" ) )"
  case "$self" in *staging*e2e*) echo "  ok   $r self-deploy sentence names staging and the e2e gate" ;;
    *) echo "  FAIL $r self-deploy sentence does not name staging + e2e: '$self'"; fails=$((fails+1)) ;; esac
done
[ "$fails" -eq 0 ] || { echo "test-land-routes: $fails failure(s)"; exit 1; }
echo "test-land-routes: $n site repos routed, unknown repo refused"
