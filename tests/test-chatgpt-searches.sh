#!/bin/bash
# chatgpt-searches: a question counts only on the capture script's own record of a finished Temporary Chat; an outage
# (signed out, a ChatGPT limit, Chrome gone, her Claude limit) is COULDNT-CHECK with its reason on Notices, never a
# pass and never "0 gaps"; a night that checks nothing is never exit 0; a changed script or the session's own page
# code is refused; questions never name us; the Mac-hours guard holds; gaps become seeds in one PR, never without
# product facts. Everything runs against tests/fixtures/chatgpt-searches/fake-ai-run: no model, no browser.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSQ="$BIN/chatgpt-searches"
FAKE="$BIN/tests/fixtures/chatgpt-searches/fake-ai-run"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# A Friday 12:00 Central (hand runs) and a Friday 22:30 Central (the night window).
NOON="2026-11-27T18:00:00Z"; NIGHT="2026-11-28T04:30:00Z"

setup() { # $1 name, $2 seeds: none | facts | nofacts
  D="$T/$1"; mkdir -p "$D/out" "$D/state" "$D/brains" "$D/repos" "$D/bin"
  printf '# Spry\n## Company\n### KeepMyProof\n- A private phone app that keeps dated proof: papers, photos, notes. Folders for custody, tenants, insurance.\n- More facts about what it does for buyers who need proof.\n## Other\n- x\n' > "$D/brains/spry.md"
  local seeds='null, "seeds_why": "test site with no seeds home"'
  if [ "$2" != none ]; then
    seeds='{ "repo": "seq23/kmp-test", "config": "search-loop.config.json" }'
    git init -q --bare "$D/origin.git"
    git clone -q "$D/origin.git" "$D/repos/kmp-test" 2>/dev/null
    if [ "$2" = facts ]; then echo '{
  "site": "keepmyproof.com",
  "product": { "facts": ["It keeps dated proof on the phone."] },
  "seeds": ["an existing seed search"]
}' > "$D/repos/kmp-test/search-loop.config.json"
    else echo '{
  "site": "keepmyproof.com"
}' > "$D/repos/kmp-test/search-loop.config.json"; fi
    (cd "$D/repos/kmp-test" && git add -A && git -c user.name=t -c user.email=t@t commit -qm init && git branch -M main && git push -q origin main) || bad "$1: test repo setup"
  fi
  cat > "$D/sites.json" <<EOF
{ "sites": [ { "id": "keepmyproof", "label": "KeepMyProof", "night": 5, "about": "a private proof-keeping phone app",
  "brain": "spry", "brain_headings": ["KeepMyProof"], "domains": ["keepmyproof.com"], "names": ["KeepMyProof"], "seeds": $seeds } ] }
EOF
  printf '#!/bin/bash\necho "$1 | $2" >> "%s/notices.txt"\n' "$D" > "$D/bin/notice"
  printf '#!/bin/bash\necho "$@" >> "%s/gh.txt"\ncase "$1 $2" in "pr list") exit 0;; "pr create") echo https://github.com/seq23/kmp-test/pull/7;; esac\n' "$D" > "$D/bin/gh"
  printf '#!/bin/bash\necho "$@" >> "%s/land.txt"\necho "land-after: started pid 1"\n' "$D" > "$D/bin/land-after"
  mkdir -p "$D/engine/bin"
  cat > "$D/engine/bin/search-loop.mjs" <<'EOF'
import fs from "node:fs"; import path from "node:path";
const a = process.argv; const root = a[a.indexOf("--root") + 1]; const c = JSON.parse(fs.readFileSync(path.join(root, a[a.indexOf("--config") + 1]), "utf8"));
if (!Array.isArray(c.seeds) || c.seeds.length > 25 || !(c.product?.facts?.length)) { console.error("NAMED STOP [CONFIG_INVALID] seeds"); process.exit(1); }
console.log("config OK (config and model routing)");
EOF
  chmod +x "$D/bin/"*
}
run() { # $1 name, then args; env FAKE_CSQ, NOW
  local D="$T/$1"; shift
  CSQ_SITES="$D/sites.json" CSQ_OUT="$D/out" CSQ_STATE="$D/state" CSQ_BRAINS="$D/brains" CSQ_AI_RUN="$FAKE" CSQ_REPOS="$D/repos" \
  CSQ_ENGINE_DIR="$D/engine" CSQ_GH="$D/bin/gh" CSQ_LAND_AFTER="$D/bin/land-after" CSQ_NOTICE="$D/bin/notice" CSQ_LOGS="$D/logs" CSQ_OPEN_CHROME=0 \
  CSQ_NOW="${NOW:-$NOON}" FAKE_LOG="$D/calls.txt" "$CSQ" "$@" > "$D/run.txt" 2>&1
  echo $?
}

