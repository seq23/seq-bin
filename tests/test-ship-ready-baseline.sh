#!/bin/bash
# ship-ready-baseline/check.mjs against fixture sites (row 18): a clean page passes; each automatic fail
# is caught by name (placeholder text, an emoji, sideways scroll at 390 px, a broken
# image, a missing description, a default 404); zero pages rendered is a fail (rule 0); a bad config
# is exit 2. Needs the tool's deps: npm ci --prefix ship-ready-baseline && npx playwright install chromium.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; TOOL="$HERE/ship-ready-baseline/check.mjs"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=1; }
HEAD_OK='<meta name="viewport" content="width=device-width"><title>Rentals</title><meta name="description" content="Party rentals in Memphis."><meta property="og:image" content="/og.png">'
page() { # dir body -> a one-page site with a real 404
  mkdir -p "$1"; printf '<!doctype html><html><head>%s</head><body style="font:16px sans-serif;color:#111;background:#fff">%s</body></html>' "$HEAD_OK" "$2" > "$1/index.html"
  printf '<!doctype html><html><head><title>Not here</title></head><body><h1>That page is not here</h1><p>%s</p><a href="/">Back to the home page</a></body></html>' "$(printf 'x%.0s' $(seq 1 200))" > "$1/404.html"
  printf '\x89PNG\r\n' > "$1/og.png"
  echo '{ "kind": "site", "serve": "site", "pages": ["/"] }' > "$(dirname "$1")/ship-ready.json"
}
judge() { (cd "$1" && node "$TOOL" --out "$1/out" > "$1/log" 2>&1); echo $?; }
case_() { # label body expected-rc grep-for
  local d="$W/$RANDOM$RANDOM"; page "$d/site" "$2"; local rc; rc=$(judge "$d")
  if [ "$rc" = "$3" ] && { [ -z "$4" ] || grep -qF -- "$4" "$d/log"; }; then ok "$1"; else bad "$1 (rc $rc): $(grep -E '^- |OUTPUT|STOP' "$d/log" | head -4 | tr '\n' ' ')"; fi
}
case_ "a clean page passes" '<h1>Tables and chairs for your party</h1><p>Delivered and set up.</p>' 0 "OUTPUT PASS"
d="$W/dark"; page "$d/site" '<style>@media (prefers-color-scheme: dark){body{background:#111!important;color:#eee!important}}</style><h1>Tables and chairs</h1>'
rc=$(judge "$d"); { [ "$rc" = 0 ] && [ -f "$d/out/shots/home-390-dark.png" ] && grep -q '"dark": "shots/home-390-dark.png"' "$d/out/baseline.json"; } && ok "a page with a dark mode gets a -dark screenshot" || bad "dark shot (rc $rc)"
d="$W/nodark"; page "$d/site" '<style>@keyframes s{to{transform:rotate(360deg)}}.s{display:inline-block;animation:s 1s linear infinite}</style><h1>Tables and chairs <span class="s">*</span></h1>'
rc=$(judge "$d"); { [ "$rc" = 0 ] && [ ! -e "$d/out/shots/home-390-dark.png" ] && grep -q '"dark": "none"' "$d/out/baseline.json"; } && ok "an animated page with no dark mode says dark: none, no extra screenshot" || bad "no-dark (rc $rc)"
d="$W/jsdark"; page "$d/site" '<style>.dk{background:#111!important;color:#eee!important}</style><script>if(matchMedia("(prefers-color-scheme: dark)").matches)document.documentElement.className="dk"</script><h1>Tables and chairs</h1>'
rc=$(judge "$d"); { [ "$rc" = 0 ] && [ -f "$d/out/shots/home-390-dark.png" ]; } && ok "a theme picked in script at load is read after a reload" || bad "js dark (rc $rc)"
d="$W/darkbudget"; page "$d/site" '<style>@media (prefers-color-scheme: dark){body{background:#111!important}}</style><h1>Tables and chairs</h1>'
rc=$( (cd "$d" && SHIP_READY_PAGE_SECS=20 node "$TOOL" --out "$d/out" > "$d/log" 2>&1); echo $?); { [ "$rc" = 0 ] && grep -q '"dark": "not read"' "$d/out/baseline.json"; } && ok "dark past the page budget says not read and never fails the page" || bad "dark budget (rc $rc)"
case_ "placeholder text fails" '<h1>Lorem ipsum dolor</h1>' 1 'placeholder text'
# Her ruling 23 Nov 2026 ("Drop the list"): no word list judges the writing, and an old "words" key is ignored,
# never a crash; the other automatic fails still catch that same page.
d="$W/words"; page "$d/site" '<h1>Unlock a seamless, tailored party</h1><p>Elevate it, dive in, delve, embark, empower, AI-powered sparkle.</p>'
echo '{ "kind": "site", "serve": "site", "pages": ["/"], "words": ["party"] }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 0 ] && grep -q 'OUTPUT PASS' "$d/log" && ! grep -qi 'banned' "$d/log"; } && ok "the old machine-writing words pass, and an old \"words\" key is ignored" || bad "old words (rc $rc): $(grep -E '^- |OUTPUT|STOP' "$d/log" | head -3 | tr '\n' ' ')"
d="$W/words-ph"; page "$d/site" '<h1>Unlock a seamless party</h1><p>TODO prices</p>'
echo '{ "kind": "site", "serve": "site", "pages": ["/"], "words": ["party"] }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q 'placeholder text: "TODO"' "$d/log"; } && ok "that config still fails on placeholder text" || bad "words + placeholder (rc $rc)"
case_ "an emoji fails" '<h1>Party time 🎉</h1>' 1 'emoji or sparkle'
case_ "© is text, not an emoji" '<p>© 2026 Porch and Party</p>' 0 "OUTPUT PASS"
case_ "sideways scroll at 390 px fails" '<div style="width:900px">wide</div>' 1 'scrolls sideways at 390'
case_ "a broken image fails" '<img src="/missing.png" alt="x">' 1 'missing.png'
case_ "text under 12 px fails" '<p style="font-size:11px">Small print</p>' 1 'text under 12 px: 11px "Small print"'
case_ "a ::before label under 12 px fails (how-we-know #416 phone tables)" '<style>td::before{content:attr(data-label);display:block;font-size:11.5px}</style><table><tr><td data-label="Cadence">Weekly</td></tr></table>' 1 'text under 12 px: 11.5px "Cadence"'
case_ "a ::before label at 12 px passes, and an icon glyph is not text" '<style>td::before{content:attr(data-label);display:block;font-size:12px}i::after{content:"→";font-size:8px}</style><table><tr><td data-label="Cadence">Weekly</td></tr></table><p>Next <i></i></p>' 0 "OUTPUT PASS"
d="$W/nodesc"; page "$d/site" '<p>Hello</p>'; sed -i.bak 's#<meta name="description" content="Party rentals in Memphis.">##' "$d/site/index.html"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q 'no meta description' "$d/log"; } && ok "a missing meta description fails" || bad "no description (rc $rc)"
d="$W/no404"; page "$d/site" '<p>Hello</p>'; rm "$d/site/404.html"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q '404 page is a server default' "$d/log"; } && ok "a default 404 fails" || bad "default 404 (rc $rc)"
d="$W/zero"; page "$d/site" '<p>Hello</p>'; echo '{ "kind": "site", "serve": "site", "pages": [] }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q 'ZERO pages rendered' "$d/log"; } && ok "zero pages rendered fails (rule 0)" || bad "zero pages (rc $rc)"
d="$W/sitemap"; page "$d/site" '<p>Home</p>'; mkdir -p "$d/site/menu"; cp "$d/site/index.html" "$d/site/menu/index.html"; sed -i.bak 's#<p>Home</p>#<p>Lorem ipsum menu</p>#' "$d/site/menu/index.html"
printf '<urlset><url><loc>https://x.test/</loc></url><url><loc>https://x.test/menu/</loc></url></urlset>' > "$d/site/sitemap.xml"; echo '{ "kind": "site", "serve": "site" }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q '/menu/ shows placeholder text' "$d/log"; } && ok "no pages listed: the sitemap's pages are judged" || bad "sitemap pages (rc $rc)"
d="$W/list"; page "$d/a" '<p>Fine</p>'; page "$d/b" '<p>TODO later</p>'; echo '[{ "kind": "site", "serve": "a", "pages": ["/"] }, { "kind": "site", "serve": "b", "pages": ["/"] }]' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q 'OUTPUT PASS' "$d/log" && grep -q 'placeholder text' "$d/log"; } && ok "a list judges each output; one red makes the check red" || bad "list (rc $rc)"
d="$W/notyet"; mkdir -p "$d"; echo '{ "kind": "app", "not_yet": "needs a signed-in API" }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 0 ] && grep -q 'NOT RUN YET (app) — needs a signed-in API' "$d/log"; } && ok "not_yet passes with its reason named" || bad "not_yet (rc $rc)"
case_ "Spanish \"todo\" is not a placeholder" '<p lang="es">Para todo el mundo</p>' 0 "OUTPUT PASS"
case_ "a page's /api call is server code, not a broken asset" '<p>Hi</p><script>fetch("/api/track-event", { method: "POST" })</script>' 0 "OUTPUT PASS"
d="$W/allow"; page "$d/site" '<p>App coming soon. TODO</p>'; echo '{ "kind": "site", "serve": "site", "pages": ["/"], "allow": { "coming soon": "the app is not in the stores yet" } }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 1 ] && grep -q 'placeholder text: "TODO"' "$d/log" && ! grep -q '"coming soon"' "$d/log"; } && ok "an allowed phrase (with its reason) passes; the TODO beside it still fails" || bad "allow (rc $rc)"
# live_origin: the site's own API on another host answers CORS for the live origin only. Without live_origin the
# local render is refused (a console error); with it the page passes; naming an origin the API refuses still fails.
# The kernel picks the port (listen 0) and the server writes it down: a random pick in 20000-40000 sat inside Linux's
# ephemeral range and collided with a live socket (main CI 22 Nov 2026, run 45062933627: EADDRINUSE 38766).
API_PORT_FILE="$W/api.port"; rm -f "$API_PORT_FILE"
node -e 'const s=require("http").createServer((q,r)=>{r.writeHead(200,{"content-type":"application/json","access-control-allow-origin":"https://x.test"});r.end("{\"left\":7}")});s.listen(0,"127.0.0.1",()=>require("fs").writeFileSync(process.argv[1],String(s.address().port)))' "$API_PORT_FILE" & API_PID=$!
for _ in $(seq 1 50); do [ -s "$API_PORT_FILE" ] && break; sleep 0.1; done
API_PORT="$(cat "$API_PORT_FILE" 2>/dev/null)"; [ -n "$API_PORT" ] || { bad "the live_origin test API never started"; API_PORT=1; }
API_BODY="<p id=n>Places left</p><script>fetch('http://127.0.0.1:$API_PORT/count').then(r=>r.json()).then(j=>{document.getElementById('n').textContent=j.left+' places left'})</script>"
for want in none https://x.test https://other.test; do
  d="$W/live-${want//[^a-z]/}"; page "$d/site" "$API_BODY"
  [ "$want" = none ] || echo "{ \"kind\": \"site\", \"serve\": \"site\", \"pages\": [\"/\"], \"live_origin\": \"$want\" }" > "$d/ship-ready.json"
  rc=$(judge "$d")
  case "$want" in
    https://x.test) { [ "$rc" = 0 ] && grep -q 'OUTPUT PASS' "$d/log"; } && ok "live_origin: the API that allows the live origin answers the render" || bad "live_origin allowed (rc $rc): $(grep -E '^- ' "$d/log" | head -2 | tr '\n' ' ')" ;;
    *) { [ "$rc" = 1 ] && grep -q 'console error' "$d/log"; } && ok "live_origin $want: a CORS refusal still fails" || bad "live_origin $want (rc $rc)" ;;
  esac
