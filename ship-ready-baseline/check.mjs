#!/usr/bin/env node
// ship-ready-baseline: renders a repo's real output and fails on the automatic fails (row 18, 20 Nov 2026).
// Called by .github/workflows/ship-ready-baseline.yml (workflow_call) with the caller repo checked out.
// The caller's ship-ready.json says what to render:
//   { "kind": "site|app|email", "build": "<cmd>", "serve": "<dir, or a cmd that serves on base_url>",
//     "base_url": "http://127.0.0.1:4173" (cmd only), "pages": ["/", "/about"],
//     "emails": { "cmd": "<writes rendered .html files>", "dir": "<that dir>" }, "words": ["extra banned word"] }
// Each automatic fail is one plain line; ZERO pages rendered is a fail (rule 0). Writes <out>/baseline.json,
// one screenshot per page and viewport, and a job summary. Exit 0 pass | 1 fails found | 2 bad config.
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, readdirSync, appendFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, extname, resolve } from "node:path";
import { spawn, execSync } from "node:child_process";
import { createRequire } from "node:module";
import { chromium } from "playwright";

const require = createRequire(import.meta.url);
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const CONFIG = arg("--config", "ship-ready.json");
const OUT = resolve(arg("--out", "ship-ready-out"));
const stop = (msg) => { console.error(`NAMED STOP [SHIP_READY_CONFIG] ${msg}`); process.exit(2); };

let cfg;
try { cfg = JSON.parse(readFileSync(CONFIG, "utf8")); } catch (e) { stop(`${CONFIG} could not be read: ${e.message}`); }
const kind = cfg.kind;
if (!["site", "app", "email"].includes(kind)) stop(`kind must be site, app or email (got ${kind})`);
mkdirSync(join(OUT, "shots"), { recursive: true });

// The shared word list: words that read as machine-written, plus emoji and sparkle glyphs (from PBS phase 1).
const shared = JSON.parse(readFileSync(new URL("./words.json", import.meta.url), "utf8"));
const wordRe = new RegExp(`(?<![\\p{L}\\p{N}])(?:${[...shared.words, ...(cfg.words || [])].join("|")})(?![\\p{L}\\p{N}])`, "iu");
const glyphRe = /\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F|[✦✧]/u; // emoji and sparkles; ©, ® and ™ are text
const placeholderRe = /lorem ipsum|\bTODO\b|\bTBD\b|coming soon|\{\{|\}\}|\bundefined\b|\bNaN\b|\[object Object\]/i;

const run = (cmd) => { console.log(`$ ${cmd}`); execSync(cmd, { stdio: "inherit", shell: "/bin/bash" }); };
if (cfg.build) run(cfg.build);

// Serving: a directory is served here (x -> x.html or x/index.html, unknown -> 404.html with status 404,
// as Cloudflare Pages and Workers assets do); a command is started and waited for on base_url.
const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript",
  ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".webp": "image/webp", ".gif": "image/gif", ".avif": "image/avif", ".ico": "image/x-icon", ".woff2": "font/woff2",
  ".woff": "font/woff", ".txt": "text/plain", ".xml": "application/xml", ".mp4": "video/mp4", ".webmanifest": "application/manifest+json" };
