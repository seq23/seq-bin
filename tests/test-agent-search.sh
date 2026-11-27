#!/bin/bash
# agent-search: one trial zone, and a money guard that can never say "under the limit" when it could not read.
# No network: tests/fixtures/agent-search/fake-curl stands in for curl and the Cloudflare API.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$BIN/tests/fixtures/agent-search"
fail=0; n=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fresh() { rm -rf "$T/s" "$T/f"; mkdir -p "$T/s" "$T/f"; echo "${1:-off}" > "$T/f/setting"; : > "$T/notices"; }
# rc, out and flat are read inside the eval strings that ok() runs.
# shellcheck disable=SC2034
run() { # env… -- args : runs agent-search with the fakes, output in $out, rc in $rc
  out=$(env AGENT_SEARCH_NO_VAULT=1 AGENT_SEARCH_CURL="$FIX/fake-curl" AGENT_SEARCH_STATE="$T/s" FAKE_DIR="$T/f" \
        AGENT_SEARCH_NOTICE="$T/notice" AGENT_SEARCH_LAUNCHCTL="$T/lctl-${LCTL_STATE:-loaded}" \
        AGENT_SEARCH_SITES="$FIX/sites.json" CLOUDFLARE_ACCOUNT_ID=acct1 "$@" 2>&1); rc=$?
}
Z=weddingseatingchartmaker.com
ok() { n=$((n + 1)); if eval "$2"; then :; else echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fail=1; fi; }
setting() { cat "$T/f/setting"; }
printf '#!/bin/bash\necho "$1 | $2" >> "%s/notices"\n' "$T" > "$T/notice"; chmod +x "$T/notice"
printf '#!/bin/bash\nexit 0\n' > "$T/lctl-loaded"; printf '#!/bin/bash\nexit 113\n' > "$T/lctl-missing"; chmod +x "$T"/lctl-*
TOK=CLOUDFLARE_AI_SEARCH_TOKEN=t

# 0. tests/lint-shell.sh lints *.sh only: lint the two extensionless scripts here.
for f in "$BIN/agent-search" "$FIX/fake-curl"; do
  n=$((n + 1)); bash -n "$f" || { echo "FAIL: $f does not parse"; fail=1; }
  if command -v shellcheck >/dev/null; then shellcheck -S warning "$f" || { echo "FAIL: shellcheck $f"; fail=1; }; fi
done

# 1. No token: NAMED STOP [ACCOUNT], non-zero, nothing changed.
for c in "status $Z" "enable $Z" "disable $Z"; do
  fresh off; run env -u CLOUDFLARE_AI_SEARCH_TOKEN "$BIN/agent-search" $c
  ok "no token ($c) is NAMED STOP [ACCOUNT] exit 2" '[ $rc -eq 2 ] && echo "$out" | grep -q "NAMED STOP \[ACCOUNT\]" && [ "$(setting)" = off ]'
done
fresh on; run env -u CLOUDFLARE_AI_SEARCH_TOKEN "$BIN/agent-search" guard
ok "no token in the guard is COULDNT-CHECK naming NAMED STOP [ACCOUNT], never UNDER" '[ $rc -ne 0 ] && echo "$out" | grep -q "NAMED STOP \[ACCOUNT\]" && ! echo "$out" | grep -q "GUARD UNDER"'

# 2. Status happy path: on and answering.
fresh on; run "$TOK" "$BIN/agent-search" status "$Z"
ok "status on + search answers = answering, exit 0" '[ $rc -eq 0 ] && echo "$out" | grep -q "^$Z answering"'
fresh off; run "$TOK" "$BIN/agent-search" status "$Z"
ok "status off = off" '[ $rc -eq 0 ] && echo "$out" | grep -q "^$Z off"'
fresh on; run "$TOK" FAKE_SEARCH=403 "$BIN/agent-search" status "$Z"
ok "status on + search 403 = blocked, never answering" '[ $rc -eq 0 ] && echo "$out" | grep -q "^$Z blocked" && ! echo "$out" | grep -q answering'
fresh on; run "$TOK" FAKE_SEARCH=404 "$BIN/agent-search" status "$Z"
ok "status on + search 404 = enabled-indexing" 'echo "$out" | grep -q "^$Z enabled-indexing"'

