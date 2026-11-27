#!/bin/bash
# outcome-read, the one reader for every PR's Outcome check (27 Nov 2026; her finish line: "runs every night with no
# shell, only allowed read tools, and no access to her logins"). Proves, offline: a check never reaches a shell (a
# probe file a shell would create is never created); only the named read tools run; local reads stay inside the
# task, log and tool folders (her gh login, the vault, ssh keys and a symlink out are refused); a web read is a plain
# https GET of a public address (this Mac, the home network and cloud metadata are refused); text tools take only
# their listed flags and no file of their own; grep finding nothing is a 0, not a failure; a missing file is "could
# not read" (exit 4), never a count; --explain reads nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; R="${OUTCOME_READ_UNDER_TEST:-$HERE/outcome-read}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
[ "$(uname)" = Darwin ] || export OUTCOME_READ_NO_SANDBOX_OK=1   # Linux CI has no sandbox-exec; the Mac always uses it
H="$W/home"; mkdir -p "$H/Work/tasks" "$H/Library/Logs" "$H/.config/gh" "$H/.boss-os" "$H/bin"
printf 'acted 1\nacted 2\nacted 3\nskipped\n' > "$H/Work/tasks/acted.log"
printf 'oauth_token: gho_FAKE\n' > "$H/.config/gh/hosts.yml"; printf '{"k":"sk-FAKE"}\n' > "$H/.boss-os/vault.json"
ln -s "$H/.config/gh/hosts.yml" "$H/Work/tasks/sneaky.log"
fails=0; passes=0
check() { local label="$1"; shift; if "$@"; then passes=$((passes+1)); else echo "  FAIL $label (rc $RC: $(head -c 200 <<<"$OUT"))"; fails=$((fails+1)); fi; }
rd() { OUT="$(HOME="$H" "$R" "$@" 2>&1)"; RC=$?; }
probe="$W/probe"
# shellcheck disable=SC2034  # WANT is read inside the eval'd check
refused() { rd "$1"; WANT="$2"; check "refused, rc 3, nothing read: $1" eval '[ "$RC" -eq 3 ] && grep -q "^not run: " <<<"$OUT" && grep -qiF -- "$WANT" <<<"$OUT" && [ ! -e "$probe" ] && ! grep -q FAKE <<<"$OUT"'; }

echo "=== no shell: nothing a shell would do ever happens ==="
refused "grep -c acted ~/Work/tasks/acted.log; touch $probe" "a second command"
refused "grep -c acted ~/Work/tasks/acted.log && touch $probe" "& or &&"
refused "grep -c acted ~/Work/tasks/acted.log || touch $probe" "||"
refused "grep -c \$(touch $probe) ~/Work/tasks/acted.log" "a variable or"
refused "grep -c \`touch $probe\` ~/Work/tasks/acted.log" "backticks"
refused "grep -c \"\$(touch $probe)\" ~/Work/tasks/acted.log" "inside double quotes"
refused "grep -c acted ~/Work/tasks/acted.log > $probe" "a redirect"
refused "grep -c acted < ~/Work/tasks/acted.log" "a redirect"
refused "grep -c acted ~/Work/tasks/acted.log
touch $probe" "a second line"
refused "touch $probe" "'touch' is not an allowed read"
refused "bash -c 'touch $probe'" "'bash' is not an allowed read"
refused "/usr/bin/touch $probe" "no script or path is run"
# shellcheck disable=SC2088  # the check text itself carries the ~; outcome-read expands it, no shell does
refused "~/bin/land --check 5" "no script or path is run"
refused "cat ~/Work/tasks/acted.log | xargs touch" "'xargs' is not an allowed text tool"
refused "cat ~/Work/tasks/acted.log | awk 'BEGIN{system(\"touch $probe\")}'" "'awk' is not an allowed text tool"
refused "cat ~/Work/tasks/acted.log | sed -n 1p" "'sed' is not an allowed text tool"

echo "=== no logins: local reads stay in the task, log and tool folders ==="
refused "cat ~/.config/gh/hosts.yml" "outside the folders"
refused "grep -c k ~/.boss-os/vault.json" "outside the folders"
refused "cat ~/Work/tasks/../.config/gh/hosts.yml" "outside the folders"
refused "cat ~/Work/tasks/sneaky.log" "outside the folders"
refused "cat /etc/passwd" "outside the folders"
refused "ls ~/.config" "outside the folders"
refused "grep -c acted acted.log" "not a full path"
refused "cat ~/Work/tasks/acted.log | grep -f ~/.config/gh/hosts.yml" "grep -f is not allowed"
refused "cat ~/Work/tasks/acted.log | grep -c x ~/.config/gh/hosts.yml" "no file after a pipe"
refused "cat ~/Work/tasks/acted.log | jq --rawfile a ~/.config/gh/hosts.yml ." "jq --rawfile is not allowed"
refused "cat ~/Work/tasks/acted.log | jq -n env" "jq -n is not allowed"
refused "cat ~/Work/tasks/acted.log | sort -o ~/Work/tasks/x" "sort -o is not allowed"
refused "cat ~/Work/tasks/acted.log | head -1 | cat" "cat can only come first"

