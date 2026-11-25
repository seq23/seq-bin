#!/bin/bash
# land's forms gate (gate_forms, in the gates block, evaluated verbatim) and its wiring (her words 23 Nov 2026:
# "u need to make sure the forms are not broken … after theee fixes u need to test them"). One case per path:
# no Forms: line is refused; a reasoned none passes; a touched form needs a preview proof; placeholders never count;
# a later owner comment declaring a form wins over a body that says none. Then the wiring: land refuses by name,
# her bypass records "undeclared" instead of stopping, and the exit trap notes FORM-PROOF and starts post-land-check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAND="${LAND_UNDER_TEST:-$HERE/land}"
BLOCK="$(sed -n '/^# --- gates begin/,/^# --- gates end/p' "$LAND")"
[ -n "$BLOCK" ] || { echo "FAIL: no gates block in $LAND"; exit 1; }
eval "$(sed -n '/^forms_lines()/,/^}/p; /^gate_forms()/,/^}/p' <<<"$BLOCK")"
declare -F gate_forms >/dev/null || { echo "FAIL: gate_forms is not in land's gates block"; exit 1; }
fails=0; passes=0
ok()  { if "$@"; then passes=$((passes+1)); else echo "  FAIL $*"; fails=$((fails+1)); fi; }
refused() { local out; out="$(gate_forms 7 "$1")" && { echo "  FAIL refused: [$1] passed"; fails=$((fails+1)); return; }; grep -q "Forms: none" <<<"$out" && passes=$((passes+1)) || { echo "  FAIL refusal says nothing useful: $out"; fails=$((fails+1)); }; }
none()    { local out; out="$(gate_forms 7 "$1")" && [ -z "$out" ] && passes=$((passes+1)) || { echo "  FAIL none: [$1] -> rc/out [$out]"; fails=$((fails+1)); }; }
touched() { local out; out="$(gate_forms 7 "$1")" && [ "$out" = "$2" ] && passes=$((passes+1)) || { echo "  FAIL touched: [$1] -> [$out], want [$2]"; fails=$((fails+1)); }; }

refused "Review class: none — docs only change here"
refused "Forms: none"
refused "Forms: none — <why>"
refused "Forms: contact form"
refused "Forms: contact form — preview: <proof>"
refused "Forms: contact form — preview: ok"
none    "Forms: none — only the footer links change"
none    "- **Forms:** none — a scheduled job, no page"
touched "Forms: contact form — preview: TEST submission 200, Resend id re_1 received" "contact form"
touched "Forms: none — no form touched
Forms: request form — preview: TEST row rec123 stored in Airtable" "request form"
touched "* Forms: lead + RSVP — preview: two TEST posts, both 200 and stored" "lead + RSVP"

# Wiring, read from land itself (the flow tests run land end to end).
ok grep -q 'FORM_MSG="$(gate_forms "$PR" "$(owner_text <<<"$PRMETA")")"' "$LAND"
ok grep -q 'die "NAMED STOP \[FORMS_UNDECLARED\] $FORM_MSG"' "$LAND"
ok grep -q 'FORMS_DUE="undeclared (landed under her bypass; the diff touches $FORMFILES)"' "$LAND"
ok grep -q 'then note_form_proof "$FORMS_DUE"' "$LAND"
ok grep -q '"$runner" --now "$slug#$PR"' "$LAND"

# form_files (her words 25 Nov 2026: "form tests should only run on updates with forms"): a real repo, real commits.
eval "$(sed -n '/^FORM_FILE_RE=/p; /^FORM_MARK_RE=/p; /^form_files()/,/^}/p' <<<"$BLOCK")"
declare -F form_files >/dev/null || { echo "FAIL: form_files is not in land's gates block"; exit 1; }
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/site" "$R/functions/api" "$R/tests"
echo '<h1>home</h1>' > "$R/site/index.html"; echo '<form method="post"><input name=e></form>' > "$R/site/old.html"
git -C "$R" add -A; git -C "$R" commit -qm base; BASE="$(git -C "$R" rev-parse HEAD)"
echo '<form action="/api/lead"><button type="submit">Go</button></form>' > "$R/site/contact.html"
echo 'export async function onRequestPost({request}){ const d = await request.formData(); }' > "$R/functions/api/lead.js"
echo '<h1>home v2</h1>' > "$R/site/index.html"; echo '# notes <form>' > "$R/README.md"
echo 'new FormData()' > "$R/tests/lead.test.js"; git -C "$R" rm -q site/old.html
git -C "$R" add -A; git -C "$R" commit -qm pr; HD="$(git -C "$R" rev-parse HEAD)"
ff() { (cd "$R" && printf '%s\n' "$@" | form_files "$HD" "$BASE"); }
ok [ -z "$(ff site/index.html README.md tests/lead.test.js)" ]           # a plain page, docs and a test: no form test
ok [ "$(ff site/contact.html)" = "site/contact.html" ]                   # a page with a <form>
ok [ "$(ff functions/api/lead.js)" = "functions/api/lead.js" ]          # a form's server handler
ok [ "$(ff site/old.html)" = "site/old.html" ]                          # a deleted form page: read at the base
ok [ "$(ff site/gone.html)" = "site/gone.html (unread)" ]               # unreadable both ends: fail closed
ok [ "$(ff README.md site/contact.html | wc -l | tr -d ' ')" = 1 ]
ok grep -q 'form_files "$HEAD"' "$LAND"
ok grep -q 'the diff touches no form, so no form test runs' "$LAND"
# Negative proof: a check that never reads the files lets every page through as a form.
eval "$(sed -n '/^form_files()/,/^}/p' <<<"$BLOCK" | sed 's/elif grep -qE "$FORM_MARK_RE"/elif true || grep -qE "$FORM_MARK_RE"/')"
if [ -n "$(ff site/index.html)" ]; then passes=$((passes+1)); else echo "  FAIL the form_files mutation did not break it"; fails=$((fails+1)); fi
eval "$(sed -n '/^form_files()/,/^}/p' <<<"$BLOCK")"

# Negative proof: a gate that accepts any Forms: line lets a bare claim through.
eval "$(sed -n '/^gate_forms()/,/^}/p' <<<"$BLOCK" | sed 's/lines="$(forms_lines <<<"$2" | grep -v .<.)"/lines="$(forms_lines <<<"$2")"; [ -n "$lines" ] \&\& return 0/')"
if gate_forms 7 "Forms: contact form" >/dev/null; then passes=$((passes+1)); else echo "  FAIL the negative proof did not break the gate (mutation not applied)"; fails=$((fails+1)); fi

echo "land-forms: $passes ok, $fails failed"
[ "$fails" -eq 0 ]