# 3. Status with the API down: COULDNT-CHECK, never "on" or "answering", exit 1.
fresh on; run "$TOK" FAKE_API=down "$BIN/agent-search" status "$Z"
ok "API down = COULDNT-CHECK, exit 1, never answering/on" '[ $rc -eq 1 ] && echo "$out" | grep -q "^$Z COULDNT-CHECK" && ! echo "$out" | grep -Eq "answering|enabled| on "'
fresh on; run "$TOK" FAKE_SETTING_READ=denied "$BIN/agent-search" status "$Z"
ok "token that sees the zone but not its setting = COULDNT-CHECK, never on" '[ $rc -eq 1 ] && echo "$out" | grep -q "^$Z COULDNT-CHECK" && ! echo "$out" | grep -Eq "answering|enabled|blocked"'
fresh off; run "$TOK" FAKE_API=down "$BIN/agent-search" status --all
ok "status --all lists every grid zone plus whisperalmanac.com, all COULDNT-CHECK when the API is down" \
  '[ $rc -eq 1 ] && [ "$(echo "$out" | grep -c COULDNT-CHECK\ setting)" -eq 3 ] && echo "$out" | grep -q "^whisperalmanac.com COULDNT-CHECK" && echo "$out" | grep -q "OUTPUT 3 zones, 3 COULDNT-CHECK"'

# 4. Enable: one zone only, guard loaded, usage readable and under the limit.
fresh off; run "$TOK" "$BIN/agent-search" enable approvalprep.com
ok "enable on another zone is refused" '[ $rc -eq 1 ] && echo "$out" | grep -q ONE_ZONE_ONLY && ! grep -q PATCH "$T/f/calls" 2>/dev/null'
fresh off; LCTL_STATE=missing run "$TOK" "$BIN/agent-search" enable "$Z"
ok "enable without the guard job loaded is refused, setting stays off" '[ $rc -eq 1 ] && echo "$out" | grep -q GUARD_NOT_LOADED && [ "$(setting)" = off ]'
fresh off; run "$TOK" FAKE_USAGE=errors "$BIN/agent-search" enable "$Z"
ok "enable with usage unreadable is refused" '[ $rc -eq 1 ] && echo "$out" | grep -q "REFUSED \[COULDNT-CHECK\]" && [ "$(setting)" = off ]'
fresh off; run "$TOK" FAKE_USAGE="800 0 0" "$BIN/agent-search" enable "$Z"
ok "enable at 800 queries is refused" '[ $rc -eq 1 ] && echo "$out" | grep -q OVER_LIMIT && [ "$(setting)" = off ]'
fresh off; run "$TOK" FAKE_PATCH=denied "$BIN/agent-search" enable "$Z"
ok "enable whose switch is refused is a NAMED STOP, not enabled" '[ $rc -eq 2 ] && echo "$out" | grep -q ENABLE_FAILED && [ "$(setting)" = off ] && ! echo "$out" | grep -q "enabled, indexing"'
fresh off; run "$TOK" FAKE_USAGE="12 3 1000" "$BIN/agent-search" enable "$Z"
ok "enable happy path turns it on and says indexing" '[ $rc -eq 0 ] && [ "$(setting)" = on ] && echo "$out" | grep -q "$Z enabled, indexing"'
run "$TOK" "$BIN/agent-search" disable "$Z"
ok "disable turns it off" '[ $rc -eq 0 ] && [ "$(setting)" = off ]'

# 5. Guard: under, at the limit (each allowance), boundary 799.
fresh on; run "$TOK" FAKE_USAGE="799 799 3999999" "$BIN/agent-search" guard
ok "guard at 799/799/3,999,999 is under, exit 0, stays on" '[ $rc -eq 0 ] && echo "$out" | grep -q "GUARD UNDER" && [ "$(setting)" = on ] && [ ! -s "$T/notices" ]'
for u in "800 0 0" "0 800 0" "0 0 4000000" "5000 0 0"; do
  fresh on; run "$TOK" FAKE_USAGE="$u" "$BIN/agent-search" guard
  ok "guard at '$u' switches off, writes Notices, exit 3" '[ $rc -eq 3 ] && [ "$(setting)" = off ] && grep -q "agent-search:off:" "$T/notices" && ! echo "$out" | grep -q "GUARD UNDER"'
done

