// open-loops-proof.mjs against a fake Boss OS (27 Nov 2026, "Landed, waiting on proof").
// Proves: only open `proving` rows whose proof_pr is exactly the PR are touched (two rows on one PR both are; a PR
// with no row is a no-op); PASS closes with the live check's words; FAIL returns the row to the main list dated
// today, next step marked NOT WORKING; Open Loops unreachable, a failed read or a failed write is exit 75 and no row
// is closed on unknown.
// Run: node --test tests/test-open-loops-proof.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { proofActions } from "../open-loops-proof.mjs";

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "open-loops-proof.mjs");
const PR = "seq23/seq-bin#198";
const row = (id, over = {}) => ({ id, title: `TEST ${id}`, status: "open", section: "proving", proof_pr: PR, next_step: "Check it kept the entry.", ...over });
const LOOPS = [
  row("olp_a"), row("olp_b"),
  row("olp_other", { proof_pr: "seq23/seq-bin#19" }),         // a different PR (prefix of nothing, not "contains")
  row("olp_main", { section: "not_finished" }),               // same PR, but on the main list
  row("olp_closed", { status: "closed" }),
];

test("only open proving rows naming exactly that PR are acted on; none is a no-op", () => {
  assert.deepEqual(proofActions(LOOPS, PR, "PASS", "saw 3", "2026-11-28").map((a) => a.id), ["olp_a", "olp_b"]);
  assert.deepEqual(proofActions(LOOPS, "seq23/boss-os#1", "PASS", "saw 3", "2026-11-28"), []);
});

test("PASS closes with the check's words; FAIL returns it dated today, marked NOT WORKING", () => {
  const [pass] = proofActions([row("olp_a")], PR, "PASS", "saw 3 kept entries", "2026-11-28");
  assert.deepEqual(pass, { id: "olp_a", act: "close", body: { reason: "seq-bin #198 live check passed 2026-11-28: saw 3 kept entries" } });
  const [fail] = proofActions([row("olp_a")], PR, "FAIL", "saw 0, needed at least 1", "2026-11-28");
  assert.deepEqual(fail, { id: "olp_a", act: "return", body: { section: "not_finished", next_date: "2026-11-28", next_step: "NOT WORKING (2026-11-28): saw 0, needed at least 1 — Check it kept the entry." } });
});

/** A fake Boss OS: `mode` = ok | list500 | write500. Records every write. */
async function fake(mode) {
  const writes = [];
  const srv = http.createServer((req, res) => {
    let body = ""; req.on("data", (c) => (body += c)); req.on("end", () => {
      const send = (code, obj, h = {}) => { res.writeHead(code, { "content-type": "application/json", ...h }); res.end(JSON.stringify(obj)); };
      if (req.url === "/api/boss/auth/unlock") return send(200, { ok: true }, { "set-cookie": "boss_session=s; Path=/" });
      if (req.headers.cookie !== "boss_session=s") return send(401, {});
      if (req.method === "GET" && req.url === "/api/boss/open-loops") return send(mode === "list500" ? 500 : 200, { data: { loops: LOOPS } }); // a 500 that still carries rows is never read as the list
      if (mode === "write500") return send(500, {});
      writes.push({ method: req.method, url: req.url, body: JSON.parse(body || "{}") }); send(200, { ok: true });
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  return { origin: `http://127.0.0.1:${srv.address().port}`, writes, close: () => new Promise((r) => srv.close(r)) };
}
// Async, so the fake server in this process can answer while the script runs.
const run = (origin, verdict) => new Promise((resolve) => {
  {
    const p = spawn(process.execPath, [SCRIPT, "--pr", PR, "--verdict", verdict, "--seen", "saw 3", "--today", "2026-11-28"], { env: { ...process.env, BOSS_ORIGIN: origin, BOSS_PASSCODE: "x" } });
    let out = ""; p.stdout.on("data", (c) => (out += c)); p.stderr.on("data", (c) => (out += c));
    p.on("close", (status) => resolve({ status, out }));
  }
});

test("PASS through the API: both rows closed with the reason, nothing else written", async () => {
  const f = await fake("ok");
  const r = await run(f.origin, "PASS"); await f.close();
  assert.equal(r.status, 0, r.out);
  assert.deepEqual(f.writes.map((w) => `${w.method} ${w.url}`), ["POST /api/boss/open-loops/olp_a/close", "POST /api/boss/open-loops/olp_b/close"]);
  assert.equal(f.writes[0].body.reason, "seq-bin #198 live check passed 2026-11-28: saw 3");
  assert.match(r.out, /OPEN_LOOPS CLOSED olp_a/);
});

test("FAIL through the API: both rows PUT back on the main list", async () => {
  const f = await fake("ok");
  const r = await run(f.origin, "FAIL"); await f.close();
  assert.equal(r.status, 0, r.out);
  assert.deepEqual(f.writes.map((w) => `${w.method} ${w.url} ${w.body.section}`), ["PUT /api/boss/open-loops/olp_a not_finished", "PUT /api/boss/open-loops/olp_b not_finished"]);
});

test("outage: unreachable, a failed list read or a failed write is exit 75, NAMED STOP, never a close on unknown", async () => {
  const gone = await run("http://127.0.0.1:9", "PASS");
  assert.equal(gone.status, 75, gone.out); assert.match(gone.out, /NAMED STOP \[OPEN_LOOPS_UNREACHABLE\]/);
  const f = await fake("list500");
  const r = await run(f.origin, "PASS"); await f.close();
  assert.equal(r.status, 75, r.out); assert.equal(f.writes.length, 0);
  const w = await fake("write500");
  const r2 = await run(w.origin, "PASS"); await w.close();
  assert.equal(r2.status, 75, r2.out); assert.match(r2.out, /OPEN_LOOPS NOT UPDATED olp_a/);
});

test("bad arguments are exit 2 and reach nothing", () => {
  const r = spawnSync(process.execPath, [SCRIPT, "--pr", "seq-bin 198", "--verdict", "PASS", "--today", "2026-11-28"], { env: { ...process.env, BOSS_ORIGIN: "http://127.0.0.1:9" }, encoding: "utf8" });
  assert.equal(r.status, 2);
});
