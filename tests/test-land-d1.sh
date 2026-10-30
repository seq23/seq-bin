#!/bin/bash
# land must migrate a self-deploying repo's D1 database BEFORE the merge, never after it.
#
# 30 Oct 2026, p-n-p #162: Cloudflare Pages deployed code reading a new `corporate` column the moment
# the merge landed; nothing applied migration 0026 to D1 `pnp-admin`, and porchandparty901.com's
# request form could fail until it was applied by hand. This evals land's routes block (p-n-p names
# its database) and its d1 block verbatim, against a fake `npx` that keeps a pending-migration count,
# and pins where land calls them: the pre-merge apply before `gh pr merge`, the pending check before
# LANDED. Carries a negative proof: a d1 block that trusts an apply without reading the pending list
# back, and one that skips the pre-merge apply, must each fail this test.
# shellcheck disable=SC2034 # NAME, PR_PATHS: read by the evaluated land blocks
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND="$HERE/../land"
ROUTES="$(sed -n '/^# --- routes begin/,/^# --- routes end/p' "$LAND")"
BLOCK="$(sed -n '/^# --- d1 begin/,/^# --- d1 end/p' "$LAND")"
[ -n "$ROUTES" ] || { echo "FAIL: land no longer carries the routes block"; exit 1; }
[ -n "$BLOCK" ] || { echo "FAIL: land no longer carries the d1 block"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# fake npx: `wrangler d1 migrations apply|list <db> --remote`. State: $WORK/pending (a count),
# $WORK/apply-fails (exists = the apply errors). Every call is logged with CI's value.
cat > "$WORK/bin/npx" <<'NPX'
#!/bin/bash
echo "CI=${CI:-} $*" >> "$FAKE_D1/calls"
[ "$1 $2 $3" = "wrangler d1 migrations" ] || { echo "unexpected npx $*" >&2; exit 2; }
case "$4" in
  apply) [ -e "$FAKE_D1/apply-fails" ] && { echo "✘ [ERROR] near \"corporate\": syntax error"; exit 1; }
         echo 0 > "$FAKE_D1/pending"; echo "🚣 applied" ;;
  list)  [ -e "$FAKE_D1/list-fails" ] && { echo "✘ [ERROR] Authentication error [code: 10000]"; exit 1; }
         n="$(cat "$FAKE_D1/pending")"
         if [ "$n" = 0 ]; then echo "✅ No migrations to apply!"; else echo "Migrations to be applied: $n"; fi ;;
  *) exit 2 ;;
esac
NPX
chmod +x "$WORK/bin/npx"
export FAKE_D1="$WORK"
fails=0; passes=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"; passes=$((passes+1)); else echo "  FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi
}
route_db() { ( die() { echo "DIED"; }; NAME="$1"; eval "$ROUTES"; echo "${D1_PREMERGE:-none}" ); }
check "p-n-p names its D1 database" pnp-admin "$(route_db p-n-p)"
check "a Pages repo with no D1 names none" none "$(route_db sprylabs-hpc-site)"
check "a scripted-deploy repo (migrates in its own script) names none" none "$(route_db west-peek-os)"

