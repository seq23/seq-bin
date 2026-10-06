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
mercedes-creator-dashboard|npm run deploy:production
topbarz-voting|npm run deploy:production
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
# so land deploys staging on every merge; production then follows the plan block (2 Oct 2026: a
# small change ships on the fast check, a large one on a green e2e — tests/test-land-plan.sh).
# shellcheck disable=SC2034  # NAME is read by the eval'd routes block
# mercedes-creator-dashboard (26 Sep 2026) is the same shape: stages on every land, names e2e,
# smokes its own custom domain (never Sheila's URL).
for build_first in sheila-creator-dashboard mercedes-creator-dashboard; do
  staged="$( ( NAME=$build_first; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$STAGING|$E2E_WF" ) )"
  if [ "$staged" = "npm run deploy:staging|e2e" ]; then echo "  ok   $build_first stages (npm run deploy:staging) and names its e2e workflow"
  else echo "  FAIL $build_first route: expected 'npm run deploy:staging|e2e', got '$staged'"; fails=$((fails+1)); fi
done
smoke="$( ( NAME=mercedes-creator-dashboard; DEPLOY=""; SELF=""; SMOKE=""; die() { exit 1; }; eval "$BLOCK"; echo "$SMOKE" ) )"
if [ "$smoke" = "https://dashboard.justbeingmercedes.com/healthz" ]; then echo "  ok   mercedes-creator-dashboard smokes its own domain"
else echo "  FAIL mercedes-creator-dashboard smoke: got '$smoke'"; fails=$((fails+1)); fi
# 26 Sep 2026: boss-os names its full e2e workflow (no staging target), so the plan block governs
# its production and `land --promote boss-os` ships an e2e-green commit. 2 Oct 2026: it also names
# deploy.yml as the workflow that ships on a green e2e (PROMOTE_WF), so land waits for that run
# after the suite instead of racing it from the laptop. And a route with E2E_WF must
# not take the "wait for the Deploy run" branch: that deploy.yml fires on e2e now, and the newest
# Deploy run on main would be an older commit's. Proven by reading the guard out of land itself.
# shellcheck disable=SC2034  # NAME is read by the eval'd routes block
bossed="$( ( NAME=boss-os; DEPLOY=""; SELF=""; STAGING=""; E2E_WF=""; die() { exit 1; }; eval "$BLOCK"; echo "$STAGING|$E2E_WF|$PROMOTE_WF|$PROMOTE_VIA" ) )"
if [ "$bossed" = "|e2e|deploy.yml|" ]; then echo "  ok   boss-os names e2e (no staging target) and waits for its own deploy.yml after a green suite"
else echo "  FAIL boss-os route: expected '|e2e|deploy.yml|', got '$bossed'"; fails=$((fails+1)); fi
# Every other route waits for promote.yml when the repo carries one (the default), and names no
# PROMOTE_VIA unless it is listed below.
for r in sheila-creator-dashboard mercedes-creator-dashboard west-peek-os approvalprep topbarz-voting; do
  # shellcheck disable=SC2034
  got="$( ( NAME="$r"; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$PROMOTE_WF|$PROMOTE_VIA" ) )"
  if [ "$got" = "promote.yml|" ]; then echo "  ok   $r: PROMOTE_WF promote.yml, no PROMOTE_VIA"
  else echo "  FAIL $r: expected 'promote.yml|', got '$got'"; fails=$((fails+1)); fi
done
# The guard reads the deploy workflow from origin/main (never the working tree: her checkout may be
# on any branch, #14) AND skips routes with E2E_WF (deploy.yml fires on e2e, not CI, #18). Both, on
# one line. 6 Oct 2026: the file is the route's DEPLOY_WF, defaulting to deploy.yml right above it.
if grep -q '^if git cat-file -e "origin/main:.github/workflows/\$DEPLOY_WF" 2>/dev/null && \[ -z "\$E2E_WF" \]; then' "$LAND" \
   && grep -q '^DEPLOY_WF="\${DEPLOY_WF:-deploy.yml}"$' "$LAND" \
   && ! grep -q 'if \[ -f ".github/workflows/' "$LAND"; then
  echo "  ok   a route with E2E_WF never waits for a deploy run on green main; DEPLOY_WF (default deploy.yml) is read from origin/main"
