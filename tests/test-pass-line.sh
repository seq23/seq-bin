#!/bin/bash
# pass-line posts only what land reads, through land's own parser (22 Nov 2026).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"; printf '#!/bin/bash\ncase "$*" in *headRefOid*) echo abc1234def0000000000000000000000000000aa;; *) echo "$*" >> "%s/posted";; esac\n' "$W" > "$W/bin/gh"; chmod +x "$W/bin/gh"
fails=0
t() { # name want_rc want_posted line
  rm -f "$W/posted"; PATH="$W/bin:$PATH" "$ROOT/pass-line" o/r 7 "$4" >/dev/null; rc=$?
  posted=0; [ -s "$W/posted" ] && posted=1
  if [ "$rc" = "$2" ] && [ "$posted" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (rc $rc, posted $posted)"; fails=$((fails+1)); fi
}
t "a full Ship-ready line posts" 0 1 'Ship-ready: PASS — reviewer run 123 looked at the page at 390 px at abc1234; Engineering: PASS'
t "a Launch-ready line posts" 0 1 'Launch-ready: PASS — reviewer run 9 looked at logo, banner, 404 at abc1234d'
t "no \"looked at\" (the #127 line) is refused and not posted" 1 0 'Ship-ready: PASS — re-checker re-checked Fail 1 at abc1234; Engineering: PASS'
t "no Engineering: PASS is refused and not posted" 1 0 'Ship-ready: PASS — reviewer looked at the page'
t "a line naming an older head is refused" 1 0 'Ship-ready: PASS — reviewer looked at the page at 9f9f9f9; Engineering: PASS'
t "a line naming no head is refused" 1 0 'Ship-ready: PASS — reviewer looked at the page; Engineering: PASS'
t "a fail verdict is refused" 1 0 'VERDICT: fail'
# land's own parser decides: a land whose parser no longer requires "looked at" makes the #127 line post.
sed 's/ looked at \.+"/"/' "$ROOT/land" > "$W/land.mut"
rm -f "$W/posted"; PASS_LINE_LAND="$W/land.mut" PATH="$W/bin:$PATH" "$ROOT/pass-line" o/r 7 'Ship-ready: PASS — re-checker re-checked Fail 1 at abc1234; Engineering: PASS' >/dev/null
[ -s "$W/posted" ] && echo "  ok   negative proof: pass-line follows land's parser, not a copy" || { echo "  FAIL negative proof: pass-line ignored land's parser"; fails=$((fails+1)); }
PASS_LINE_LAND="$W/nope" "$ROOT/pass-line" o/r 7 x >/dev/null; [ $? = 2 ] && echo "  ok   no parser → named stop" || { echo "  FAIL no parser did not stop"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS test-pass-line" || { echo "FAIL test-pass-line ($fails)"; exit 1; }