done
kill "$API_PID" 2>/dev/null
d="$W/badlive"; mkdir -p "$d"; echo '{ "kind": "site", "serve": ".", "live_origin": "http://x.test" }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 2 ] && grep -q 'live_origin must be an https origin' "$d/log"; } && ok "a non-https live_origin is a named stop" || bad "bad live_origin (rc $rc)"
# A signed-in console (kind web-app): a server that shows the app only with the session cookie, and
free_port() { # a port the kernel says is free now (bind 0, read it, let go); never a guess in the ephemeral range
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{process.stdout.write(String(s.address().port));s.close()})'
}
# a sign-in command that writes a Playwright storageState with the cookie it is given.
console_() { # dir cookie-value -> a console fixture whose sign-in writes that cookie
  mkdir -p "$1"; local port; port="$(free_port)"
  cat > "$1/server.mjs" <<'JS'
import { createServer } from "node:http";
createServer((req, res) => {
  const inn = /(^|;\s*)s=ok(;|$)/.test(req.headers.cookie || "");
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(`<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Studio</title></head><body style="font:16px sans-serif;color:#111;background:#fff">${inn ? '<nav aria-label="Main" style="display:none"><a href="/">Desktop</a></nav><nav aria-label="Main"><a href="/">Home</a></nav><h1>Your clips</h1>' : '<nav aria-label="Main" style="display:none"><a href="/">Hidden</a></nav><h1>Sign in</h1><p>Type your email.</p>'}</body></html>`);
}).listen(Number(process.argv[2]), "127.0.0.1");
JS
  printf 'const u = new URL(process.env.SHIP_READY_BASE_URL); require("fs").writeFileSync(process.env.SHIP_READY_STATE, JSON.stringify({ cookies: [{ name: "s", value: process.argv[2], domain: u.hostname, path: "/", expires: -1, httpOnly: true, secure: false, sameSite: "Lax" }], origins: [] }));\n' > "$1/sign-in.cjs"
  printf '{ "kind": "web-app", "serve": "node server.mjs %s", "base_url": "http://127.0.0.1:%s", "pages": ["/", "/review"], "sign_in": { "cmd": "node sign-in.cjs %s", "signed_in": "nav[aria-label=Main]" } }' "$port" "$port" "$2" > "$1/ship-ready.json"
}
d="$W/webapp"; console_ "$d" ok; rc=$(judge "$d")
{ [ "$rc" = 0 ] && grep -q 'OUTPUT PASS rendered=4' "$d/log" && ! find "$d/out" -name 'session.json' | grep -q .; } && ok "a signed-in console renders each page with its session at 390 and 1280 px (the session never in the artifact)" || bad "web-app signed in (rc $rc): $(grep -E '^- |OUTPUT|STOP' "$d/log" | head -4 | tr '\n' ' ')"
d="$W/webapp-out"; console_ "$d" wrong; rc=$(judge "$d")
{ [ "$rc" = 1 ] && grep -q '/review did not render signed in' "$d/log"; } && ok "a console page that shows the login screen fails by name" || bad "web-app signed out (rc $rc)"
d="$W/webapp-nosess"; console_ "$d" ok; sed -i.bak 's#"cmd": "node sign-in.cjs ok"#"cmd": "true"#' "$d/ship-ready.json"; rc=$(judge "$d")
{ [ "$rc" = 1 ] && grep -q 'wrote no session' "$d/log" && grep -q 'ZERO pages rendered' "$d/log"; } && ok "a sign-in that writes no session fails and judges nothing signed out" || bad "web-app no session (rc $rc)"
d="$W/webapp-cmdfail"; console_ "$d" ok; sed -i.bak 's#"cmd": "node sign-in.cjs ok"#"cmd": "node sign-in.cjs ok; exit 3"#' "$d/ship-ready.json"; rc=$(judge "$d")
{ [ "$rc" = 1 ] && grep -q 'the sign-in command failed (exit 3)' "$d/log" && grep -q 'ZERO pages rendered' "$d/log"; } && ok "a sign-in command that fails is red even when it wrote a session, and judges nothing" || bad "web-app sign-in exit 3 (rc $rc)"
for half in '{ "cmd": "true" }' '{ "cmd": "true", "signed_in": " " }' '{ "signed_in": "nav" }'; do
  d="$W/webapp-half$RANDOM"; mkdir -p "$d"; printf '{ "kind": "web-app", "serve": "x", "base_url": "http://127.0.0.1:1", "sign_in": %s }' "$half" > "$d/ship-ready.json"; rc=$(judge "$d")
  { [ "$rc" = 2 ] && grep -q 'sign_in needs cmd' "$d/log"; } && ok "a half-filled sign_in $half is a named stop (exit 2)" || bad "half sign_in $half (rc $rc)"