else echo "  FAIL land waits for a deploy run even when the route names E2E_WF, reads the workflow from the working tree, or lost the deploy.yml default"; fails=$((fails+1)); fi
# …and it finds THE MERGE COMMIT's run, never "the newest run named Deploy" (an older commit's run,
# and blind to any workflow not named exactly "Deploy" — westpeek-live's is "Deploy Cloudflare Worker").
if grep -q 'select(.name==\\"Deploy\\")' "$LAND"; then echo "  FAIL land still picks the deploy run by the name \"Deploy\" instead of by the merge commit"; fails=$((fails+1))
else echo "  ok   the deploy run is found by the merge commit, not by its name"; fi
# 6 Oct 2026: westpeek-live's Workers Builds is upload-only; production ships only through
# deploy-cloudflare-worker.yml on green main. land must wait for that run and smoke the live domain.
# shellcheck disable=SC2034  # NAME is read by the eval'd routes block
wpl="$( ( NAME=westpeek-live; DEPLOY=""; SELF=""; DEPLOY_WF=""; SMOKE=""; die() { exit 1; }; eval "$BLOCK"; echo "$DEPLOY|$DEPLOY_WF|$SMOKE|$E2E_WF|$STAGING|$PROMOTE_VIA" ) )"
if [ "$wpl" = "|deploy-cloudflare-worker.yml|https://westpeek.live/api/runtime/health|||" ]; then
  echo "  ok   westpeek-live waits for its own deploy-cloudflare-worker.yml run and smokes westpeek.live"
else echo "  FAIL westpeek-live route: expected '|deploy-cloudflare-worker.yml|https://westpeek.live/api/runtime/health|||', got '$wpl'"; fails=$((fails+1)); fi
wself="$( ( NAME=westpeek-live; DEPLOY=""; SELF=""; DEPLOY_WF=""; SMOKE=""; die() { exit 1; }; eval "$BLOCK"; echo "$SELF" ) )"
case "$wself" in *"Workers Builds only uploads"*) echo "  ok   westpeek-live's sentence says Workers Builds only uploads" ;;
  *) echo "  FAIL westpeek-live's sentence still claims Workers Builds deploys it: '$wself'"; fails=$((fails+1)) ;; esac
# Only westpeek-live names a DEPLOY_WF today; every other route leaves it empty (deploy.yml default).
for r in west-peek-os boss-os topbarz-voting justbeingmercedes dream-wedding-builder how-we-know; do
  # shellcheck disable=SC2034
  got="$( ( NAME="$r"; DEPLOY=""; SELF=""; DEPLOY_WF=""; die() { exit 1; }; eval "$BLOCK"; echo "$DEPLOY_WF" ) )"
  if [ -z "$got" ]; then echo "  ok   $r names no DEPLOY_WF"; else echo "  FAIL $r: unexpected DEPLOY_WF '$got'"; fails=$((fails+1)); fi
done
# The deploy-run picker, read out of land verbatim: newest run whose head CONTAINS the merge sha,
# skipping skipped/cancelled runs; nothing when no such run exists (land then keeps looking, bounded).
DWF="$(sed -n '/^# --- deploy_wf begin/,/^# --- deploy_wf end/p' "$LAND")"
[ -n "$DWF" ] || { echo "FAIL: land no longer carries the deploy_wf block"; exit 1; }
pick() { # $1 sha, rows on stdin; ancestry: "aaa" < "bbb" < "ccc" (a later letter contains an earlier one)
  ( eval "$DWF"
    contains_sha() { [ "$1" = "$2" ] || [[ "$2" > "$1" ]]; }
    deploy_wf_pick "$1" )
}
T=$'\t'
while IFS='|' read -r label sha rows want; do
  [ -n "$label" ] || continue
  got="$(printf '%b' "$rows" | pick "$sha")"
  if [ "$got" = "$(printf '%b' "$want")" ]; then echo "  ok   deploy_wf_pick: $label"
  else echo "  FAIL deploy_wf_pick: $label — expected '$want', got '$got'"; fails=$((fails+1)); fi
