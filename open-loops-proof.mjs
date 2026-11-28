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
// Env: BOSS_ORIGIN (tests; default https://boss.sequoiataylor.com), BOSS_PASSCODE.
import { pathToFileURL } from "node:url";

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

function args(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith("--")) a[argv[i].slice(2)] = argv[i + 1]?.startsWith("--") || argv[i + 1] === undefined ? true : argv[++i];
  return a;
}

async function main() {
  const a = args(process.argv.slice(2));
  if (!PR_RE.test(String(a.pr ?? "")) || !["PASS", "FAIL"].includes(a.verdict) || !DAY_RE.test(String(a.today ?? ""))) {
    console.log("usage: open-loops-proof.mjs --pr owner/repo#N --verdict PASS|FAIL --seen <text> --today YYYY-MM-DD"); return 2;
  }
  const O = process.env.BOSS_ORIGIN || "https://boss.sequoiataylor.com";
  const stop = (why) => { console.log(`NAMED STOP [OPEN_LOOPS_UNREACHABLE] ${why}; every row waiting on ${a.pr} not yet updated is left as it was`); return 75; };
  let cookie = "", loops;
  try {
    const u = await fetch(`${O}/api/boss/auth/unlock`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ passcode: process.env.BOSS_PASSCODE ?? "" }), signal: AbortSignal.timeout(20000) });
    cookie = (u.headers.get("set-cookie") ?? "").split(";")[0];
    if (!u.ok || !cookie) return stop(`sign-in answered HTTP ${u.status}`);
    const r = await fetch(`${O}/api/boss/open-loops`, { headers: { cookie }, signal: AbortSignal.timeout(20000) });
    loops = (await r.json().catch(() => ({})))?.data?.loops;
    if (!r.ok || !Array.isArray(loops)) return stop(`the list answered HTTP ${r.status}`);
  } catch (e) { return stop(`could not reach Open Loops (${e?.cause?.code ?? e?.name ?? "error"})`); }
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