# 6. Guard cannot read: day 1 stays on and says so; day 2 running switches off. Never UNDER.
for mode in "FAKE_API=down" "FAKE_USAGE=errors" "FAKE_USAGE=errors_with_data" "FAKE_USAGE=partial" "FAKE_USAGE=noaccount"; do
  fresh on; run "$TOK" "$mode" AGENT_SEARCH_TODAY=2026-12-02 "$BIN/agent-search" guard
  ok "guard unreadable ($mode) day 1: exit 1, COULDNT-CHECK, Notices, still on, never UNDER" \
    '[ $rc -eq 1 ] && echo "$out" | grep -q COULDNT-CHECK && ! echo "$out" | grep -q "GUARD UNDER" && [ "$(setting)" = on ] && grep -q "agent-search:unread:2026-12-02" "$T/notices"'
done
fresh on
run "$TOK" FAKE_USAGE=errors AGENT_SEARCH_TODAY=2026-12-02 "$BIN/agent-search" guard
run "$TOK" FAKE_USAGE=errors AGENT_SEARCH_TODAY=2026-12-02 "$BIN/agent-search" guard
ok "two failed runs on the SAME day are one day, still on" '[ $rc -eq 1 ] && [ "$(setting)" = on ]'
run "$TOK" FAKE_USAGE=errors AGENT_SEARCH_TODAY=2026-12-03 "$BIN/agent-search" guard
ok "unreadable on the second day running switches off, Notices, exit 3" '[ $rc -eq 3 ] && [ "$(setting)" = off ] && grep -q "agent-search:off:2026-12-03" "$T/notices"'
fresh on
run "$TOK" FAKE_USAGE=errors AGENT_SEARCH_TODAY=2026-12-02 "$BIN/agent-search" guard
run "$TOK" FAKE_USAGE="5 0 0" AGENT_SEARCH_TODAY=2026-12-03 "$BIN/agent-search" guard
run "$TOK" FAKE_USAGE=errors AGENT_SEARCH_TODAY=2026-12-04 "$BIN/agent-search" guard
ok "a good read in between resets the count: fail, good, fail stays on" '[ $rc -eq 1 ] && [ "$(setting)" = on ]'
fresh on
run "$TOK" FAKE_API=down AGENT_SEARCH_TODAY=2026-12-02 "$BIN/agent-search" guard
run "$TOK" FAKE_API=down AGENT_SEARCH_TODAY=2026-12-03 "$BIN/agent-search" guard
ok "API down two days: the switch-off cannot run either = NAMED STOP + 'turn it off by hand' Notices, exit 2" \
  '[ $rc -eq 2 ] && echo "$out" | grep -q GUARD_COULDNT_SWITCH_OFF && grep -q "agent-search:stuck:2026-12-03" "$T/notices"'
fresh on; run "$TOK" FAKE_USAGE="900 0 0" FAKE_PATCH=denied "$BIN/agent-search" guard
ok "over the limit with the switch refused = NAMED STOP, exit 2, never UNDER" '[ $rc -eq 2 ] && echo "$out" | grep -q GUARD_COULDNT_SWITCH_OFF && ! echo "$out" | grep -q "GUARD UNDER"'

fresh on; run "$TOK" FAKE_USAGE="900 0 0" FAKE_PATCH=ignored "$BIN/agent-search" guard
ok "a switch-off the API accepts but does not apply is NAMED STOP, never SWITCHED-OFF" '[ $rc -eq 2 ] && echo "$out" | grep -q GUARD_COULDNT_SWITCH_OFF && ! echo "$out" | grep -q "GUARD SWITCHED-OFF"'
fresh off; run "$TOK" FAKE_SETTING_READ=denied "$BIN/agent-search" enable "$Z"
ok "enable with a token that cannot read the setting is NAMED STOP [ACCOUNT], nothing patched" '[ $rc -eq 2 ] && echo "$out" | grep -q "NAMED STOP \[ACCOUNT\]" && ! grep -q PATCH "$T/f/calls"'

# 7. The guard job: daily 10:30 Central, runs the guard.
P="$BIN/launchd/com.seq.agent-search-guard.plist"
# shellcheck disable=SC2034
flat=$(tr -d '\n\t ' < "$P" 2>/dev/null)
ok "guard plist fires daily at 10:30 (Central) and runs agent-search guard" \
  'echo "$flat" | grep -q "<key>Hour</key><integer>10</integer><key>Minute</key><integer>30</integer>" && ! echo "$flat" | grep -q Weekday && grep -q "agent-search guard" "$P"'

[ $n -ge 30 ] || { echo "FAIL: only $n checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "agent-search: ok ($n checks)"
exit $fail
