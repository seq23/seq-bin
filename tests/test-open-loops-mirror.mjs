// open-loops-mirror.mjs against a fake Boss OS (27 Nov 2026, "Landed, waiting on proof").
// Proves: a `proving` row is off the main list (not counted open, overdue or yours, even long past its date), sits in
// its own folded section with its PR between the dated list and Parked, and the header says "N waiting on proof";
// an unreadable list is a NAMED STOP, never an empty page.
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

test("a proving row is off the main list and out of every count but its own", async () => {
  const { code, html } = await mirror(200, LOOPS);
  assert.equal(code, 0);
  assert.match(html, /<p class="sum">2 open · 1 overdue · 1 yours · 1 waiting on proof · 1 parked<\/p>/);
  const overdue = html.slice(html.indexOf('<h2 class="late">'), html.indexOf("Landed, waiting on proof"));
  assert.ok(!overdue.includes("form keeps nothing"), "the proving row is not in the dated list");
  const proofAt = html.indexOf("Landed, waiting on proof <small>1</small>"), parkedAt = html.indexOf("<h2>Parked");
  assert.ok(proofAt > 0 && proofAt < parkedAt, "its section sits before Parked");
  const section = html.slice(proofAt, parkedAt);
  assert.match(section, /TEST form keeps nothing/);
  assert.match(section, /waiting on seq23\/seq-bin#198's live check/);
  assert.match(html, /<details class="park"><summary><h2>Landed, waiting on proof/, "folded, like Parked");
});

test("an unreadable list is a NAMED STOP and writes no page", async () => {
  const { code, o, html } = await mirror(500, []);
  assert.equal(code, 2);
  assert.match(o, /NAMED STOP \[LOOPS_UNREADABLE\]/);
  assert.equal(html, "");
});