echo "=== the web: a plain https GET of a public address, with no sign-in ==="
refused "curl -s -d x=1 https://example.com/api" "curl -d is not allowed"
refused "curl -s -X POST https://example.com/api" "curl -X is not allowed"
refused "curl -s -H 'Authorization: Bearer x' https://example.com/" "curl -H is not allowed"
refused "curl -s -b ~/cookies https://example.com/" "curl -b is not allowed"
refused "curl -s -K ~/.curlrc https://example.com/" "curl -K is not allowed"
refused "curl -s -o ~/Work/tasks/x https://example.com/" "only as -o /dev/null"
refused "curl -s http://example.com/" "not a plain https address"
refused "curl -s https://user:pw@example.com/" "not a plain https address"
refused "curl -s file:///etc/passwd" "not a plain https address"
refused "curl -s https://127.0.0.1/" "not a public address"
refused "curl -s https://169.254.169.254/latest/meta-data/" "not a public address"
refused "curl -s https://192.168.1.1/" "not a public address"
refused "curl -s https://example.com/ https://127.0.0.1/" "not a public address"
refused "gh pr list" "only \`gh api"
refused "gh api -X DELETE repos/a/b" "gh api -X is not allowed"
refused "gh api -f title=x repos/a/b/issues" "gh api -f is not allowed"
refused "gh api --input x.json repos/a/b/issues" "gh api --input is not allowed"
refused "gh api https://evil.example/x" "plain API path"
refused "npx wrangler d1 execute db --remote --command 'SELECT 1'" "'npx' is not an allowed read"
refused "wrangler d1 execute db --remote --command 'SELECT 1'" "'wrangler' is not an allowed read"
rd --explain "gh api repos/seq23/seq-bin/pulls --jq length"; check "--explain on an allowed web check: rc 0, nothing read or printed" eval '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
rd --explain "curl -s -o /dev/null -w '%{http_code}' https://example.com/api | grep -c 401"; check "--explain: the status-code form is allowed" [ "$RC" -eq 0 ]

echo "=== what runs, and what it prints ==="
rd "grep -c acted ~/Work/tasks/acted.log"; check "grep -c on an allowed file: 3" eval '[ "$RC" -eq 0 ] && [ "$OUT" = 3 ]'
rd "grep -c nothing-like-this ~/Work/tasks/acted.log"; check "grep -c finding nothing prints 0 and is rc 0 (a reading, not a failure)" eval '[ "$RC" -eq 0 ] && [ "$OUT" = 0 ]'
rd "cat ~/Work/tasks/acted.log | grep -v skipped | wc -l"; check "a pipe of text tools: 3" eval '[ "$RC" -eq 0 ] && [ "$(tr -d " " <<<"$OUT")" = 3 ]'
rd "ls ~/Work/tasks | grep -c acted"; check "ls of an allowed folder piped to grep: 1" eval '[ "$RC" -eq 0 ] && [ "$OUT" = 1 ]'
rd "cat ~/Work/tasks/acted.log | jq -R . | jq -s length"; check "jq reads the output so far: 4" eval '[ "$RC" -eq 0 ] && [ "$OUT" = 4 ]'
rd "tail -n 1 ~/Work/tasks/acted.log"; check "tail -n 1: the last line" eval '[ "$RC" -eq 0 ] && [ "$OUT" = skipped ]'
rd "grep -c acted ~/Work/tasks/gone.log"; check "a missing file is rc 4, could not read, never a count" eval '[ "$RC" -eq 4 ] && grep -q "^could not read: " <<<"$OUT"'
rd --explain "grep -c acted ~/Work/tasks/acted.log; touch $probe"; check "--explain refuses the same way" eval '[ "$RC" -eq 3 ] && [ ! -e "$probe" ]'
rd ""; check "an empty check is refused" [ "$RC" -eq 3 ]
if [ "$(uname)" = Darwin ]; then
  rd "cat ~/Work/tasks/acted.log | head -1"
  check "on the Mac the text tools still run inside their no-network, no-write, no-home sandbox" eval '[ "$RC" -eq 0 ] && [ "$OUT" = "acted 1" ]'
else
  OUT="$(HOME="$H" OUTCOME_READ_NO_SANDBOX_OK='' "$R" "cat ~/Work/tasks/acted.log | head -1" 2>&1)"; RC=$?
  check "with no sandbox (and no test override), no text tool is run: rc 4" eval '[ "$RC" -eq 4 ] && grep -q "no sandbox" <<<"$OUT"'
fi
echo "outcome-read: $passes ok, $fails failed"
[ "$fails" -eq 0 ]
