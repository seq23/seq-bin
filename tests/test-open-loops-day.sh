#!/bin/bash
# open-loops.mjs withDay: the due day in Central, right across both clock changes and midnight (review F2, N4).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
node --input-type=module -e '
import { withDay } from "./open-loops.mjs";
const d = (iso, day) => withDay({ stop: "T", next_date: day }, Date.parse(iso)).next_date;
const want = [
  ["2026-11-01T05:30:00Z", "tomorrow", "2026-11-02"], // 00:30 CDT on the fall-back day (a 25 h day)
  ["2027-03-14T05:30:00Z", "tomorrow", "2027-03-14"], // 23:30 CST the night before spring-forward (a 23 h day)
  ["2026-11-23T05:59:00Z", "today", "2026-11-22"],    // 23:59 CST
  ["2026-11-23T06:01:00Z", "today", "2026-11-23"],    // 00:01 CST
  ["2026-12-31T23:00:00Z", "tomorrow", "2027-01-01"],
];
let bad = 0;
for (const [iso, day, exp] of want) { const got = d(iso, day); if (got !== exp) { console.log(`FAIL ${day} at ${iso}: ${got}, want ${exp}`); bad++; } }
for (const day of ["2026-13-45", "2026-02-30", "soon", undefined]) {
  try { withDay({ stop: "T", next_date: day }); console.log(`FAIL ${day} was accepted`); bad++; } catch (e) { if (!/OPEN_LOOPS_NO_DAY/.test(e.message)) { console.log(`FAIL ${day}: ${e.message}`); bad++; } }
}
if (withDay({ stop: "T", cleared: true }).next_date !== undefined) { console.log("FAIL a close was given a day"); bad++; }
if (bad) process.exit(1);
console.log("test-open-loops-day: ok — both clock changes, midnight, year end, and no made-up dates");
'
