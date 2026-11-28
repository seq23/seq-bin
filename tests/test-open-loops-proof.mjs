// open-loops-proof.mjs against a fake Boss OS (27 Nov 2026, "Landed, waiting on proof").
// Proves: only open `proving` rows whose proof_pr is exactly the PR are touched (two rows on one PR both are; a PR
// with no row is a no-op); PASS closes with the live check's words; FAIL returns the row to the main list dated
// today, next step marked NOT WORKING; Open Loops unreachable, a failed read or a failed write is exit 75 and no row
// is closed on unknown.
// --sync (28 Nov 2026): one `proving` row per PR with an OUTCOME-CHECK DUE line and no open row naming it; a DONE or
// FAIL line never makes one; an undeclared outcome still does; a re-run makes nothing twice; Open Loops down is exit
// 75 with no row claimed; a non-empty list read as nothing is a NAMED STOP (Rule 0).
// Run: node --test tests/test-open-loops-proof.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { proofActions, readDue, syncActions } from "../open-loops-proof.mjs";

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
  srv.unref(); // a failed assertion before close() never holds the run open
  return { origin: `http://127.0.0.1:${srv.address().port}`, writes, close: () => new Promise((r) => { srv.closeAllConnections?.(); srv.close(r); }) };
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

// ---- --sync ----
const DUE = (pr, by = "2026-11-29", rest = "expect:>=3 — outcome: TEST the page lists 3 rows — check: grep -c x ~/Work/tasks/a.md") => `- OUTCOME-CHECK DUE ${pr} abc123 — task:job by:${by} ${rest}`;
const LIST = [
  "# Post-land checks", "",
  DUE("seq23/seq-bin#301"),
  DUE("seq23/p-n-p#7", "2026-11-26", "expect:infer — outcome: UNDECLARED (owner bypass) — check: infer"),
  DUE("seq23/seq-bin#301", "2026-11-30"),                                          // a second DUE line for one PR: one row
  "- OUTCOME-CHECK DONE seq23/seq-bin#302 abc — task:j by:2026-11-26 expect:>=1 — outcome: TEST done — check: c → https://x",
  "- OUTCOME-CHECK FAIL seq23/seq-bin#303 abc — task:j by:2026-11-26 expect:>=1 — outcome: TEST failed — check: c → https://x",
  "- ENG-CHECK DUE seq23/seq-bin#304 abc — landed on green CI",
  "- FORM-PROOF DUE seq23/seq-bin#305 abc — forms: x",
].join("\n");

test("readDue: only OUTCOME-CHECK DUE lines, one per PR; DONE, FAIL and other kinds make nothing", () => {
  const { due, unread, outcomeLines } = readDue(LIST);
  assert.deepEqual(due.map((d) => d.pr), ["seq23/seq-bin#301", "seq23/p-n-p#7"]);
  assert.equal(due[0].by, "2026-11-29"); assert.equal(due[0].check, "grep -c x ~/Work/tasks/a.md");
  assert.deepEqual(unread, []); assert.equal(outcomeLines, 5);
  const odd = readDue("- OUTCOME-CHECK DUE seq23/seq-bin#9 abc — no shape here\n- OUTCOME-CHECK OWED seq23/seq-bin#8 abc — x");
  assert.equal(odd.due.length, 0); assert.equal(odd.unread.length, 2, "a DUE line out of shape, or an unknown status word, is unread, never skipped");
});

test("syncActions: the row's fields; an open row naming the PR (any section) means none; a closed one does not", () => {
  const { due } = readDue(LIST);
  const [a, b] = syncActions([], due);
  assert.deepEqual(a, { pr: "seq23/seq-bin#301", body: { title: "seq-bin #301: TEST the page lists 3 rows", finish_line: "Next-day live check passes: grep -c x ~/Work/tasks/a.md",
    next_step: "post-land-check runs it on or after 2026-11-29: a pass closes this row, a fail brings it back marked NOT WORKING.", next_date: "2026-11-29", owner: "claude", business: "personal", section: "proving", proof_pr: "seq23/seq-bin#301" } });
  assert.equal(b.body.title, "p-n-p #7: outcome undeclared — landed under her bypass"); assert.equal(b.body.business, "porch-and-party"); assert.equal(b.body.next_date, "2026-11-26");
  assert.equal(syncActions([], [{ ...due[0], pr: "seq23/keepmyproof#88" }])[0].body.business, "spry", "an unlisted repo falls back to spry");
  assert.deepEqual(syncActions([{ status: "open", section: "not_finished", proof_pr: "seq23/seq-bin#301" }], due).map((x) => x.pr), ["seq23/p-n-p#7"]);
  assert.deepEqual(syncActions([{ status: "closed", section: "proving", proof_pr: "seq23/seq-bin#301" }], due).map((x) => x.pr), ["seq23/seq-bin#301", "seq23/p-n-p#7"]);
  const long = syncActions([], [{ ...due[0], outcome: "word ".repeat(80) }])[0].body.title;
  assert.ok(long.length <= 200 && long.endsWith("…"), long);
});

