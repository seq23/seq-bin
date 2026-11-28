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

test("yours first with 🟡/🔴, then open by date, parked, and proving last; counts equal the rows sent", async () => {
  const loops = [...LOOPS, L("yes_row", { section: "not_finished", owner: "sequoia", title: "TEST Decide: keep it", next_date: "2999-01-02" }),
    L("dollar", { section: "proving", next_date: "2020-01-02", proof_pr: "seq23/x#1", title: "TEST check $' and $& stay text" })];
  const { code, html } = await mirror(200, loops);
  assert.equal(code, 0);
  assert.match(html, /<p class="sum">3 open · 1 overdue · 2 yours \(🟡 1 your yes · 🔴 1 only you\) · 2 landed, not yet proven · 2 parked<\/p>/);
  const at = (s) => html.indexOf(s);
  const yours = at('<h2 id="yours">'), open = at('<h2 id="open">'), parked = at('<h2 id="parked">'), proving = at('<h2 id="proving">');
  assert.ok(at('<p class="sum">') < yours && yours < open && open < parked && parked < proving, "order");
  const ys = html.slice(yours, open);
  assert.ok(ys.indexOf("🟡 TEST Decide: keep it") > 0 && ys.indexOf("🟡 TEST Decide") < ys.indexOf("🔴 TEST main_soon"), "🟡 rows lead, 🔴 after");
  assert.ok(!html.slice(open, parked).includes("main_soon"), "her rows are not repeated in Open");
  assert.match(html.slice(open, parked), /<h3 class="late">Overdue <small>1<\/small><\/h3>[\s\S]*TEST main_late/);
  const pk = html.slice(parked, proving);
  assert.match(pk, /TEST parked but holding a date<\/span><span class="m">Claude · Spry Labs<\/span>/);
  assert.ok(!/\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2}\b/.test(pk), "no date in parked");
  const pv = html.slice(proving);
  assert.match(pv, /Check Wed 1 Jan <small>1<\/small><\/h3><ul><li class="p"><span class="t">TEST form keeps nothing<\/span><span class="m">seq-bin #198<\/span>/);
  assert.ok(pv.includes("TEST check $&#39; and $&amp; stay text") || pv.includes("TEST check $' and $&amp; stay text"), "row text with $' is kept as text");
  assert.equal((html.match(/<h1>/g) ?? []).length, 1, "the page is not copied into itself");
  assert.equal((html.match(/<li class="p">/g) ?? []).length, 2);
  assert.ok(!html.includes("<details"), "nothing folded shut");
});

test("empty lists still show their heading with 0 and a plain line, never a missing section", async () => {
  const { code, html } = await mirror(200, LOOPS.filter((l) => l.section === "not_finished" && l.owner !== "sequoia"));
  assert.equal(code, 0);
  assert.match(html, /Yours <small>0<\/small><\/h2>[\s\S]*Nothing waiting on you\./);
  assert.match(html, /Landed, not yet proven <small>0<\/small><\/h2>[\s\S]*Nothing waiting on a live check\./);
  assert.match(html, /Parked, no date <small>0<\/small><\/h2><ul><li class="none">Nothing parked\.<\/li>/);
});

test("an unreadable list is a NAMED STOP and writes no page", async () => {
  const { code, o, html } = await mirror(500, []);
  assert.equal(code, 2);
  assert.match(o, /NAMED STOP \[LOOPS_UNREADABLE\]/);
  assert.equal(html, "");
});
