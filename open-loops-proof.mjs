// open-loops-proof.mjs — post-land-check's one write to Open Loops (her words 27 Nov 2026: "we need a new section
// on open loops for the not yet proven stuff and move it off the main list"). A row in the section
// "Landed, waiting on proof" (section `proving`) names the PR whose next-day live check decides it (`proof_pr`,
// "owner/repo#123"). When post-land-check has a verdict for that PR, this closes or returns every such row:
//
//   PASS → closed, reason "<repo> #<pr> live check passed <date>: <what it saw>"
//   FAIL → back on the main list: section not_finished, next date today, next step prefixed
//          "NOT WORKING (<date>): <what it saw> — "
//
// Matching is structure only: status open, section proving, proof_pr exactly the PR. A PR with no row is a no-op.
// Run from a boss-os checkout through the vault (BOSS_PASSCODE), as post-land-check does:
//   npm run -s vault:run -- node ~/bin/open-loops-proof.mjs --pr seq23/seq-bin#198 --verdict PASS --seen "…" --today 2026-11-28
// Prints one line per row (OPEN_LOOPS CLOSED|RETURNED <id>) or OPEN_LOOPS NONE <pr>.
// Exit 0 done (none included) · 2 bad arguments · 75 Open Loops could not be read or a write failed: the rows not
// yet written are left exactly as they were (never closed on unknown), and it says NAMED STOP [OPEN_LOOPS_UNREACHABLE].
//
// --sync <post-land-checks.md> (her words 28 Nov 2026: "there should be a fucking list on open loops … for landed not
// yet proven"): the OTHER half, the rows' birth. Until then nothing made a `proving` row when a PR landed, so 12 rows
// stood for ~180 DUE lines. One `proving` row per PR that has an `OUTCOME-CHECK DUE` line and no OPEN row (any
// section) already naming it in proof_pr: title "<repo> #<n>: <outcome, short>", finish line "Next-day live check
// passes: <check>", next date the by: day, owner claude, business the repo's brain (REPO_BRAIN, else spry). A line
// with no Outcome (her bypass) gets one too. Only DUE lines make rows; a DONE or FAIL line never does. Re-runs make
// nothing twice (matched on proof_pr first; Boss OS also keeps one open row per title). post-land-check runs it each
// night before its checks, and land-after after each land that owes a live check.
//   npm run -s vault:run -- node ~/bin/open-loops-proof.mjs --sync ~/Work/tasks/post-land-checks.md [--dry-run]
// Prints OPEN_LOOPS CREATED <pr> <id> per row, then OPEN_LOOPS SYNC <due PRs> due, <made> made, <had> had a row.
// Exit 0 · 2 the list is missing or unreadable · 3 Rule 0: NAMED STOP [SYNC_READ_NOTHING] (a non-empty list with no
// OUTCOME-CHECK line, or with DUE lines of which none could be read) or [SYNC_LINES_UNREAD] (some could not be read;
// the rest are made) · 75 NAMED STOP [OPEN_LOOPS_UNREACHABLE]: the list could not be read (nothing written) or a write
// failed (it stops there and says how many were made; the next sync makes the rest).
// Env: BOSS_ORIGIN (tests; default https://boss.sequoiataylor.com), BOSS_PASSCODE.
import { pathToFileURL } from "node:url";
import fs from "node:fs";

const PR_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9]\d{0,6}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/** What to do with the loops for one verdict. Pure. */
export function proofActions(loops, pr, verdict, seen, today) {
  const rows = (loops ?? []).filter((l) => l?.status === "open" && l.section === "proving" && l.proof_pr === pr);
  const [repo, n] = [pr.split("#")[0].split("/")[1], pr.split("#")[1]];
  const saw = String(seen ?? "").replace(/\s+/g, " ").trim();
  return rows.map((l) => verdict === "PASS"
    ? { id: l.id, act: "close", body: { reason: `${repo} #${n} live check passed ${today}: ${saw}`.slice(0, 400) } }
    : { id: l.id, act: "return", body: { section: "not_finished", next_date: today, next_step: `NOT WORKING (${today}): ${saw} — ${l.next_step ?? ""}`.trim().slice(0, 400) } });
}

// The repo's brain (a slug Boss OS accepts as `business`). Repo names are public; anything unlisted is Spry Labs.
export const REPO_BRAIN = Object.freeze({
  "boss-os": "personal", "seq-bin": "personal", "west-peek-os": "west-peek-ventures", "westpeek-live": "west-peek",
  "p-n-p": "porch-and-party", dailystory: "time-2-read", WKYS: "wkys",
  "horse-legal-guide-velocity": "friends", "hicks-consulting-canonical": "friends", "WPP-llm": "friends",
  "topbarz-voting": "friends", "cynthia-brown-dds-site": "friends", "dianne-place-recovery-services": "friends",
});
// land's line: - OUTCOME-CHECK DUE <owner/repo#n> <sha> — task:<slug> by:<day> expect:>=N|infer — outcome: <o> — check: <c>
// (the same shape post-land-check's outcome_lines reads; the outcome may itself hold " — ", the last " — check: " ends it).
const DUE_LINE = /^- OUTCOME-CHECK DUE ([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9]\d{0,6}) (\S+) — task:(\S*) by:(\d{4}-\d{2}-\d{2}) expect:(>=\d+|infer) — outcome: (.*) — check: (.*?)\s*$/;
const KIND_LINE = /^- OUTCOME-CHECK (\S+) /;