# 1. A good night: 5 questions checked, the searches in the site file, exit 0, the rollup written.
setup ok none
rc=$(FAKE_CSQ=ok run ok --hand --sites keepmyproof)
D="$T/ok"; md="$D/out/2026-11-27/keepmyproof.md"
[ "$rc" = 0 ] || bad "ok: exit $rc, want 0 ($(tail -3 "$D/run.txt"))"
grep -q "OUTPUT 5 questions checked" "$D/run.txt" || bad "ok: no 'OUTPUT 5 questions checked' line"
[ -f "$md" ] && grep -q '`buyer need 3 app search one`' "$md" || bad "ok: the captured searches are not in $md"
grep -q "RivalApp 2" "$md" && ! grep -q "Invented App ·\|· Invented App\|named: Invented" "$md" || bad "ok: names not checked against the answer"
grep -q "Ours showed up in 0 of 5 checked chats" "$md" || bad "ok: the score line is wrong"
[ -f "$D/out/rollup-2026-W48.md" ] && grep -q "| KeepMyProof | 5/5 | 0 of 5 |" "$D/out/rollup-2026-W48.md" || bad "ok: rollup row missing"
[ ! -s "$D/notices.txt" ] || bad "ok: a good night wrote a Notices line"
grep -q "no-home: test site" "$md" || bad "ok: a site with no seeds home does not say so"

# 2. Signed out of ChatGPT: COULDNT-CHECK with the reason on Notices, exit 75, never a pass or "0 gaps".
setup out none
rc=$(FAKE_CSQ=signedout run out --hand --sites keepmyproof)
D="$T/out"
[ "$rc" = 75 ] || bad "signed out: exit $rc, want 75"
grep -q "COULDNT-CHECK: ChatGPT is signed out in Chrome" "$D/run.txt" || bad "signed out: no COULDNT-CHECK line with the reason"
grep -q "COULDNT-CHECK tonight — ChatGPT is signed out" "$D/notices.txt" 2>/dev/null || bad "signed out: no Notices line with the reason"
grep -qi "0 gaps\|CHATGPT-SEARCHES-COMPLETE" "$D/run.txt" && bad "signed out: reported as complete or as 0 gaps"
grep -q '"status": "CHECKED"' "$D/state/week-2026-W48.json" && bad "signed out: a question counted as checked"

# 3. Rule 0: the session asks nothing (no wall) — FAIL, exit 1, Notices; never exit 0.
setup zero none
rc=$(FAKE_CSQ=zero run zero --hand --sites keepmyproof)
D="$T/zero"
[ "$rc" = 1 ] || bad "zero: exit $rc, want 1"
grep -q "OUTPUT 0 questions checked — FAIL" "$D/run.txt" || bad "zero: no FAIL census line"
grep -q "FAIL tonight — 0 questions checked" "$D/notices.txt" 2>/dev/null || bad "zero: no Notices line"

# 4. ChatGPT's temporary limit after 2 answers: stop, 2 checked, the rest owed; the next night asks only 3, 4, 5.
setup lim none
rc=$(FAKE_CSQ=limit2 run lim --hand --sites keepmyproof)
D="$T/lim"
[ "$rc" = 75 ] || bad "limit: exit $rc, want 75"
grep -q "OUTPUT 2 questions checked — PARTIAL: 2 questions checked, then ChatGPT said it hit a temporary limit" "$D/run.txt" || bad "limit: census wrong: $(grep OUTPUT "$D/run.txt")"
grep -q "COULDNT-CHECK tonight — 2 questions checked, then ChatGPT said" "$D/notices.txt" 2>/dev/null || bad "limit: no Notices line"
: > "$D/calls.txt"
rc=$(FAKE_CSQ=ok NOW="2026-11-29T04:30:00Z" run lim)
[ "$rc" = 0 ] || bad "limit resume: exit $rc, want 0 ($(tail -2 "$D/run.txt"))"
grep -q "asked 3,4,5: Q3 checked, Q4 checked, Q5 checked" "$D/run.txt" || bad "limit resume: did not ask exactly the owed questions"
grep -q "^bare" "$D/calls.txt" && bad "limit resume: wrote new questions mid-week"