done
d="$W/webapp-nosignin"; mkdir -p "$d"; echo '{ "kind": "web-app", "serve": "x", "base_url": "http://127.0.0.1:1" }' > "$d/ship-ready.json"; rc=$(judge "$d")
{ [ "$rc" = 2 ] && grep -q 'web-app needs sign_in' "$d/log"; } && ok "a web-app with no sign_in is a named stop (exit 2)" || bad "web-app no sign_in (rc $rc)"
d="$W/badcfg"; mkdir -p "$d"; echo '{ "kind": "poster" }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 2 ] && grep -q 'SHIP_READY_CONFIG' "$d/log"; } && ok "a bad config is a named stop (exit 2)" || bad "bad config (rc $rc)"
# Every upload in the shared workflows sets retention-days, or the 90-day default fills the free Actions storage (27 Nov 2026).
up=$(grep -c 'uses: actions/upload-artifact' .github/workflows/*.yml | awk -F: '{s+=$2} END{print s+0}'); ret=$(grep -A8 'uses: actions/upload-artifact' .github/workflows/*.yml | grep -c 'retention-days: [1-9]')
{ [ "$up" -ge 1 ] && [ "$ret" = "$up" ]; } && ok "every artifact upload ($up) expires within days, not the 90-day default" || bad "uploads $up, with retention-days $ret"
[ "$fails" = 0 ] && echo "test-ship-ready-baseline: every automatic fail is caught and a clean page passes" || exit 1
