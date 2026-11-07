#!/usr/bin/env bash
# A named job's refs make the tail watch her own replies; every other ref stays untailed (7 Nov 2026).
set -u
. "$(dirname "$0")/../scooter-watch-named.sh"
t="$(mktemp)"; trap 'rm -f "$t"' EXIT
fail=0
printf 'TLR-AAAAAA  # brand A thread\nTLR-BBBBBB\n' > "$t"
[ "$(named_ref 'Re: ACTION REQUIRED: Brand Pricing Reply · v2 · TLR-BBBBBB' "$t")" = "TLR-BBBBBB" ] || { echo "FAIL: listed ref not found"; fail=1; }
[ "$(named_ref 'Re: thing · TLR-AAAAAA' "$t")" = "TLR-AAAAAA" ] || { echo "FAIL: commented line not read"; fail=1; }
[ -z "$(named_ref 'Re: other brand · TLR-CCCCCC' "$t")" ] || { echo "FAIL: unlisted ref was named"; fail=1; }
[ -z "$(named_ref 'Re: thing · TLR-AAAAAA' /nonexistent)" ] || { echo "FAIL: missing file named something"; fail=1; }
: > "$t"; [ -z "$(named_ref 'Re: thing · TLR-AAAAAA' "$t")" ] || { echo "FAIL: empty file named something"; fail=1; }
# The watcher uses it before its reply exclusion.
grep -q 'named="$(named_ref "$subject"' "$(dirname "$0")/../scooter-watch.sh" || { echo "FAIL: scooter-watch.sh does not call named_ref"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-named: OK (5 cases)"; exit $fail