/** Every OUTCOME-CHECK line of the list, read. Pure. `due` holds one entry per PR (its first DUE line); `unread`
 *  holds each OUTCOME-CHECK line that is DUE but not in land's shape, or carries a status word that is not
 *  DUE/DONE/FAIL (a format that moved on must never read as "nothing due"). */
export function readDue(text) {
  const due = [], unread = [], seen = new Set(); let outcomeLines = 0;
  for (const line of String(text ?? "").split("\n")) {
    const k = KIND_LINE.exec(line); if (!k) continue;
    outcomeLines++;
    if (k[1] === "DONE" || k[1] === "FAIL") continue;
    const m = k[1] === "DUE" ? DUE_LINE.exec(line) : null;
    if (!m) { unread.push(line.slice(0, 120)); continue; }
    const [, pr, sha, task, by, expect, outcome, check] = m;
    if (seen.has(pr)) continue; seen.add(pr);
    due.push({ pr, sha, task, by, expect, outcome: outcome.trim(), check: check.trim() });
  }
  return { due, unread, outcomeLines };
}

const short = (s, n) => { const t = String(s ?? "").replace(/\s+/g, " ").trim(); if (t.length <= n) return t; const c = t.slice(0, n); return `${c.slice(0, c.lastIndexOf(" ") > n / 2 ? c.lastIndexOf(" ") : n).replace(/[\s,;:.—-]+$/, "")}…`; };

/** The rows to create: one per DUE PR with no open row naming it in proof_pr. Pure. */
export function syncActions(loops, due) {
  const had = new Set((loops ?? []).filter((l) => l?.status === "open" && l.proof_pr).map((l) => l.proof_pr));
  return due.filter((d) => !had.has(d.pr)).map((d) => {
    const repo = d.pr.split("#")[0].split("/")[1], n = d.pr.split("#")[1];
    const undeclared = d.expect === "infer" || /^UNDECLARED\b/.test(d.outcome);
    return { pr: d.pr, body: {
      title: `${repo} #${n}: ${undeclared ? "outcome undeclared — landed under her bypass" : short(d.outcome, 120)}`.slice(0, 200),
      finish_line: `Next-day live check passes: ${undeclared ? "a check the nightly checker writes from the PR (no Outcome was declared)" : short(d.check, 260)}`.slice(0, 300),
      next_step: `post-land-check runs it on or after ${d.by}: a pass closes this row, a fail brings it back marked NOT WORKING.`,
      next_date: d.by, owner: "claude", business: REPO_BRAIN[repo] ?? "spry", section: "proving", proof_pr: d.pr,
    } };
  });
}

function args(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith("--")) a[argv[i].slice(2)] = argv[i + 1]?.startsWith("--") || argv[i + 1] === undefined ? true : argv[++i];
  return a;
}

/** Sign in and read every row. Returns { cookie, loops } or { why } (never a list on unknown). */
async function readLoops(O) {
  try {
    const u = await fetch(`${O}/api/boss/auth/unlock`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ passcode: process.env.BOSS_PASSCODE ?? "" }), signal: AbortSignal.timeout(20000) });
    const cookie = (u.headers.get("set-cookie") ?? "").split(";")[0];
    if (!u.ok || !cookie) return { why: `sign-in answered HTTP ${u.status}` };
    const r = await fetch(`${O}/api/boss/open-loops`, { headers: { cookie }, signal: AbortSignal.timeout(20000) });
    const loops = (await r.json().catch(() => ({})))?.data?.loops;
    if (!r.ok || !Array.isArray(loops)) return { why: `the list answered HTTP ${r.status}` };
    return { cookie, loops };
  } catch (e) { return { why: `could not reach Open Loops (${e?.cause?.code ?? e?.name ?? "error"})` }; }
}

