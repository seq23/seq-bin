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
ok grep -q 'FORMS_DUE="undeclared (landed under her bypass)"' "$LAND"
ok grep -q 'then note_form_proof "$FORMS_DUE"' "$LAND"
ok grep -q '"$runner" --now "$slug#$PR"' "$LAND"

# Negative proof: a gate that accepts any Forms: line lets a bare claim through.
eval "$(sed -n '/^gate_forms()/,/^}/p' <<<"$BLOCK" | sed 's/lines="$(forms_lines <<<"$2" | grep -v .<.)"/lines="$(forms_lines <<<"$2")"; [ -n "$lines" ] \&\& return 0/')"
if gate_forms 7 "Forms: contact form" >/dev/null; then passes=$((passes+1)); else echo "  FAIL the negative proof did not break the gate (mutation not applied)"; fails=$((fails+1)); fi

echo "land-forms: $passes ok, $fails failed"
[ "$fails" -eq 0 ]
