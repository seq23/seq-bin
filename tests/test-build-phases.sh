#!/bin/bash
# build-phases against a stub ai-run and a stub gh, with a local bare repo as origin.
# Proves: ready only when Codex says complete AND checks are green; red CI's log is the next brief;
# two idle rounds are STUCK (exit 3); a Codex limit is exit 75 with the round's work pushed;
# a reviewer's fail sends Codex back and READY needs a result newer than the review.
set -uo pipefail
# HOME is moved to a temp dir and CI runners have no git identity: give the commits one.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
HERE="$(cd "$(dirname "$0")/.." && pwd)"; BP="$HERE/build-phases"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }

setup() {
  T="$(mktemp -d)"; export HOME="$T/home"; mkdir -p "$HOME/GitHub" "$T/bin" "$T/briefs"
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$HOME/GitHub/app" 2>/dev/null
  ( cd "$HOME/GitHub/app" && git commit -q --allow-empty -m init && git push -q origin HEAD:main )
  git -C "$HOME/GitHub/app" fetch -q
  echo "phases" > "$T/briefs/PHASES.md"
  # stub gh: PR exists after create; checks bucket from $T/checks (one line per call, last repeats)
  cat > "$T/bin/gh" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "pr list") [ -f "$T/pr" ] && echo "https://example.test/pr/1" ;;
  "pr create") touch "$T/pr" ;;
  "pr checks") if [ "\${4:-}" = --watch ] || [ "\${3:-}" = --watch ]; then exit 0; fi
               n=\$(cat "$T/checks.n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$T/checks.n"
               sed -n "\${n}p" "$T/checks" | grep . || tail -1 "$T/checks" ;;
  "run list") echo 99 ;;
  "run view") echo "TypeError: boom in screen.tsx" ;;
esac
EOF
  chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
  export BUILD_PHASES_CLONE="$HOME/GitHub/app" BUILD_PHASES_AIRUN="$T/bin/ai-run"
}
# stub ai-run: behaviour per round from $T/plan (line N = round N): work|complete|idle|limit
airun() { cat > "$T/bin/ai-run" <<EOF
#!/bin/bash
cwd=""; while [ \$# -gt 0 ]; do case "\$1" in --cwd) cwd="\$2"; shift 2;; --) shift; break;; *) shift;; esac; done
echo "\$*" >> "$T/prompts"
n=\$(cat "$T/round" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$T/round"
case "\$(sed -n "\${n}p" "$T/plan")" in
  work) echo x\$n > "\$cwd/f\$n" ; echo "STATUS: incomplete" > "$T/briefs/phase-1-result.md" ;;
  complete) echo x\$n > "\$cwd/f\$n"; sleep 1; echo "STATUS: complete" > "$T/briefs/phase-1-result.md" ;;
  idle) : ;;
  limit) echo half > "\$cwd/half"; exit 75 ;;
esac
EOF
chmod +x "$T/bin/ai-run"; }
run() { "$BP" --repo o/app --briefs "$T/briefs" --phase 1 --rounds 5 > "$T/out" 2>&1; echo $?; }

setup; airun; printf 'work\ncomplete\n' > "$T/plan"; echo green > "$T/checks"
rc=$(run); { [ "$rc" = 0 ] && grep -q '^OUTPUT READY https://example.test/pr/1' "$T/out"; } && ok "ready after complete + green" || bad "ready ($rc): $(tail -2 "$T/out")"
[ "$(git -C "$T/origin.git" log --oneline codex/app-phase-1 | wc -l)" -ge 3 ] && ok "each round's work committed and pushed by the runner" || bad "rounds not pushed"

setup; airun; printf 'complete\ncomplete\n' > "$T/plan"; printf 'fail\npass\n' > "$T/checks"
rc=$(run); { [ "$rc" = 0 ] && grep -q 'TypeError: boom' "$T/prompts"; } && ok "red CI log is the next round's brief" || bad "red CI ($rc)"

setup; airun; printf 'work\nidle\nidle\nwork\n' > "$T/plan"; echo green > "$T/checks"
rc=$(run); { [ "$rc" = 3 ] && grep -q '^OUTPUT STUCK' "$T/out"; } && ok "two idle rounds are STUCK" || bad "stuck ($rc): $(tail -1 "$T/out")"

setup; airun; printf 'limit\n' > "$T/plan"; echo green > "$T/checks"
rc=$(run); { [ "$rc" = 75 ] && git -C "$T/origin.git" show codex/app-phase-1:half >/dev/null 2>&1; } && ok "Codex limit exits 75 with work pushed" || bad "limit ($rc)"

setup; airun; printf 'complete\ncomplete\n' > "$T/plan"; echo green > "$T/checks"
mkdir -p "$T/briefs/reviews"; echo "VERDICT: fail" > "$T/briefs/reviews/hostile-phase-1.md"; touch -t 202601010000 "$T/briefs/reviews/hostile-phase-1.md"
echo "STATUS: complete" > "$T/briefs/phase-1-result.md"; touch -t 202501010000 "$T/briefs/phase-1-result.md"
rc=$(run); { [ "$rc" = 0 ] && grep -q 'reviewer FAILED' "$T/prompts"; } && ok "a reviewer's fail sends Codex back" || bad "review ($rc): $(tail -1 "$T/out")"

# negative proof: never READY while Codex still says incomplete, even with green checks
setup; airun; printf 'work\nwork\n' > "$T/plan"; echo green > "$T/checks"
"$BP" --repo o/app --briefs "$T/briefs" --phase 1 --rounds 2 > "$T/out" 2>&1; rc=$?
{ [ "$rc" = 3 ] && grep -q '^OUTPUT ROUND_CAP' "$T/out"; } && ok "never READY while incomplete" || bad "negative ($rc)"
exit $fail
