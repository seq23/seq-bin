#!/bin/bash
# pnp-real-work.mjs (the real-work photo step of the Marketplace listings job) against a stand-in
# for wrangler: no network, no credentials. What is under test is the step's own behaviour:
#   · photo sets and clips are fetched once, listed newest first, with the OUTPUT line the job greps
#   · a clip too big to attach is left out; the owner's saved photos are added
#   · a store that cannot be read is a NAMED STOP with exit 2, and the files fetched earlier stay usable
#   · the log lines never carry a file name or a note (they can name a customer)
# RULE 0: zero assertions is not a pass.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
JOB="$ROOT/pnp-real-work.mjs"
[ -f "$JOB" ] || { echo "NAMED STOP [MISSING] $JOB"; exit 3; }
command -v node >/dev/null 2>&1 || { echo "NAMED STOP [NO_NODE] node is not installed"; exit 3; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
asserts=0; failed=0
export TMP rc before after
ok()  { asserts=$((asserts + 1)); echo "  o $*"; }
bad() { asserts=$((asserts + 1)); failed=$((failed + 1)); echo "  x $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }   # check "what" command...
is() { bash -c "$1"; }

recent=$(node -e 'console.log(new Date(Date.now() - 2 * 86400000).toISOString())')
old="2026-01-05T10:00:00.000Z"
mkdir -p "$TMP/owner" "$TMP/out"
printf 'jpegbytes' > "$TMP/owner/party-backdrop.jpg"; printf 'Owner notes line.\n' > "$TMP/owner/README.md"
cat > "$TMP/wrangler" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/calls"
[ -f "$TMP/down" ] && { echo "Authentication error [code: 10000]" >&2; exit 1; }
if [ "\$1" = d1 ]; then
  case "\$*" in
    *photo_packs*) echo '[{"results":[{"id":"pck_old","at":"$old","edited":1,"note":"SECRETNAME shower","images":"[\"packs/pck_old/c1.jpg\"]"},{"id":"pck_new","at":"$recent","edited":0,"note":"hotel room","images":"[\"packs/pck_new/c1.jpg\",\"packs/pck_new/c2.jpg\"]"}]}]' ;;
    *) echo '[{"results":[{"id":"clp_big","at":"$recent","r2_key":"clips/big.mp4","note":"big"},{"id":"clp_ok","at":"$old","r2_key":"clips/ok.mp4","note":"ok"}]}]' ;;
  esac
else
  while [ \$# -gt 0 ]; do [ "\$1" = --file ] && dest="\$2"; shift; done
  case "\$dest" in *clp_big*) head -c 9500000 /dev/zero > "\$dest" ;; *) printf 'bytes' > "\$dest" ;; esac
fi
STUB
chmod +x "$TMP/wrangler"
run() { PNP_REAL_WORK_DIR="$TMP/out" PNP_REAL_WORK_OWNER_DIR="$TMP/owner" PNP_REAL_WORK_WRANGLER="$TMP/wrangler" node "$JOB" > "$TMP/log" 2>&1; echo $?; }

echo "1. a normal run"
rc=$(run)
check "exits 0" is '[ "$rc" = 0 ]'
check "last line is the OUTPUT line: 3 new (2 studio + the owner photo), 5 usable" is '[ "$(tail -1 "$TMP/log")" = "real work photos: OUTPUT 3 new, 5 usable" ]'
check "newest first in the manifest" is '[ "$(node -e "const m=require(\"$TMP/out/manifest.json\").photos;console.log(m.map(p=>p.date).join()===m.map(p=>p.date).sort().reverse().join()&&m.length===5)")" = true ]'
check "the 9.5 MB clip is not offered" is '! grep -q clp_big "$TMP/out/list.txt"'
check "the list gives full paths, the AI mark and the owner notes" is 'grep -q "^- $TMP/out/studio-2026-01-05-pck_old-1.jpg | 2026-01-05 | photo | .* | touched up with AI | " "$TMP/out/list.txt" && grep -q "| not marked as AI-edited | hotel room" "$TMP/out/list.txt" && grep -q "Owner notes line." "$TMP/out/list.txt"'
check "the log carries no file name and no note" is '! grep -q -e SECRETNAME -e pck_ -e backdrop "$TMP/log"'

echo "2. a second run fetches nothing twice"
before=$(grep -c "r2 object get" "$TMP/calls"); rc=$(run); after=$(grep -c "r2 object get" "$TMP/calls")
check "no file is downloaded again" is '[ "$before" = "$after" ] && [ "$before" = 5 ]'

echo "3. the store cannot be read"
touch "$TMP/down"; rc=$(run)
check "exits 2 with a NAMED STOP" is '[ "$rc" = 2 ] && grep -q "^NAMED STOP \[REAL_PHOTOS_NOT_READ\] " "$TMP/log"'
check "the files fetched earlier stay usable, and the OUTPUT line is still last" is '[ "$(tail -1 "$TMP/log")" = "real work photos: OUTPUT 3 new, 5 usable" ]'
rm -rf "$TMP/out" "$TMP/owner"; mkdir -p "$TMP/out"; rc=$(run)
check "nothing on this Mac and no store: a NAMED STOP and 0 usable, never a quiet pass" is '[ "$rc" = 2 ] && [ "$(tail -1 "$TMP/log")" = "real work photos: OUTPUT 0 new, 0 usable" ] && grep -q "none: use the site photos" "$TMP/out/list.txt"'

echo "$asserts assertions, $failed failed"
[ "$asserts" -gt 0 ] || { echo "NAMED STOP [NO_ASSERTIONS] the test examined nothing"; exit 3; }
[ "$failed" = 0 ]