# run_case <block> <db> <pending> <apply-fails 0|1> <fn> [paths] -> "<rc> <applies> <lists>"
run_case() {
  local block="$1" db="$2" pending="$3" afail="$4" fn="$5" paths="${6-}"
  rm -f "$WORK/calls" "$WORK/apply-fails" "$WORK/list-fails"; : > "$WORK/calls"
  echo "$pending" > "$WORK/pending"; [ "$afail" = 1 ] && : > "$WORK/apply-fails"
  [ "$afail" = L ] && : > "$WORK/list-fails"
  local rc=0
  ( PATH="$WORK/bin:$PATH"; deploy_at() { (eval "$2"); }; D1_PREMERGE="$db"; PR_PATHS="$paths"
    eval "$block"; "$fn" deadbeefcafe >/dev/null 2>&1 ) || rc=$?
  printf '%s %s %s' "$rc" "$(grep -c ' apply ' "$WORK/calls" || true)" "$(grep -c ' list ' "$WORK/calls" || true)"
}
suite() { # block -> number of failed assertions
  local b="$1" f=0
  t() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected '$2', got '$3'"; f=$((f+1)); fi; }
  t "pre-merge, PR adds a migration: applied, then read back" "0 1 1" "$(run_case "$b" pnp-admin 1 0 d1_premerge $'functions/api/request.js\nmigrations/0026_corporate_outreach.sql')"
  t "pre-merge, PR changes no migration: nothing touched" "0 0 0" "$(run_case "$b" pnp-admin 1 0 d1_premerge $'functions/api/request.js')"
  t "pre-merge, PR paths unreadable: applied anyway (fail closed)" "0 1 1" "$(run_case "$b" pnp-admin 1 0 d1_premerge '')"
  t "pre-merge, the apply fails: refused (land stops before the merge)" "1 1 0" "$(run_case "$b" pnp-admin 1 1 d1_premerge 'migrations/0026.sql')"
  t "pre-merge, an apply that exits 0 but leaves one pending: refused" "1 0 1" "$(run_case "$b" pnp-admin STUCK 0 d1_premerge_stuck 'migrations/0026.sql')"
  t "pre-merge, no D1 on the route: nothing touched" "0 0 0" "$(run_case "$b" '' 1 0 d1_premerge 'migrations/0026.sql')"
  t "post-merge, nothing pending: read only, no apply" "0 0 1" "$(run_case "$b" pnp-admin 0 0 d1_postmerge)"
  t "post-merge, a migration still owed: applied, then read back clean" "0 1 2" "$(run_case "$b" pnp-admin 1 0 d1_postmerge)"
  t "post-merge, owed and the apply fails: refused (never LANDED)" "1 1 1" "$(run_case "$b" pnp-admin 1 1 d1_postmerge)"
  t "post-merge, the pending list cannot be read: refused, not 'none pending'" "1" "$(run_case "$b" pnp-admin 0 L d1_postmerge | cut -d' ' -f1)"
  t "post-merge, no D1 on the route: nothing touched" "0 0 0" "$(run_case "$b" '' 1 0 d1_postmerge)"
  return "$f"
}
# The "stuck" case: an apply that exits 0 yet leaves a migration pending (Cloudflare answered but
# did not apply). d1_premerge_stuck swaps the apply for `true`, so the pending count never clears.
stuck_block() { printf '%s\nd1_premerge_stuck() { D1_APPLY="true"; d1_premerge "$@"; }\n' "$1"; }
echo "== land's d1 block"
f=0; suite "$(stuck_block "$BLOCK")" || f=$?
fails=$((fails + f))
# The pinned call: apply exactly as the repo's own admin:migrate script does.
rm -f "$WORK/calls"; echo 1 > "$WORK/pending"
( PATH="$WORK/bin:$PATH"; deploy_at() { (eval "$2"); }; D1_PREMERGE=pnp-admin; PR_PATHS=migrations/x.sql; eval "$BLOCK"; d1_premerge abc >/dev/null 2>&1 )
check "the apply is \`CI=true wrangler d1 migrations apply pnp-admin --remote\`" 1 "$(grep -c '^CI=true wrangler d1 migrations apply pnp-admin --remote$' "$WORK/calls")"
check "the d1 block never runs \`wrangler deploy\`" 0 "$(grep -c 'wrangler deploy' <<<"$BLOCK" || true)"

echo "== where land calls it"
L_PRE="$(grep -n 'd1_premerge "\$HEAD" || die "NAMED STOP \[D1_MIGRATION_FAILED\]' "$LAND" | cut -d: -f1 | head -1 || true)"
L_MERGE="$(grep -n 'gh pr merge "\$PR" --squash --match-head-commit' "$LAND" | cut -d: -f1 | head -1 || true)"
L_POST="$(grep -n 'd1_postmerge "\$MSHA_PAGES" || die "NAMED STOP \[D1_MIGRATIONS_PENDING\]' "$LAND" | cut -d: -f1 | head -1 || true)"
L_LANDED="$(grep -n 'say "LANDED — #\$PR is merged, main is green, and all \$PW_N Cloudflare builds' "$LAND" | cut -d: -f1 | head -1 || true)"
check "the pre-merge apply is called, and BEFORE gh pr merge" yes "$([ -n "$L_PRE" ] && [ -n "$L_MERGE" ] && [ "$L_PRE" -lt "$L_MERGE" ] && echo yes || echo "no (${L_PRE:-missing} vs ${L_MERGE:-missing})")"
check "the post-merge pending check is called, and BEFORE the self-deploy LANDED" yes "$([ -n "$L_POST" ] && [ -n "$L_LANDED" ] && [ "$L_POST" -lt "$L_LANDED" ] && echo yes || echo "no (${L_POST:-missing} vs ${L_LANDED:-missing})")"

echo "== negative proof: a block that trusts the apply without reading the list back must fail"
TRUSTING="$(sed 's/^  d1_none_pending "\$1"$/  return 0/' <<<"$BLOCK")"
[ "$TRUSTING" != "$BLOCK" ] || { echo "  FAIL the mutation did not apply (d1_apply_at changed shape?)"; fails=$((fails+1)); }
nf=0; suite "$(stuck_block "$TRUSTING")" >/dev/null || nf=$?
check "the trusting block is caught" yes "$([ "$nf" -gt 0 ] && echo yes || echo no)"
echo "== negative proof: a block that never applies before the merge must fail"
SKIPPING="$(sed 's/^  \[ -n "\$D1_PREMERGE" \] || return 0$/  return 0/' <<<"$BLOCK")"
[ "$SKIPPING" != "$BLOCK" ] || { echo "  FAIL the mutation did not apply"; fails=$((fails+1)); }
nf=0; suite "$(stuck_block "$SKIPPING")" >/dev/null || nf=$?
check "the skipping block is caught" yes "$([ "$nf" -gt 0 ] && echo yes || echo no)"

total=$((passes + fails))
[ "$total" -gt 0 ] || { echo "FAIL: zero assertions ran"; exit 1; }
[ "$fails" -eq 0 ] || { echo "FAILED: $fails"; exit 1; }
echo "PASS: land migrates D1 before the merge and confirms none pending after it"
