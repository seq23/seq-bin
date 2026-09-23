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

# The site repos the web property change lane targets, and the route each must resolve to.
# "self" = deploys itself on merge (DEPLOY empty, SELF set); anything else = the DEPLOY command.
SITES='
westpeek-live|self
join-west-peek-main|self
west-peek-pitch-lab|self
west-peek-network-os|self
secondaries|self
founder-dilution-dashboard|self
west-peek-os|npm run deploy:production
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
[ "$fails" -eq 0 ] || { echo "test-land-routes: $fails failure(s)"; exit 1; }
echo "test-land-routes: $n site repos routed, unknown repo refused"