async function serveDir(dir) {
  const root = resolve(dir);
  if (!existsSync(root)) stop(`serve directory ${dir} does not exist`);
  const isFile = (p) => existsSync(p) && statSync(p).isFile();
  const server = createServer((req, res) => {
    const url = decodeURIComponent(new URL(req.url, "http://x").pathname);
    const base = join(root, url);
    if (!base.startsWith(root)) { res.writeHead(403).end(); return; }
    const hit = [base, `${base}.html`, join(base, "index.html")].find(isFile);
    if (hit) { res.writeHead(200, { "content-type": TYPES[extname(hit)] || "application/octet-stream" }); res.end(readFileSync(hit)); return; }
    const nf = join(root, "404.html");
    res.writeHead(404, { "content-type": "text/html; charset=utf-8" });
    res.end(isFile(nf) ? readFileSync(nf) : "<html><head><title>404 Not Found</title></head><body>Not Found</body></html>");
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}
async function serveCmd(cmd, url) {
  if (!url) stop("serve is a command, so base_url is required");
  console.log(`$ ${cmd} &`);
  const child = spawn("/bin/bash", ["-c", cmd], { stdio: "inherit", detached: true });
  for (let i = 0; i < 120; i++) {
    try { const r = await fetch(url); if (r.status < 500) return { url: url.replace(/\/$/, ""), close: () => { try { process.kill(-child.pid); } catch {} } }; } catch {}
    await new Promise((r) => setTimeout(r, 1000));
  }
  try { process.kill(-child.pid); } catch {}
  stop(`${cmd} did not answer on ${url} within 120 s`);
}

const results = []; // { page, viewport, fails: [] }
const fail = (row, line) => row.fails.push(line);
const axeSource = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");

async function judge(browser, origin, target, viewport, opts) {
  const row = { page: target.label, viewport: `${viewport.width}x${viewport.height}`, fails: [] };
  const t0 = Date.now(); const T = (s) => process.env.SRB_DEBUG && console.log(`    ${s} ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  results.push(row);
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  const consoleErrors = []; const badResponses = [];
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });
  page.on("pageerror", (e) => consoleErrors.push(e.message));
  page.on("response", (r) => { if (r.status() >= 400 && origin && r.url().startsWith(origin) && r.url() !== target.url) badResponses.push(`${r.status()} ${r.url().slice(origin.length)}`); });
  let resp;
  try { resp = await page.goto(target.url, { waitUntil: "domcontentloaded", timeout: 30000 }); } catch (e) { fail(row, `${target.label} did not load: ${e.message.split("\n")[0]}`); await context.close(); return row; }
  if (resp && resp.status() >= 400 && !opts.expect404) fail(row, `${target.label} answered ${resp.status()}`);
  T("loaded");
  // Lazy images and late requests: scroll to the foot, then settle.
  await page.evaluate(async () => { for (let y = 0; y < document.body.scrollHeight; y += 600) { window.scrollTo(0, y); await new Promise((r) => setTimeout(r, 30)); } window.scrollTo(0, 0); });
  await page.waitForLoadState("load", { timeout: 8000 }).catch(() => {});
  await page.waitForLoadState("networkidle", { timeout: 4000 }).catch(() => {});
  T("settled");
  const shot = `${target.label.replace(/[^a-z0-9]+/gi, "_").replace(/^_|_$/g, "") || "home"}-${viewport.width}.png`;
  await page.screenshot({ path: join(OUT, "shots", shot), fullPage: true }).catch(() => {});
  row.shot = `shots/${shot}`; T("shot");
  const facts = await page.evaluate(() => {
    const vis = (el) => { const s = getComputedStyle(el); const r = el.getBoundingClientRect(); return s.visibility !== "hidden" && s.display !== "none" && r.width > 0 && r.height > 0; };
    const small = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const t = walker.currentNode; const el = t.parentElement;
      if (!el || !t.textContent.trim() || !vis(el) || el.closest("[aria-hidden=true], .sr-only, .visually-hidden")) continue;
      const px = parseFloat(getComputedStyle(el).fontSize);
      if (px < 12) small.push(`${px}px "${t.textContent.trim().slice(0, 40)}"`);
    }
    const brokenImgs = [...document.images].filter((i) => i.complete && i.naturalWidth === 0 && i.getAttribute("src")).map((i) => i.getAttribute("src"));
    const links = [...document.querySelectorAll("a[href]")].map((a) => a.href).filter((h) => h.startsWith(location.origin));
    const meta = (sel) => document.querySelector(sel)?.getAttribute("content")?.trim() || "";
    return {
      text: document.body.innerText,
      overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      small, brokenImgs, links: [...new Set(links.map((h) => h.split("#")[0]))],
      title: document.title.trim(), description: meta('meta[name="description"]'), ogImage: meta('meta[property="og:image"]'),
    };
  });
  if (viewport.width <= 400 && facts.overflow > 1) fail(row, `${target.label} scrolls sideways at ${viewport.width} px (${facts.overflow} px too wide)`);
  for (const r of new Set(badResponses)) fail(row, `${target.label} asks for an asset that fails: ${r}`);
  for (const src of facts.brokenImgs) fail(row, `${target.label} has a broken image: ${src}`);
  for (const e of [...new Set(consoleErrors)].slice(0, 5)) fail(row, `${target.label} logs a console error: ${e.slice(0, 160)}`);
  const ph = facts.text.match(placeholderRe); if (ph) fail(row, `${target.label} shows placeholder text: "${ph[0]}"`);
  const w = facts.text.match(wordRe); if (w) fail(row, `${target.label} uses a banned word: "${w[0]}"`);
  const g = facts.text.match(glyphRe); if (g) fail(row, `${target.label} shows an emoji or sparkle: ${g[0]}`);
  if (facts.small.length) fail(row, `${target.label} has text under 12 px: ${facts.small.slice(0, 3).join(", ")}`);
  if (opts.site) {
    if (!facts.title) fail(row, `${target.label} has no <title>`);
    if (!facts.description) fail(row, `${target.label} has no meta description`);
    if (!facts.ogImage) fail(row, `${target.label} has no og:image`);
  }
  T("facts");
  await page.addScriptTag({ content: axeSource });
  const axe = await page.evaluate(async () => (await window.axe.run(document, { runOnly: { type: "rule", values: ["color-contrast"] } })).violations);
  for (const v of axe) for (const n of v.nodes.slice(0, 3)) fail(row, `${target.label} has text below 4.5:1 contrast: ${n.target.join(" ")}`);
  T("axe");
  row.links = facts.links;
  await context.close();
  return row;
}

let srv;
const targets = [];
if (kind === "email") {
  const em = cfg.emails || {};
  if (em.cmd) run(em.cmd);
  if (!em.dir || !existsSync(em.dir)) stop("kind email needs emails.dir, written by emails.cmd");
  srv = await serveDir(em.dir);
  for (const f of readdirSync(em.dir).filter((f) => f.endsWith(".html")).sort()) targets.push({ label: f, url: `${srv.url}/${f}` });
} else {
  srv = typeof cfg.serve === "string" && existsSync(cfg.serve) && statSync(cfg.serve).isDirectory() ? await serveDir(cfg.serve) : await serveCmd(cfg.serve, cfg.base_url);
  for (const p of cfg.pages || []) targets.push({ label: p, url: `${srv.url}${p}` });
}
const viewports = kind === "site" ? [{ width: 390, height: 844 }, { width: 1280, height: 800 }] : [{ width: 390, height: 844 }];
const browser = await chromium.launch();
const linkSet = new Set();
for (const t of targets) for (const vp of viewports) {
  const t0 = Date.now();
  const row = await judge(browser, srv.url, t, vp, { site: kind === "site" });
  console.log(`  ${t.label} @${vp.width}: ${row.fails.length} fail(s), ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  for (const f of row.fails) console.log(`    - ${f}`);
  for (const l of row.links || []) linkSet.add(l);
}
if (kind === "site" && targets.length) {
  // The 404 page: an unknown address must answer 404 with the site's own page, never a server default.
  const row = { page: "404", viewport: "-", fails: [] }; results.push(row);
  const r = await fetch(`${srv.url}/ship-ready-baseline-no-such-page`);
  const body = await r.text();
  if (r.status !== 404) fail(row, `an unknown address answers ${r.status}, not 404`);
  if (/<title>\s*404 Not Found\s*<\/title>/i.test(body) || body.trim().length < 200) fail(row, "the 404 page is a server default, not the site's own page");
  // Internal links from the listed pages.
  for (const l of linkSet) {
    const s = await fetch(l, { redirect: "follow" }).then((x) => x.status).catch(() => 0);
    if (s >= 400 || s === 0) fail(row, `a link on the listed pages is broken: ${l.slice(srv.url.length) || "/"} (${s || "no answer"})`);
  }
}
await browser.close(); srv.close();

const rendered = results.filter((r) => r.shot).length;
const lines = results.flatMap((r) => r.fails);
if (rendered === 0) lines.unshift("ZERO pages rendered: list pages (or emails) in ship-ready.json that this check can open");
writeFileSync(join(OUT, "baseline.json"), JSON.stringify({ kind, rendered, pass: lines.length === 0, pages: results.map(({ links, ...r }) => r) }, null, 2));
const summary = [`## ship-ready-baseline: ${lines.length ? "FAIL" : "PASS"} (${rendered} page renders)`, ...lines.map((l) => `- ${l}`)].join("\n");
console.log(summary);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary + "\n");
console.log(`OUTPUT ${lines.length ? "FAIL" : "PASS"} rendered=${rendered} fails=${lines.length}`);
process.exit(lines.length ? 1 : 0);