# 5. Chrome or the extension gone: COULDNT-CHECK NO_CHROME.
setup chrome none
rc=$(FAKE_CSQ=nochrome run chrome --hand --sites keepmyproof)
D="$T/chrome"
[ "$rc" = 75 ] && grep -q "Chrome or the Claude in Chrome extension was not reachable" "$D/run.txt" || bad "no chrome: exit $rc / reason missing"

# 6. Her Claude plan's limit (both models): COULDNT-CHECK, exit 75; the second model was tried.
setup climit none
rc=$(FAKE_CSQ=claudelimit run climit --hand --sites keepmyproof)
D="$T/climit"
[ "$rc" = 75 ] && grep -q "her Claude plan's usage limit" "$D/run.txt" || bad "claude limit: exit $rc / reason missing"
[ "$(grep -c '^bare' "$D/calls.txt")" = 2 ] || bad "claude limit: the second model was not tried"

# 7. A changed capture script, the session's own page code, or a chat that is not temporary: nothing counts.
for m in badinstall offscript nottemp; do
  setup "$m" none
  rc=$(FAKE_CSQ=$m run "$m" --hand --sites keepmyproof)
  D="$T/$m"
  [ "$rc" != 0 ] || bad "$m: exit 0"
  grep -q '"status": "CHECKED"' "$D/state/week-2026-W48.json" && bad "$m: a question counted as checked"
done
grep -q "SCRIPT_CHANGED" "$T/badinstall/out/2026-11-27/keepmyproof.md" || bad "badinstall: reason not shown"
grep -q "OFF_SCRIPT" "$T/offscript/out/2026-11-27/keepmyproof.md" || bad "offscript: reason not shown"
grep -q "not a temporary chat" "$T/nottemp/out/2026-11-27/keepmyproof.md" || bad "nottemp: reason not shown"

# 8. Questions that name us are refused (tried twice), the site is not asked.
setup brand none
rc=$(FAKE_CSQ=brand run brand --hand --sites keepmyproof)
D="$T/brand"
[ "$rc" = 1 ] && grep -q "QUESTIONS_REFUSED: q1: names us" "$D/run.txt" || bad "brand: exit $rc / not refused"
grep -q "^chrome" "$D/calls.txt" && bad "brand: asked ChatGPT anyway"

# 9. The Mac-hours guard: the scheduled run refuses outside 22:00-01:59; a hand run refuses 07:00-09:59.
setup guard none
rc=$(FAKE_CSQ=ok run guard)
[ "$rc" = 3 ] && grep -q "OUTSIDE_NIGHT" "$T/guard/run.txt" || bad "guard: a scheduled run at noon was not refused (exit $rc)"
rc=$(FAKE_CSQ=ok NOW="2026-11-27T14:30:00Z" run guard --hand)
[ "$rc" = 3 ] && grep -q "MAC_REST" "$T/guard/run.txt" || bad "guard: a hand run at 08:30 was not refused (exit $rc)"
[ ! -s "$T/guard/calls.txt" ] || bad "guard: a model ran outside the hours"
rc=$(FAKE_CSQ=ok NOW="$NIGHT" run guard)
[ "$rc" = 0 ] || bad "guard: the 22:30 scheduled run failed (exit $rc: $(tail -2 "$T/guard/run.txt"))"

# 10. Seeds: gaps go into the config through ONE PR handed to land-after, checked by the engine's validator.
setup seeds facts
rc=$(FAKE_CSQ=ours1 run seeds --hand --sites keepmyproof)
D="$T/seeds"
[ "$rc" = 0 ] || bad "seeds: exit $rc ($(tail -3 "$D/run.txt"))"
git -C "$D/origin.git" show chatgpt-seeds/keepmyproof-2026-W48:search-loop.config.json > "$D/pushed.json" 2>/dev/null || bad "seeds: no branch pushed"
node -e 'const c=require(process.argv[1]); const q=c.seeds.map(s=>typeof s==="string"?s:s.query); if(q[0]!=="an existing seed search"||q.length!==5||q.includes("app for buyer need 1 with no account")) process.exit(1)' "$D/pushed.json" \
  || bad "seeds: the pushed config does not keep the old seed and add the 4 gaps (Q1 had us): $(cat "$D/pushed.json")"
