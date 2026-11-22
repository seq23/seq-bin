#!/bin/bash
# ship-ready-baseline/check.mjs against fixture sites (row 18): a clean page passes; each automatic fail
# is caught by name (placeholder text, a banned word, an emoji, sideways scroll at 390 px, a broken
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
case_ "placeholder text fails" '<h1>Lorem ipsum dolor</h1>' 1 'placeholder text'
case_ "a banned word fails" '<h1>Unlock a seamless party</h1>' 1 'banned word'
case_ "an emoji fails" '<h1>Party time 🎉</h1>' 1 'emoji or sparkle'
case_ "© is text, not an emoji" '<p>© 2026 Porch and Party</p>' 0 "OUTPUT PASS"
case_ "sideways scroll at 390 px fails" '<div style="width:900px">wide</div>' 1 'scrolls sideways at 390'
case_ "a broken image fails" '<img src="/missing.png" alt="x">' 1 'missing.png'
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
# A signed-in console (kind web-app): a server that shows the app only with the session cookie, and
# a sign-in command that writes a Playwright storageState with the cookie it is given.
console_() { # dir cookie-value -> a console fixture whose sign-in writes that cookie
  mkdir -p "$1"; local port=$((20000 + RANDOM % 20000))
  cat > "$1/server.mjs" <<'JS'
import { createServer } from "node:http";
createServer((req, res) => {
  const inn = /(^|;\s*)s=ok(;|$)/.test(req.headers.cookie || "");
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(`<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Studio</title></head><body style="font:16px sans-serif;color:#111;background:#fff">${inn ? '<nav aria-label="Main"><a href="/">Home</a></nav><h1>Your clips</h1>' : "<h1>Sign in</h1><p>Type your email.</p>"}</body></html>`);
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
d="$W/webapp-nosignin"; mkdir -p "$d"; echo '{ "kind": "web-app", "serve": "x", "base_url": "http://127.0.0.1:1" }' > "$d/ship-ready.json"; rc=$(judge "$d")
{ [ "$rc" = 2 ] && grep -q 'web-app needs sign_in' "$d/log"; } && ok "a web-app with no sign_in is a named stop (exit 2)" || bad "web-app no sign_in (rc $rc)"
d="$W/badcfg"; mkdir -p "$d"; echo '{ "kind": "poster" }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 2 ] && grep -q 'SHIP_READY_CONFIG' "$d/log"; } && ok "a bad config is a named stop (exit 2)" || bad "bad config (rc $rc)"
[ "$fails" = 0 ] && echo "test-ship-ready-baseline: every automatic fail is caught and a clean page passes" || exit 1