done <<PICK
own run, green|bbb|9${T}bbb${T}completed${T}success\n8${T}aaa${T}completed${T}success|9${T}completed${T}success
own run, red, is reported red|bbb|9${T}bbb${T}completed${T}failure\n8${T}aaa${T}completed${T}success|9${T}completed${T}failure
in flight is returned for the wait|bbb|9${T}bbb${T}in_progress${T}|9${T}in_progress${T}
an older commit's run is never ours|bbb|8${T}aaa${T}completed${T}success|
superseded: the newer run carries it|bbb|10${T}ccc${T}completed${T}success\n9${T}bbb${T}completed${T}cancelled|10${T}completed${T}success
skipped runs are passed over|bbb|10${T}bbb${T}completed${T}skipped\n9${T}bbb${T}completed${T}failure|9${T}completed${T}failure
only skipped: nothing yet|bbb|10${T}bbb${T}completed${T}skipped|
PICK
# THE CHECK THAT WOULD HAVE CAUGHT 6 Oct 2026: a self-deploying route whose repo carries a GitHub
# workflow that deploys to Cloudflare on push / workflow_run must NAME that workflow (DEPLOY_WF, or
# PROMOTE_VIA) — otherwise land reports LANDED off a Cloudflare check-run (or "nothing to run") while
# production is still moving, and never sees that workflow go red. A deploy workflow here: uses the
# CLOUDFLARE_API_TOKEN secret, has a run/command line that deploys, and fires on push or workflow_run.
deploys_on_main() { # $1 checkout -> the deploy workflow file names on origin/main, one per line
  local f c
  git -C "$1" ls-tree --name-only origin/main .github/workflows/ 2>/dev/null | while read -r f; do
    c="$(git -C "$1" show "origin/main:$f" 2>/dev/null)" || continue
    grep -q 'CLOUDFLARE_API_TOKEN' <<<"$c" || continue
    grep -qE '^ *(- )?(run|command):.*deploy' <<<"$c" || continue
    grep -qE '^  (push|workflow_run):' <<<"$c" || continue
    echo "${f##*/}"
  done
}
self_route_gap() { # $1 repo name  $2 checkout -> prints the unwaited workflow(s); 0 = gap found
  local wf named gap=""
  # shellcheck disable=SC2034
  named="$( ( NAME="$1"; DEPLOY=""; SELF=""; DEPLOY_WF=""; die() { exit 1; }; eval "$BLOCK"; [ -z "$DEPLOY" ] || exit 0; echo "$DEPLOY_WF $PROMOTE_VIA" ) )" || return 1
  [ -n "$( ( NAME="$1"; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$DEPLOY" ) )" ] && return 1
  for wf in $(deploys_on_main "$2"); do
    case " $named " in *" $wf "*) : ;; *) gap="$gap $wf" ;; esac
  done
  [ -n "$gap" ] && { echo "${gap# }"; return 0; }
  return 1
}
# Proven on a fixture first (always runs, CI included): a self route with such a workflow and no
# DEPLOY_WF is caught; naming it clears the gap.
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
( cd "$FX" && git init -q -b main && mkdir -p .github/workflows \
  && printf 'name: Deploy Cloudflare Worker\non:\n  workflow_run:\n    workflows: [v]\njobs:\n  d:\n    env:\n      CLOUDFLARE_API_TOKEN: x\n    steps:\n      - run: npm run cf:deploy\n' > .github/workflows/deploy-cloudflare-worker.yml \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm fx && git update-ref refs/remotes/origin/main HEAD )
BLOCK_SAVED="$BLOCK"
BLOCK="${BLOCK_SAVED/westpeek-live)        DEPLOY=\"\" ; SELF=/westpeek-live)        DEPLOY=\"\" ; DEPLOY_WF=\"\" ; SMOKE=\"\" ; IGNORED=}"
BLOCK="$(sed 's/DEPLOY_WF="deploy-cloudflare-worker.yml"/DEPLOY_WF=""/' <<<"$BLOCK")"
if gap="$(self_route_gap westpeek-live "$FX")" && [ "$gap" = deploy-cloudflare-worker.yml ]; then
  echo "  ok   negative proof: a self route that does not name its repo's deploy workflow is caught ($gap)"
else echo "  FAIL negative proof: the unwaited deploy workflow was not caught (got '${gap:-nothing}')"; fails=$((fails+1)); fi
BLOCK="$BLOCK_SAVED"
if gap="$(self_route_gap westpeek-live "$FX")"; then echo "  FAIL westpeek-live names its deploy workflow yet a gap was reported: $gap"; fails=$((fails+1))
else echo "  ok   positive proof: naming DEPLOY_WF clears the gap"; fi
# Then every real checkout present on this machine (none in CI: the fixture above is the proof there).
ROOT="${LAND_REPOS_ROOT:-$HOME/GitHub}"; seen=0
if [ -d "$ROOT" ]; then
  while IFS='|' read -r repo _; do
    [ -n "$repo" ] && [ -d "$ROOT/$repo/.git" ] || continue
    seen=$((seen+1))
    if gap="$(self_route_gap "$repo" "$ROOT/$repo")"; then
      echo "  FAIL $repo deploys to Cloudflare through $gap on main, but its land route does not wait for it (set DEPLOY_WF)"; fails=$((fails+1))
    fi
  done <<< "$SITES"
  if [ "$seen" -gt 0 ]; then echo "  ok   $seen local checkout(s) under $ROOT: every self route waits for its repo's own deploy workflow"
  else echo "  ok   no site checkouts under $ROOT; the fixture proof above stands"; fi