grep -q "pr create -R seq23/kmp-test" "$D/gh.txt" || bad "seeds: no PR opened"
grep -q "^7 --repo seq23/kmp-test --task chatgpt-seeds-keepmyproof" "$D/land.txt" || bad "seeds: land-after not run on the PR"
grep -q "Review class: none" "$D/state/pr-body-keepmyproof-2026-W48.md" && grep -q "^## Not built" "$D/state/pr-body-keepmyproof-2026-W48.md" && grep -q "^Outcome: " "$D/state/pr-body-keepmyproof-2026-W48.md" || bad "seeds: PR body lacks land's lines"
grep -q "PR https://github.com/seq23/kmp-test/pull/7" "$D/out/2026-11-27/keepmyproof.md" || bad "seeds: the site file does not link the PR"
[ -z "$(git -C "$D/repos/kmp-test" worktree list | sed 1d)" ] || bad "seeds: the worktree was left behind"

# 11. No product facts: no seeds are written (the engine would refuse them), and it says why.
setup nofacts nofacts
rc=$(FAKE_CSQ=ok run nofacts --hand --sites keepmyproof)
D="$T/nofacts"
grep -q "waiting: NO_PRODUCT_FACTS" "$D/out/2026-11-27/keepmyproof.md" || bad "nofacts: the reason is not shown"
if [ -e "$D/gh.txt" ] && grep -q "pr create" "$D/gh.txt"; then bad "nofacts: a PR was opened"; fi

# 12. A drop against last week is a Notices line.
setup drop none
D="$T/drop"
node -e '
const rows={}; for(let n=1;n<=5;n++) rows[n]={n,status:"CHECKED",ours:n<=3,queries:["q"],read_domains:[]};
require("fs").writeFileSync(process.argv[1], JSON.stringify({week:"2026-W47",start_slot:1,sites:{keepmyproof:{questions:["a?","b?","c?","d?","e?"],asked:rows}},nights:[]}));' "$D/state/week-2026-W47.json"
rc=$(FAKE_CSQ=ours1 run drop --hand --sites keepmyproof)
grep -q "showed up in 1 of 5 ChatGPT chats this week, down from 3 of 5 last week" "$D/notices.txt" 2>/dev/null || bad "drop: no Notices line (exit $rc)"
grep -q "| KeepMyProof | 5/5 | 1 of 5 | 3 of 5 |" "$D/out/rollup-2026-W48.md" || bad "drop: rollup does not show last week"

# 13. The clock: Friday 22:30 and Saturday 01:30 Central are the same night; ISO week; minutes to 02:00.
node -e '
const c=require(process.argv[1]); const a=c.central(new Date("2026-11-28T04:30:00Z")), b=c.central(new Date("2026-11-28T07:30:00Z"));
const ok = c.nightOf(a)==="2026-11-27" && c.nightOf(b)==="2026-11-27" && c.isoWeek("2026-11-27")==="2026-W48" && c.isoWeek("2026-11-30")==="2026-W49" && c.isoWeek("2026-11-29")==="2026-W48"
  && c.slotOf("2026-11-29")===7 && c.minutesToTwo(a)===210 && c.minutesToTwo(b)===30;
process.exit(ok?0:1);' "$CSQ" || bad "clock: night, week or window wrong"
# Our names in any spelling are refused; a plain buyer question is not.
node -e '
const c=require(process.argv[1]); const s={names:["KeepMyProof","Porch & Party"],domains:["keepmyproof.com","porchandparty901.com"]};
const ok = c.namesUs("is keep my proof good?",s) && c.namesUs("Porch and Party reviews?",s) && c.namesUs("try porchandparty901",s) && !c.namesUs("best app to keep proof for court?",s);
process.exit(ok?0:1);' "$CSQ" || bad "names: brand check wrong"

# The cited list she reads: one App Store link per app, no picture files.
node -e '
const c=require(process.argv[1]); const t=c.tidyCited(["apps.apple.com/us/app/x/id1","apps.apple.com/fj/app/x/id1","media.gettyimages.com/id/2/photo/a.jpg","cdn.site.com/p.png","site.com/a"]);
process.exit(JSON.stringify(t)===JSON.stringify(["apps.apple.com/us/app/x/id1","site.com/a"])?0:1);' "$CSQ" || bad "cited: App Store duplicates or pictures kept"

[ $fail -eq 0 ] && echo "chatgpt-searches: ok"
exit $fail
