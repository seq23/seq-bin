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
d="$W/badcfg"; mkdir -p "$d"; echo '{ "kind": "poster" }' > "$d/ship-ready.json"
rc=$(judge "$d"); { [ "$rc" = 2 ] && grep -q 'SHIP_READY_CONFIG' "$d/log"; } && ok "a bad config is a named stop (exit 2)" || bad "bad config (rc $rc)"
[ "$fails" = 0 ] && echo "test-ship-ready-baseline: every automatic fail is caught and a clean page passes" || exit 1
