#!/bin/bash
# The patch-or-rebuild question is asked when the PR OPENS (her ruling 23 Nov 2026), through the real
# hook path: Claude Code's PreToolUse JSON for `gh pr create` into command-guard.mjs, which runs
# pr-patch-check, which runs land's own gate_patch. A real git origin holds a fix commit made today.
# Proves: a PR changing the fixed function with no "Patch or rebuild:" line is refused, naming the fix;
# the line in --body, in a heredoc body, or in --body-file lets it through; a placeholder line does not;
# a PR changing another function, a PR for another repo, or a folder it cannot judge is let through.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$BIN/command-guard.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0; ok(){ n=$((n+1)); echo "  ok   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }
hook() { node -e 'console.log(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' "$1" "$2" | node "$G"; }
denied() { grep -q '"permissionDecision":"deny"' <<<"$1"; }
gc() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/w" 2>/dev/null; git -C "$T/w" checkout -q -b main
printf 'function alpha() {\n  return 1;\n}\nfunction beta() {\n  return 2;\n}\n' > "$T/w/lib.js"
gc "$T/w" add lib.js; gc "$T/w" commit -q -m "add lib"
sed -i '' 's/return 1;/return 11;/' "$T/w/lib.js"; gc "$T/w" commit -q -am "lib: fix alpha's off-by-ten (#41)"
git -C "$T/w" push -q origin main 2>/dev/null; git -C "$T/w" fetch -q origin
git -C "$T/w" remote set-url origin https://github.com/seq23/demo.git   # the slug the guard reads (fetch done above)
git -C "$T/w" update-ref refs/remotes/origin/main main

gc "$T/w" checkout -q -b touch-alpha; sed -i '' 's/return 11;/return 12;/' "$T/w/lib.js"; gc "$T/w" commit -q -am "alpha again"

out=$(hook "gh pr create --title t --body 'changes alpha'" "$T/w")
denied "$out" && grep -q '#41' <<<"$out" && grep -q 'Patch or rebuild' <<<"$out" && ok "a PR changing alpha (fixed today in #41) with no line is refused, naming #41" || bad "unanswered patch not refused: $out"
out=$(hook "cd $T/w && gh pr create --title t --body 'x'" "/tmp")
denied "$out" && ok "…also after a 'cd <repo> &&' from another folder" || bad "cd form not judged: $out"
out=$(hook "gh pr create --title t --body 'Patch or rebuild: patch, alpha is one tested line and #41 left its shape right'" "$T/w")
[ -z "$out" ] && ok "the line in --body naming #41 with a reason lets it open" || bad "answered line refused: $out"
out=$(hook "gh pr create --title t --body \"\$(cat <<'EOF'
Some text.

Patch or rebuild: patch, because #41 fixed one constant and the design is sound.
EOF
)\"" "$T/w")
[ -z "$out" ] && ok "the line inside a heredoc body lets it open" || bad "heredoc answer refused: $out"
printf 'Body\nPatch or rebuild: patch, the alpha helper (#41) is one small tested function\n' > "$T/body.md"
out=$(hook "gh pr create --title t --body-file $T/body.md" "$T/w")
[ -z "$out" ] && ok "the line in --body-file lets it open" || bad "body-file answer refused: $out"
out=$(hook "gh pr create --title t --body 'Patch or rebuild: <why a patch and not a rebuild> (#41)'" "$T/w")
denied "$out" && ok "a copied placeholder is not an answer" || bad "placeholder accepted"

gc "$T/w" checkout -q -b touch-beta main; sed -i '' 's/return 2;/return 3;/' "$T/w/lib.js"; gc "$T/w" commit -q -am "beta"
out=$(hook "gh pr create --title t --body x" "$T/w")
[ -z "$out" ] && ok "a PR changing only beta (no recent fix) opens with nothing asked" || bad "unrelated function refused: $out"

gc "$T/w" checkout -q touch-alpha
out=$(hook "gh pr create --repo seq23/other --title t --body x" "$T/w")
[ -z "$out" ] && ok "a PR for another repo than the one checked out is left to land" || bad "other repo refused: $out"
out=$(hook "gh pr create --title t --body x" "$T/nowhere")
[ -z "$out" ] && ok "a folder it cannot see is let through (land still asks at merge)" || bad "missing folder refused: $out"
out=$(LAND_SRC=/nonexistent hook "gh pr create --title t --body x" "$T/w")
[ -z "$out" ] && ok "no land to read: let through, never a guess" || bad "no-land case refused"

# Negative proof: a checker that never runs land's gate passes the unanswered PR, and this test sees it.
cp "$BIN/pr-patch-check" "$T/pr-patch-check.bak"
sed -i '' 's/^msg="\$(gate_patch /msg="$(true /' "$BIN/pr-patch-check"
out=$(hook "gh pr create --title t --body 'changes alpha'" "$T/w")
cp "$T/pr-patch-check.bak" "$BIN/pr-patch-check"
denied "$out" && bad "mutation (gate never run) was not noticed" || ok "mutation: a checker that skips land's gate lets the unanswered PR through (so case 1 is real)"

node "$G" --self-test >/dev/null || bad "guard self-test"
[ "$fail" -eq 0 ] && echo "test-pr-patch-check: $n checks passed — the patch-or-rebuild line is asked for when the PR opens" || { echo "test-pr-patch-check: FAILED"; exit 1; }
