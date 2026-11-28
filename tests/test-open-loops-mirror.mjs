// open-loops-mirror.mjs against a fake Boss OS (27 Nov 2026 "Landed, waiting on proof"; 28 Nov 2026 the two lists).
// Proves: directly under the summary line, before any dated heading and never folded, come "Landed, not yet proven
// (N)" (each row's PR as "repo #n" and its check date) then "Parked, no date (N)" (no date, even when the row holds
// one); a `proving` row is not counted open, overdue or yours, even long past its date, and appears in no dated
// group; counts equal the rows sent; an unreadable list is a NAMED STOP, never an empty page.
// Run: node --test tests/test-open-loops-mirror.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "open-loops-mirror.mjs");
const L = (id, over) => ({ id, title: `TEST ${id}`, status: "open", owner: "claude", business: "spry", next_step: "s", finish_line: "f", ...over });
const LOOPS = [
  L("main_late", { section: "not_finished", next_date: "2020-01-01" }),
  L("main_soon", { section: "not_finished", next_date: "2999-01-01", owner: "sequoia" }),
  L("proof_late", { section: "proving", next_date: "2020-01-01", owner: "sequoia", proof_pr: "seq23/seq-bin#198", title: "TEST form keeps nothing" }),
  L("idea", { section: "parked", next_date: null }),
  L("idea_dated", { section: "parked", next_date: "2026-12-25", title: "TEST parked but holding a date" }),
];

async function mirror(status, loops) {
  const srv = http.createServer((req, res) => {
    if (req.url === "/api/boss/auth/unlock") { res.writeHead(200, { "set-cookie": "boss_session=s; Path=/" }); return res.end("{}"); }
    res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify({ data: { loops } }));
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "olm-"));
  const out = await new Promise((resolve) => {
    const p = spawn(process.execPath, [SCRIPT], { env: { ...process.env, BOSS_ORIGIN: `http://127.0.0.1:${srv.address().port}`, OPEN_LOOPS_MIRROR_DIR: dir, BOSS_PASSCODE: "x" } });
    let o = ""; p.stdout.on("data", (c) => (o += c)); p.on("close", (code) => resolve({ code, o }));
  });
  await new Promise((r) => srv.close(r));
  const file = path.join(dir, "index.html");
  return { ...out, html: fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "" };
}

test("both lists sit under the summary, open, in order, before any dated heading; proving is off the main list", async () => {
  const { code, html } = await mirror(200, LOOPS);
  assert.equal(code, 0);
  assert.match(html, /<p class="sum">2 open · 1 overdue · 1 yours · 1 landed, not yet proven · 2 parked<\/p>/);
  const sum = html.indexOf('<p class="sum">');
  const proofAt = html.indexOf('<h2 class="list">Landed, not yet proven <small>1</small></h2>');
  const parkAt = html.indexOf('<h2 class="list">Parked, no date <small>2</small></h2>');
  const firstDated = html.indexOf('<h2 class="late">');
  assert.ok(sum > 0 && sum < proofAt && proofAt < parkAt && parkAt < firstDated, `order: summary ${sum} < proving ${proofAt} < parked ${parkAt} < first dated ${firstDated}`);
  assert.ok(!html.includes("<details class=\"park\">") && !/<summary><h2/.test(html), "neither list is folded");
  const proving = html.slice(proofAt, parkAt), parked = html.slice(parkAt, firstDated), dated = html.slice(firstDated);
  assert.match(proving, /TEST form keeps nothing<\/span><span class="s">seq-bin #198 · live check Wed 1 Jan<\/span>/);
  assert.match(parked, /TEST idea<\/span>/); assert.match(parked, /TEST parked but holding a date<\/span><span class="s">Claude · Spry Labs<\/span>/);
  assert.ok(!/\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2}\b/.test(parked), "no date printed in the parked list");
  assert.ok(!dated.includes("form keeps nothing") && !dated.includes("TEST idea"), "no proving or parked row in the dated list");
  assert.equal((proving.match(/<li /g) ?? []).length, 1); assert.equal((parked.match(/<li /g) ?? []).length, 2);
});

test("empty lists still show their heading with 0 and a plain line, never a missing section", async () => {
  const { code, html } = await mirror(200, LOOPS.filter((l) => l.section === "not_finished"));
  assert.equal(code, 0);
  assert.match(html, /Landed, not yet proven <small>0<\/small><\/h2>[\s\S]*Nothing waiting on a live check\./);
  assert.match(html, /Parked, no date <small>0<\/small><\/h2><ul><li class="none">Nothing parked\.<\/li>/);
});

test("an unreadable list is a NAMED STOP and writes no page", async () => {
  const { code, o, html } = await mirror(500, []);
  assert.equal(code, 2);
  assert.match(o, /NAMED STOP \[LOOPS_UNREADABLE\]/);
  assert.equal(html, "");
});
