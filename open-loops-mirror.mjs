// Open Loops mirror: reads Boss OS (the source of truth) and writes a calm read-only page.
// Prints CHANGED <file> when the content differs from the last publish, UNCHANGED otherwise.
// Run from ~/GitHub/boss-os: npm run -s vault:run -- node ~/bin/open-loops-mirror.mjs
// Publishing needs the claude.ai artifact tools, which only an interactive Claude session has (claude -p cannot, tested 5 Nov 2026).
// So: any session that changes Open Loops runs this, then publish_files to slug bff28f87-655d-4829-9bc1-ea23e70a2fac when it prints CHANGED.
import fs from "node:fs"; import crypto from "node:crypto"; import os from "node:os";
const DIR = `${os.homedir()}/.boss-os/runtime/open-loops-mirror`; fs.mkdirSync(DIR, { recursive: true });
const O = "https://boss.sequoiataylor.com";
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
const byId = Object.fromEntries(L.map((l) => [l.id, l]));
const row = (l) => {
  const who = WHO[l.owner] ?? l.owner; const wait = l.blocked_by && byId[l.blocked_by] ? `<span class="tag">waits on: ${esc(byId[l.blocked_by].title)}</span>` : "";
  return `<li class="${l.owner === "sequoia" ? "mine" : ""}"><details><summary><span class="t">${esc(l.title)}</span><span class="s">${esc(who)} · ${esc(BIZ[l.business] ?? l.business)}${l.next_date ? " · " + day(l.next_date) : ""}</span>${wait}</summary>
<p><b>Next:</b> ${esc(l.next_step ?? "")}</p><p><b>Done when:</b> ${esc(l.finish_line ?? "")}</p></details></li>`;
};
const active = L.filter((l) => l.section !== "parked").sort((a, b) => (a.next_date || "9").localeCompare(b.next_date || "9") || a.title.localeCompare(b.title));
const parked = L.filter((l) => l.section === "parked").sort((a, b) => a.title.localeCompare(b.title));
const overdue = active.filter((l) => l.next_date && l.next_date < today);
const groups = new Map();
for (const l of active.filter((l) => !(l.next_date && l.next_date < today))) { const k = l.next_date || "no date"; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(l); }
const yours = active.filter((l) => l.owner === "sequoia").length;
let body = `<p class="sum">${active.length} open · ${overdue.length} overdue · ${yours} yours · ${parked.length} parked</p>`;
if (overdue.length) body += `<h2 class="late">Overdue</h2><ul>${overdue.map(row).join("")}</ul>`;
for (const [k, rows] of groups) body += `<h2>${k === "no date" ? "No date" : day(k) + (k === today ? " · today" : "")} <small>${rows.length}</small></h2><ul>${rows.map(row).join("")}</ul>`;
body += `<details class="park"><summary><h2>Parked <small>${parked.length}</small> ▾</h2></summary><ul>${parked.map(row).join("")}</ul></details>`;
const content = body; const hash = crypto.createHash("sha256").update(content).digest("hex").slice(0, 16);
const stamp = new Date().toLocaleString("en-US", { timeZone: tz, weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
const html = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Open Loops</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@600&family=Karla:wght@400;600&family=IBM+Plex+Mono&display=swap">
<style>:root{--ground:#fdf8f4;--card:#fffcfa;--line:#ecdcd6;--ink:#3d2f33;--muted:#907e84;--gold:#c8a45c;--gold-deep:#a8842f;--red:#a83a3a;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--ground:#1b1517;--card:#241c1f;--line:#3a2e32;--ink:#f3e7df;--muted:#b9a7ad;--gold:#e0bd72;--gold-deep:#e0bd72;--red:#e08a8a;color-scheme:dark}}
body{margin:0;background:var(--ground);color:var(--ink);font:15px/1.55 Karla,system-ui,sans-serif}.wrap{max-width:560px;margin:0 auto;padding:28px 16px 60px}
h1{font:600 28px "Cormorant Garamond",Georgia,serif;margin:0}.sum{font:12px "IBM Plex Mono",monospace;letter-spacing:.06em;color:var(--muted);margin:4px 0 6px}
.meta{font-size:13px;color:var(--muted);margin:0 0 18px}.meta a{color:var(--gold-deep)}
h2{font:600 18px "Cormorant Garamond",Georgia,serif;margin:22px 0 6px;display:inline-block}h2 small{font:12px "IBM Plex Mono",monospace;color:var(--muted)}h2.late{color:var(--red)}
ul{list-style:none;margin:0;padding:0}li{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:6px 0}li.mine{border-left:3px solid var(--gold)}
summary{cursor:pointer;padding:11px 14px;min-height:44px;list-style:none;display:block}summary::-webkit-details-marker{display:none}
.t{display:block;font-weight:600;overflow-wrap:anywhere}.s{display:block;font-size:13px;color:var(--muted)}.tag{display:inline-block;font-size:12px;color:var(--gold-deep);margin-top:2px}
details p{margin:0 14px 10px;font-size:14px;overflow-wrap:anywhere}.park>summary{padding:0}.park>summary h2{margin-top:26px}</style></head>
<body><div class="wrap"><h1>Open Loops</h1>${body.replace(/^<p class="sum">/, '<p class="sum">')}
<p class="meta">A read-only copy, refreshed from Boss OS when the list changes. Last refresh ${esc(stamp)} CT. Gold edge = yours. <a href="https://boss.sequoiataylor.com/?tab=loops">Open the live list in Boss OS ›</a></p>
</div></body></html>`;
// Keep the meta line under the title for readers.
const page = html.replace(`<h1>Open Loops</h1>${body}`, `<h1>Open Loops</h1>${body.slice(0, body.indexOf("</p>") + 4)}<p class="meta">Read-only copy of Boss OS, refreshed when the list changes · last refresh ${esc(stamp)} CT · gold edge = yours · <a href="https://boss.sequoiataylor.com/?tab=loops">Open the live list ›</a></p>${body.slice(body.indexOf("</p>") + 4)}`).replace(/<p class="meta">A read-only copy[\s\S]*?<\/p>\n<\/div>/, "</div>");
fs.writeFileSync(`${DIR}/index.html`, page);
const last = fs.existsSync(`${DIR}/published.hash`) ? fs.readFileSync(`${DIR}/published.hash`, "utf8").trim() : "";
fs.writeFileSync(`${DIR}/pending.hash`, hash);
console.log(hash === last ? `UNCHANGED ${L.length} open` : `CHANGED ${DIR}/index.html (${L.length} open)`);
