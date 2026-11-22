#!/bin/bash
# TEMP probe (removed after): the live_origin trio from test-ship-ready-baseline.sh, N times, printing the judge's
# own fail lines whenever a case is wrong.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; TOOL="$HERE/ship-ready-baseline/check.mjs"; W="$(mktemp -d)"
HEAD_OK='<meta name="viewport" content="width=device-width"><title>Rentals</title><meta name="description" content="Party rentals in Memphis."><meta property="og:image" content="/og.png">'
page() { mkdir -p "$1"; printf '<!doctype html><html><head>%s</head><body style="font:16px sans-serif;color:#111;background:#fff">%s</body></html>' "$HEAD_OK" "$2" > "$1/index.html"
  printf '<!doctype html><html><head><title>Not here</title></head><body><h1>That page is not here</h1><p>%s</p><a href="/">Back to the home page</a></body></html>' "$(printf 'x%.0s' $(seq 1 200))" > "$1/404.html"
  printf '\x89PNG\r\n' > "$1/og.png"; echo '{ "kind": "site", "serve": "site", "pages": ["/"] }' > "$(dirname "$1")/ship-ready.json"; }
API_PORT=$((20000 + RANDOM % 20000))
node -e 'require("http").createServer((q,r)=>{r.writeHead(200,{"content-type":"application/json","access-control-allow-origin":"https://x.test"});r.end("{\"left\":7}")}).listen(+process.argv[1],"127.0.0.1")' "$API_PORT" &
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$API_PORT/" >/dev/null && break; sleep 0.1; done
API_BODY="<p id=n>Places left</p><script>fetch('http://127.0.0.1:$API_PORT/count').then(r=>r.json()).then(j=>{document.getElementById('n').textContent=j.left+' places left'})</script>"
bad=0
for i in $(seq 1 "${N:-20}"); do
  for want in none https://x.test https://other.test; do
    d="$W/$i-${want//[^a-z]/}"; page "$d/site" "$API_BODY"
    [ "$want" = none ] || echo "{ \"kind\": \"site\", \"serve\": \"site\", \"pages\": [\"/\"], \"live_origin\": \"$want\" }" > "$d/ship-ready.json"
    rc=$( (cd "$d" && node "$TOOL" --out "$d/out" > "$d/log" 2>&1); echo $?)
    case "$want" in https://x.test) good=$([ "$rc" = 0 ] && echo y) ;; *) good=$([ "$rc" = 1 ] && grep -q 'console error' "$d/log" && echo y) ;; esac
    if [ "$good" = y ]; then echo "ok   $i $want rc $rc"; else bad=$((bad + 1)); echo "BAD  $i $want rc $rc"; grep -E '^\s+- |@|OUTPUT' "$d/log" | sed 's/^/       /'; fi
  done
done
echo "PROBE: $bad bad of $(( ${N:-20} * 3 ))"; [ "$bad" -eq 0 ]