fi
# The three self-deploying repos that moved to build-first say so in their SELF sentence, so the
# "5/5" line an operator reads names staging and the promote path, not "on push to main".
for r in secondaries founder-dilution-dashboard justbeingmercedes; do
  # shellcheck disable=SC2034
  self="$( ( NAME="$r"; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$SELF" ) )"
  case "$self" in *staging*e2e*) echo "  ok   $r self-deploy sentence names staging and the e2e gate" ;;
    *) echo "  FAIL $r self-deploy sentence does not name staging + e2e: '$self'"; fails=$((fails+1)) ;; esac
done
# 2 Oct 2026: those three are the routes whose production moves through the repo's OWN workflow.
# land must be able to drive it — the e2e workflow named (so the plan and the known-red rule apply)
# and the workflow to dispatch named (PROMOTE_VIA, which is then also the run it waits for). Without
# these land confirmed the staging build and stopped: production never moved for a small change.
while IFS='|' read -r r via; do
  [ -n "$r" ] || continue
  # shellcheck disable=SC2034
  got="$( ( NAME="$r"; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$DEPLOY|$E2E_WF|$PROMOTE_VIA|$PROMOTE_WF" ) )"
  if [ "$got" = "|e2e|$via|$via" ]; then echo "  ok   $r ships production through its own $via, on the plan (e2e named)"
  else echo "  FAIL $r: expected '|e2e|$via|$via', got '$got'"; fails=$((fails+1)); fi
done <<'VIA'
secondaries|promote.yml
founder-dilution-dashboard|promote.yml
justbeingmercedes|deploy.yml
VIA
# …and land does not stop at the staging build for them: the self-deploy branch exits only when the
# route names no PROMOTE_VIA.
# 6 Oct 2026: a DEPLOY_WF route falls through too — to the wait for its own deploy run.
if grep -q '^  { \[ -n "\$PROMOTE_VIA" \] && \[ -n "\$E2E_WF" \]; } || \[ -n "\$DEPLOY_WF" \] || exit 0$' "$LAND"; then
  echo "  ok   a PROMOTE_VIA route falls through from the staging build to the plan, a DEPLOY_WF route to its deploy-run wait"
else echo "  FAIL land exits at the Cloudflare build even for a PROMOTE_VIA or DEPLOY_WF route (or the guard moved)"; fails=$((fails+1)); fi
# The deploy-run wait must come AFTER that fall-through, or a DEPLOY_WF route never reaches it.
ft="$(grep -n '|| \[ -n "\$DEPLOY_WF" \] || exit 0$' "$LAND" | head -1 | cut -d: -f1)"
gw="$(grep -n '^if git cat-file -e "origin/main:.github/workflows/\$DEPLOY_WF"' "$LAND" | head -1 | cut -d: -f1)"
if [ -n "$ft" ] && [ -n "$gw" ] && [ "$ft" -lt "$gw" ]; then echo "  ok   the self-deploy fall-through (line $ft) reaches the deploy-run wait (line $gw)"
else echo "  FAIL the deploy-run wait (line ${gw:-none}) is not reachable after the self-deploy fall-through (line ${ft:-none})"; fails=$((fails+1)); fi
# 2 Oct 2026: topbarz-voting ships through its own deploy.yml on a green Validate (staging, a live
# check, production, a live check) and has no browser suite. So its route must name NO e2e workflow
# and NO staging command: with either set, land would skip the "wait for the Deploy run" branch and
# deploy from the laptop, racing the workflow's `d1 migrations apply`.
# shellcheck disable=SC2034  # NAME is read by the eval'd routes block
tbz="$( ( NAME=topbarz-voting; DEPLOY=""; SELF=""; die() { exit 1; }; eval "$BLOCK"; echo "$DEPLOY|$SELF|$STAGING|$E2E_WF|$PROMOTE_VIA" ) )"
if [ "$tbz" = "npm run deploy:production||||" ]; then echo "  ok   topbarz-voting waits for its own Deploy run (no e2e workflow, no staging command, no PROMOTE_VIA)"
else echo "  FAIL topbarz-voting route: expected 'npm run deploy:production||||', got '$tbz'"; fails=$((fails+1)); fi
[ "$fails" -eq 0 ] || { echo "test-land-routes: $fails failure(s)"; exit 1; }
echo "test-land-routes: $n site repos routed, unknown repo refused"
