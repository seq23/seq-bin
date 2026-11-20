#!/bin/bash
# Behaviour test for the dangerous-command guard as the hook it is: real Claude Code and Codex hook JSON
# on stdin. Proves: each irreversible command is refused with a reason (the deny JSON both tools read);
# a harmless command passes with no output; unreadable input is let through (a broken guard never stops
# every session); the self-test still catches every listed shape; the installer wires both tools into a
# fake HOME, keeps their other settings, and a second run changes nothing.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$BIN/command-guard.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; bad(){ echo "FAIL: $1"; fail=1; }
hook() { node -e 'console.log(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' "$1" "${2:-$T}" | node "$G"; }

node "$G" --self-test || bad "self-test failed"

# The shapes the owner named (19 Nov 2026), through the real hook path.
mkdir -p "$T/repo"; git -C "$T/repo" init -q -b main; git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m base
for c in "rm -rf $HOME/GitHub/boss-os" "git push --force origin main" "npx wrangler deploy" \
         "npx wrangler d1 execute WP_OS_DB --remote --command \"DROP TABLE prospects\"" "launchctl bootout gui/501/com.seq.ci-sweep"; do
  out=$(hook "$c" "$T/repo")
  echo "$out" | grep -q '"permissionDecision":"deny"' || bad "not refused: $c"
  echo "$out" | grep -q '"permissionDecisionReason":"Blocked by the dangerous-command guard' || bad "no reason given: $c"
done
# A force push with no branch named is judged on the current branch.
[ -n "$(hook "git push -f" "$T/repo")" ] || bad "a bare force push on main was not refused"
git -C "$T/repo" checkout -q -b feature
[ -z "$(hook "git push -f" "$T/repo")" ] || bad "a force push on a feature branch was refused"
# A DELETE in a file run on the live database is read from the file.
printf 'DELETE FROM people;\n' > "$T/fix.sql"
[ -n "$(hook "wrangler d1 execute db --remote --file=$T/fix.sql" "$T")" ] || bad "a DELETE inside --file was not refused"

# Harmless commands pass silently.
for c in "ls -la" "rm -rf $T/scratch" "git status" "npm test" "wrangler d1 export WP_OS_DB --remote --output $T/x.sql"; do
  [ -z "$(hook "$c" "$T")" ] || bad "a harmless command was refused: $c"
done
# Codex can send argv; a bash -lc string is opened.
out=$(node -e 'console.log(JSON.stringify({tool_name:"Bash",tool_input:{command:["bash","-lc","rm -rf ~/Brains"]},cwd:"/tmp"}))' | node "$G")
echo "$out" | grep -q deny || bad "Codex argv form was not refused"
# Unreadable input never blocks.
out=$(echo "not json" | node "$G" 2>/dev/null); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] || bad "unreadable input was not let through"

# The installer: both files, other settings kept, idempotent.
mkdir -p "$T/home/.claude"
echo '{"model":"x","hooks":{"Notification":[{"hooks":[{"type":"command","command":"n.sh"}]}]}}' > "$T/home/.claude/settings.json"
GUARD_HOME="$T/home" "$BIN/install-command-guard.sh" >/dev/null || bad "installer failed"
cp "$T/home/.claude/settings.json" "$T/first.json"
GUARD_HOME="$T/home" "$BIN/install-command-guard.sh" >/dev/null || bad "installer failed on the second run"
cmp -s "$T/first.json" "$T/home/.claude/settings.json" || bad "a second install changed settings.json"
node -e '
const s=require(process.argv[1]), c=require(process.argv[2]);
const ok = s.model==="x" && s.hooks.Notification.length===1 && s.hooks.PreToolUse.length===1 && s.hooks.PreToolUse[0].matcher==="Bash"
  && /command-guard\.mjs$/.test(s.hooks.PreToolUse[0].hooks[0].command) && c.hooks.PreToolUse.length===1;
process.exit(ok?0:1)' "$T/home/.claude/settings.json" "$T/home/.codex/hooks.json" || bad "installer did not wire both tools and keep the other settings"
GUARD_HOME="$T/home" "$BIN/install-command-guard.sh" --check >/dev/null || bad "--check did not see the wiring"
GUARD_HOME="$T/empty" "$BIN/install-command-guard.sh" --check >/dev/null 2>&1 && bad "--check passed with nothing wired"

[ $fail -eq 0 ] && echo "command-guard: ok"
exit $fail
