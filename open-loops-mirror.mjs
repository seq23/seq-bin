// Open Loops mirror: reads Boss OS (the source of truth) and writes a plain, low-fidelity read-only page.
// Prints CHANGED <file> when the page content differs from the last run, UNCHANGED otherwise.
// Run from ~/GitHub/boss-os: npm run -s vault:run -- node ~/bin/open-loops-mirror.mjs
// Publishing needs the claude.ai Artifact tool, which only an interactive Claude session has (claude -p cannot, 5 Nov 2026):
// on CHANGED, the session publishes <dir>/index.html to https://claude.ai/artifact/QhkCPRzzuNm9Kd1ystTuDd. That is the whole job.
//
// Layout (her words 28 Nov 2026: "it looks stupid it needs reformatting … it needs to be easy and low fidelity"):
//   summary + jump links → "Yours" (🟡 waiting on your yes, 🔴 only you can do it) → Overdue → Open, by date →
//   "Parked, no date" → "Landed, not yet proven" (one short line each, grouped by check date). Every list is a
//   plain open list (her 28 Nov ruling: both lists are lists, never folded shut); rows are one or two lines, no cards.
// Env (tests): OPEN_LOOPS_MIRROR_DIR, BOSS_ORIGIN.
import fs from "node:fs"; import crypto from "node:crypto"; import os from "node:os";
const DIR = process.env.OPEN_LOOPS_MIRROR_DIR || `${os.homedir()}/.boss-os/open-loops-mirror`; fs.mkdirSync(DIR, { recursive: true });
const O = process.env.BOSS_ORIGIN || "https://boss.sequoiataylor.com";
const u = await fetch(`${O}/api/boss/auth/unlock`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ passcode: process.env.BOSS_PASSCODE }) });
const cookie = (u.headers.get("set-cookie") ?? "").split(";")[0];
const r = await fetch(`${O}/api/boss/open-loops`, { headers: { cookie } });
const j = await r.json().catch(() => ({}));
const all = j?.data?.loops;
if (!r.ok || !Array.isArray(all) || all.length === 0) { console.log(`NAMED STOP [LOOPS_UNREADABLE] HTTP ${r.status}`); process.exit(2); }
const L = all.filter((l) => l.status === "open");
const tz = "America/Chicago";
const today = new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(new Date());
const BIZ = { brokerage: "Spry Ventures", "west-peek-ventures": "West Peek Ventures", "west-peek": "West Peek", "porch-and-party": "Porch & Party", "time-2-read": "Time-2-Read", spry: "Spry Labs", friends: "Friends", personal: "Boss OS" };
const WHO = { sequoia: "You", claude: "Claude", codex: "Codex" };
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const day = (d) => new Date(d + "T12:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
const biz = (l) => BIZ[l.business] ?? l.business ?? "";
const prWords = (p) => { const m = /^[^/]+\/([^#]+)#(\d+)$/.exec(String(p ?? "")); return m ? `${m[1]} #${m[2]}` : "no PR named"; };
// 🟡 = a decision waiting on her yes; 🔴 = a task only she can do (sign-in, payment, a call). Display only; nothing acts on it.
const isYes = (l) => /\b(decide|decision|your yes|her yes|yes\/no|yes or no|go or no-go|go\/no-go|she decides|you decide)\b/i.test(`${l.title} ${l.next_step ?? ""}`);
const mark = (l) => (l.owner === "sequoia" ? (isYes(l) ? "🟡 " : "🔴 ") : "");

const line = (l, { date = true, who = true } = {}) => {
  const meta = [who ? WHO[l.owner] ?? l.owner : "", biz(l), date && l.next_date ? day(l.next_date) : ""].filter(Boolean).join(" · ");
  const next = l.next_step ? `<span class="n">${esc(l.next_step)}</span>` : "";
  return `<li><span class="t">${mark(l)}${esc(l.title)}</span><span class="m">${esc(meta)}</span>${next}</li>`;
};
const proofLine = (l) => `<li class="p"><span class="t">${esc(l.title)}</span><span class="m">${esc(prWords(l.proof_pr))}</span></li>`;

const byDate = (a, b) => (a.next_date || "9").localeCompare(b.next_date || "9") || a.title.localeCompare(b.title);
const active = L.filter((l) => l.section === "not_finished").sort(byDate);
const parked = L.filter((l) => l.section === "parked").sort((a, b) => a.title.localeCompare(b.title));
const proving = L.filter((l) => l.section === "proving").sort(byDate);
const yours = active.filter((l) => l.owner === "sequoia");
const others = active.filter((l) => l.owner !== "sequoia");
const overdue = others.filter((l) => l.next_date && l.next_date < today);
const upcoming = others.filter((l) => !(l.next_date && l.next_date < today));
const group = (rows, key) => { const g = new Map(); for (const l of rows) { const k = key(l); if (!g.has(k)) g.set(k, []); g.get(k).push(l); } return g; };
const yesN = yours.filter(isYes).length;
const lateN = active.filter((l) => l.next_date && l.next_date < today).length;

let body = `<p class="sum">${active.length} open · ${lateN} overdue · ${yours.length} yours (🟡 ${yesN} your yes · 🔴 ${yours.length - yesN} only you) · ${proving.length} landed, not yet proven · ${parked.length} parked</p>`;
body += `<nav><a href="#yours">Yours ${yours.length}</a><a href="#open">Open ${others.length}</a><a href="#parked">Parked ${parked.length}</a><a href="#proving">Not yet proven ${proving.length}</a></nav>`;
body += `<h2 id="yours">Yours <small>${yours.length}</small></h2><p class="key">🟡 waiting on your yes · 🔴 only you can do it</p><ul>${[...yours.filter(isYes), ...yours.filter((l) => !isYes(l))].map((l) => line(l, { who: false })).join("") || '<li class="none">Nothing waiting on you.</li>'}</ul>`;
body += `<h2 id="open">Open <small>${others.length}</small></h2>`;
if (overdue.length) body += `<h3 class="late">Overdue <small>${overdue.length}</small></h3><ul>${overdue.map((l) => line(l)).join("")}</ul>`;
for (const [k, rows] of group(upcoming, (l) => l.next_date || "no date")) body += `<h3>${k === "no date" ? "No date" : day(k) + (k === today ? " · today" : "")} <small>${rows.length}</small></h3><ul>${rows.map((l) => line(l, { date: false })).join("")}</ul>`;
if (!others.length) body += `<ul><li class="none">Nothing open.</li></ul>`;
body += `<h2 id="parked">Parked, no date <small>${parked.length}</small></h2><ul>${parked.map((l) => line(l, { date: false })).join("") || '<li class="none">Nothing parked.</li>'}</ul>`;
body += `<h2 id="proving">Landed, not yet proven <small>${proving.length}</small></h2><p class="key">Each landed; its next-day live check closes it, or brings it back as NOT WORKING.</p>`;
if (proving.length) for (const [k, rows] of group(proving, (l) => l.next_date || "no date")) body += `<h3>${k === "no date" ? "Check date not set" : "Check " + day(k)} <small>${rows.length}</small></h3><ul>${rows.map(proofLine).join("")}</ul>`;
else body += `<ul><li class="none">Nothing waiting on a live check.</li></ul>`;

const hash = crypto.createHash("sha256").update(body).digest("hex").slice(0, 16);
const stamp = new Date().toLocaleString("en-US", { timeZone: tz, weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
// Assembled by concatenation only: never String.replace with row text (a "$'" in a check command once copied half the page into itself).
const page = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Open Loops</title>
<style>:root{--bg:#fbfaf8;--ink:#2b2b2b;--muted:#77716d;--line:#e6e1dc;--late:#a83a3a;--link:#7a5a1e;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#181616;--ink:#ece7e2;--muted:#a9a19b;--line:#332e2c;--late:#e48a8a;--link:#e0bd72;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#181616;--ink:#ece7e2;--muted:#a9a19b;--line:#332e2c;--late:#e48a8a;--link:#e0bd72;color-scheme:dark}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
.wrap{max-width:680px;margin:0 auto;padding:24px 16px 64px}h1{font-size:24px;margin:0 0 4px}
.sum,.meta,.key{color:var(--muted);font-size:13px;margin:2px 0 8px}.meta a,nav a{color:var(--link)}
nav{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:14px;margin:8px 0 4px;position:sticky;top:0;background:var(--bg);padding:8px 0;border-bottom:1px solid var(--line)}
h2{font-size:18px;margin:28px 0 2px;scroll-margin-top:48px}h3{font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:16px 0 2px}
h3.late{color:var(--late)}small{font-weight:400;color:var(--muted)}
ul{list-style:none;margin:0;padding:0}li{padding:7px 0;border-bottom:1px solid var(--line);overflow-wrap:anywhere}
.t{font-weight:600}.m{color:var(--muted);font-size:13px;margin-left:8px}.n{display:block;color:var(--muted);font-size:13px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
li.p{padding:4px 0}li.p .t{font-weight:400;font-size:14px}li.none{color:var(--muted)}</style></head>
<body><div class="wrap"><h1>Open Loops</h1>${body}
<p class="meta">Read-only copy of Boss OS, refreshed when the list changes · last refresh ${esc(stamp)} CT · <a href="https://boss.sequoiataylor.com/?tab=loops">Open the live list ›</a></p></div></body></html>`;
fs.writeFileSync(`${DIR}/index.html`, page);
const last = fs.existsSync(`${DIR}/last.hash`) ? fs.readFileSync(`${DIR}/last.hash`, "utf8").trim() : "";
fs.writeFileSync(`${DIR}/last.hash`, hash);
console.log(hash === last ? `UNCHANGED ${L.length} open` : `CHANGED ${DIR}/index.html (${L.length} open)`);