/** A fake Boss OS that keeps the rows it is sent, as the real one does. mode: ok | list500 | write500 | writeAfter1 */
async function store(mode, rows = []) {
  const posts = [];
  const srv = http.createServer((req, res) => {
    let body = ""; req.on("data", (c) => (body += c)); req.on("end", () => {
      const send = (code, obj, h = {}) => { res.writeHead(code, { "content-type": "application/json", ...h }); res.end(JSON.stringify(obj)); };
      if (req.url === "/api/boss/auth/unlock") return send(200, { ok: true }, { "set-cookie": "boss_session=s; Path=/" });
      if (req.headers.cookie !== "boss_session=s") return send(401, {});
      if (req.method === "GET" && req.url === "/api/boss/open-loops") return send(mode === "list500" ? 500 : 200, { data: { loops: rows } });
      if (req.method === "POST" && req.url === "/api/boss/open-loops") {
        if (mode === "write500" || (mode === "writeAfter1" && posts.length >= 1)) return send(500, {});
        const b = JSON.parse(body || "{}"); posts.push(b); const loop = { id: `olp_${posts.length}`, status: "open", ...b }; rows.push(loop); return send(200, { data: { loop } });
      }
      send(404, {});
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  srv.unref(); // a failed assertion before close() never holds the run open
  return { origin: `http://127.0.0.1:${srv.address().port}`, posts, rows, close: () => new Promise((r) => { srv.closeAllConnections?.(); srv.close(r); }) };
}
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "olp-sync-"));
const listFile = (text) => { const f = path.join(dir, `l${Math.random().toString(36).slice(2)}.md`); fs.writeFileSync(f, text); return f; };
const runSync = (origin, file) => new Promise((resolve) => {
  const p = spawn(process.execPath, [SCRIPT, "--sync", file], { env: { ...process.env, BOSS_ORIGIN: origin, BOSS_PASSCODE: "x" } });
  let out = ""; p.stdout.on("data", (c) => (out += c)); p.stderr.on("data", (c) => (out += c)); p.on("close", (status) => resolve({ status, out }));
});

test("sync through the API: one proving row per DUE PR, and a second run makes nothing twice", async () => {
  const f = await store("ok"); const file = listFile(LIST);
  const r1 = await runSync(f.origin, file);
  assert.equal(r1.status, 0, r1.out);
  assert.deepEqual(f.posts.map((p) => `${p.proof_pr} ${p.section}`), ["seq23/seq-bin#301 proving", "seq23/p-n-p#7 proving"]);
  assert.match(r1.out, /OPEN_LOOPS SYNC 2 due, 2 made, 0 had a row/);
  const r2 = await runSync(f.origin, file); await f.close();
  assert.equal(r2.status, 0, r2.out); assert.equal(f.posts.length, 2, "no duplicate on re-run");
  assert.match(r2.out, /OPEN_LOOPS SYNC 2 due, 0 made, 2 had a row/);
});

test("sync outage: unreachable or a failed read is exit 75 with nothing written; a failed write stops and says how many were made", async () => {
  const file = listFile(LIST);
  const gone = await runSync("http://127.0.0.1:9", file);
  assert.equal(gone.status, 75, gone.out); assert.match(gone.out, /NAMED STOP \[OPEN_LOOPS_UNREACHABLE\]/); assert.doesNotMatch(gone.out, /CREATED|SYNC \d/);
  const l = await store("list500"); const r = await runSync(l.origin, file); await l.close();
  assert.equal(r.status, 75, r.out); assert.equal(l.posts.length, 0);
  const w = await store("writeAfter1"); const r2 = await runSync(w.origin, file); await w.close();
  assert.equal(r2.status, 75, r2.out); assert.match(r2.out, /made 1 of 2 row\(s\), then seq23\/p-n-p#7 answered HTTP 500/); assert.doesNotMatch(r2.out, /OPEN_LOOPS SYNC/);
});

test("sync Rule 0: a non-empty list read as nothing is a NAMED STOP, exit 3, nothing written; all-checked is exit 0", async () => {
  const f = await store("ok");
  const none = await runSync(f.origin, listFile("# Post-land checks\n\n- ENG-CHECK DUE seq23/x#1 abc — y\n"));
  assert.equal(none.status, 3, none.out); assert.match(none.out, /NAMED STOP \[SYNC_READ_NOTHING\]/);
  const bad = await runSync(f.origin, listFile("- OUTCOME-CHECK DUE seq23/x#1 abc — the shape moved on\n"));
  assert.equal(bad.status, 3, bad.out); assert.match(bad.out, /NAMED STOP \[SYNC_READ_NOTHING\]/);
  const part = await runSync(f.origin, listFile(`${DUE("seq23/seq-bin#310")}\n- OUTCOME-CHECK DUE seq23/x#1 abc — the shape moved on\n`));
  assert.equal(part.status, 3, part.out); assert.match(part.out, /NAMED STOP \[SYNC_LINES_UNREAD\]/); assert.match(part.out, /OPEN_LOOPS CREATED seq23\/seq-bin#310/);
  const done = await runSync(f.origin, listFile("- OUTCOME-CHECK DONE seq23/seq-bin#302 abc — task:j by:2026-11-26 expect:>=1 — outcome: o — check: c → u\n"));
  assert.equal(done.status, 0, done.out); assert.match(done.out, /OPEN_LOOPS SYNC 0 due/);
  const missing = await runSync(f.origin, path.join(dir, "nope.md")); await f.close();
  assert.equal(missing.status, 2, missing.out); assert.match(missing.out, /NAMED STOP \[DUE_FILE_UNREADABLE\]/);
  assert.equal(f.posts.length, 1, "only the readable DUE line made a row");
});