async function sync(a, O) {
  let text;
  try { text = fs.readFileSync(String(a.sync), "utf8"); } catch (e) { console.log(`NAMED STOP [DUE_FILE_UNREADABLE] ${a.sync} could not be read (${e.code ?? "error"}); no row was made`); return 2; }
  const { due, unread, outcomeLines } = readDue(text);
  const stopRead = (name, why) => { console.log(`NAMED STOP [${name}] ${why}`); for (const l of unread) console.log(`  unread: ${l}`); return 3; };
  // Rule 0: a list with words in it that yields nothing is a reader gone wrong, never "nothing due".
  if (text.trim() && !outcomeLines) return stopRead("SYNC_READ_NOTHING", `${a.sync} is not empty but holds no OUTCOME-CHECK line: the wrong file, or land's line changed shape; no row was made`);
  if (!due.length && unread.length) return stopRead("SYNC_READ_NOTHING", `${unread.length} OUTCOME-CHECK line(s) in ${a.sync} and none could be read; no row was made`);
  const stop = (why) => { console.log(`NAMED STOP [OPEN_LOOPS_UNREACHABLE] ${why}`); return 75; };
  if (!due.length) { console.log(`OPEN_LOOPS SYNC 0 due: every one of ${outcomeLines} outcome check(s) in ${a.sync} has its verdict`); return 0; }
  const got = await readLoops(O);
  if (got.why) return stop(`${got.why}; no row was made for the ${due.length} PR(s) waiting on proof`);
  const acts = syncActions(got.loops, due);
  let made = 0;
  for (const x of acts) {
    if (a["dry-run"]) { console.log(`[dry-run] OPEN_LOOPS would create ${x.pr}: ${JSON.stringify(x.body)}`); continue; }
    let r, j;
    try { r = await fetch(`${O}/api/boss/open-loops`, { method: "POST", headers: { "content-type": "application/json", cookie: got.cookie }, body: JSON.stringify(x.body), signal: AbortSignal.timeout(20000) }); j = await r.json().catch(() => ({})); }
    catch (e) { return stop(`made ${made} of ${acts.length} row(s), then ${x.pr} could not be written (${e?.cause?.code ?? e?.name ?? "error"}); the next sync makes the rest`); }
    if (!r.ok) return stop(`made ${made} of ${acts.length} row(s), then ${x.pr} answered HTTP ${r.status}; the next sync makes the rest`);
    made++; console.log(`OPEN_LOOPS CREATED ${x.pr} ${j?.data?.loop?.id ?? "?"}${j?.data?.deduped ? " (an open row of that title was kept)" : ""}`);
  }
  console.log(`OPEN_LOOPS SYNC ${due.length} due, ${a["dry-run"] ? `${acts.length} would be` : made} made, ${due.length - acts.length} had a row`);
  if (unread.length) return stopRead("SYNC_LINES_UNREAD", `${unread.length} OUTCOME-CHECK line(s) could not be read, so their PRs have no row`);
  return 0;
}

async function main() {
  const a = args(process.argv.slice(2));
  const O = process.env.BOSS_ORIGIN || "https://boss.sequoiataylor.com";
  if (a.sync !== undefined) {
    if (a.sync === true) { console.log("usage: open-loops-proof.mjs --sync <post-land-checks.md> [--dry-run]"); return 2; }
    return sync(a, O);
  }
  if (!PR_RE.test(String(a.pr ?? "")) || !["PASS", "FAIL"].includes(a.verdict) || !DAY_RE.test(String(a.today ?? ""))) {
    console.log("usage: open-loops-proof.mjs --pr owner/repo#N --verdict PASS|FAIL --seen <text> --today YYYY-MM-DD"); return 2;
  }
  const stop = (why) => { console.log(`NAMED STOP [OPEN_LOOPS_UNREACHABLE] ${why}; every row waiting on ${a.pr} not yet updated is left as it was`); return 75; };
  const got = await readLoops(O);
  if (got.why) return stop(got.why);
  const { cookie, loops } = got;
  const acts = proofActions(loops, a.pr, a.verdict, a.seen ?? "", a.today);
  if (!acts.length) { console.log(`OPEN_LOOPS NONE ${a.pr}`); return 0; }
  let bad = 0;
  for (const x of acts) {
    if (a["dry-run"]) { console.log(`[dry-run] OPEN_LOOPS would ${x.act} ${x.id}: ${JSON.stringify(x.body)}`); continue; }
    const url = x.act === "close" ? `${O}/api/boss/open-loops/${encodeURIComponent(x.id)}/close` : `${O}/api/boss/open-loops/${encodeURIComponent(x.id)}`;
    try {
      const r = await fetch(url, { method: x.act === "close" ? "POST" : "PUT", headers: { "content-type": "application/json", cookie }, body: JSON.stringify(x.body), signal: AbortSignal.timeout(20000) });
      if (r.ok) console.log(`OPEN_LOOPS ${x.act === "close" ? "CLOSED" : "RETURNED"} ${x.id}`);
      else { bad++; console.log(`OPEN_LOOPS NOT UPDATED ${x.id} (HTTP ${r.status})`); }
    } catch (e) { bad++; console.log(`OPEN_LOOPS NOT UPDATED ${x.id} (${e?.cause?.code ?? e?.name ?? "error"})`); }
  }
  return bad ? stop(`${bad} of ${acts.length} row write(s) failed`) : 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) process.exit(await main());
