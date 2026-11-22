#!/usr/bin/env node
// ship-ready-baseline: renders a repo's real output and fails on the automatic fails (row 18, 20 Nov 2026).
// Called by .github/workflows/ship-ready-baseline.yml (workflow_call) with the caller repo checked out.
// The caller's ship-ready.json says what to render:
//   { "kind": "site|app|web-app|email", "build": "<cmd>", "serve": "<dir, or a cmd that serves on base_url>",
//     "base_url": "http://127.0.0.1:4173" (cmd only), "pages": ["/", "/about"] (omitted: "/" + 7 from sitemap.xml),
//     "emails": { "cmd": "<writes rendered .html files>", "dir": "<that dir>" }, "words": ["extra banned word"],
//     "not_yet": "<why it cannot render in CI yet; pairs with a dated Open Loops row>",
//     "allow": { "<placeholder phrase true for this repo>": "<why>" },
//     "live_origin": "https://example.com" (the site's public origin: its own cross-origin APIs answer the
//       local render exactly as they answer that origin, so CORS is judged as production sees it),
//     "sign_in": { "cmd": "<signs in against $SHIP_READY_BASE_URL, writes a Playwright storageState to $SHIP_READY_STATE>",
//                  "signed_in": "<CSS selector only a signed-in screen has>" } }
// kind web-app is a console behind a sign-in: sign_in is required, every page renders with that session
// at 390 and 1280 px, and a page without the signed_in selector is a fail (it rendered the login screen).
// or a list of those (a site and an app in one repo).
// Each automatic fail is one plain line; ZERO pages rendered is a fail (rule 0). Writes <out>/baseline.json,
// one screenshot per page and viewport (plus a -dark one where the page has a dark mode), and a job summary. Exit 0 pass | 1 fails found | 2 bad config.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync, statSync, readdirSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:http";
import { join, extname, resolve } from "node:path";
import { spawn, execSync } from "node:child_process";
import { createRequire } from "node:module";
import { chromium } from "playwright";

const require = createRequire(import.meta.url);
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const CONFIG = arg("--config", "ship-ready.json");
const OUT = resolve(arg("--out", "ship-ready-out"));
const PAGE_SECS = Number(process.env.SHIP_READY_PAGE_SECS || 90);
const stop = (msg) => { console.error(`NAMED STOP [SHIP_READY_CONFIG] ${msg}`); process.exit(2); };

let cfg;
try { cfg = JSON.parse(readFileSync(CONFIG, "utf8")); } catch (e) { stop(`${CONFIG} could not be read: ${e.message}`); }
// Several outputs in one repo (a site and an app, several publications): a list, each judged in turn.
if (Array.isArray(cfg)) {
  if (!cfg.length) stop("an empty list renders nothing (rule 0)");
  let worst = 0;
  cfg.forEach((one, i) => {
    const file = resolve(`.ship-ready-${i}.json`); writeFileSync(file, JSON.stringify(one));
    try { execSync(`node "${new URL(import.meta.url).pathname}" --config "${file}" --out "${join(OUT, String(i))}"`, { stdio: "inherit" }); }
    catch (e) { worst = Math.max(worst, e.status || 1); }
  });
  process.exit(worst);
}
// A repo whose output cannot be rendered in CI yet says why; the job passes with that reason in its
// summary, and the reason is a dated Open Loops row (never a silent skip).
if (cfg.not_yet) {
  const why = `## ship-ready-baseline: NOT RUN YET (${cfg.kind || "?"}) — ${cfg.not_yet}`;
  console.log(why); console.log(`::warning title=ship-ready-baseline not run yet::${cfg.not_yet}`);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, why + "\n");
  console.log("OUTPUT NOT_YET"); process.exit(0);
}
const kind = cfg.kind;
if (!["site", "app", "web-app", "email"].includes(kind)) stop(`kind must be site, app, web-app or email (got ${kind})`);
const signIn = cfg.sign_in;
if (kind === "web-app" && !signIn) stop("kind web-app needs sign_in: { cmd, signed_in } (or not_yet with its reason)");
if (signIn && (typeof signIn.cmd !== "string" || !signIn.cmd.trim() || typeof signIn.signed_in !== "string" || !signIn.signed_in.trim()))
  stop("sign_in needs cmd (writes $SHIP_READY_STATE) and signed_in (a selector only a signed-in screen has)");
mkdirSync(join(OUT, "shots"), { recursive: true });

// The shared word list: words that read as machine-written, plus emoji and sparkle glyphs (from PBS phase 1).
const shared = JSON.parse(readFileSync(new URL("./words.json", import.meta.url), "utf8"));
const wordRe = new RegExp(`(?<![\\p{L}\\p{N}])(?:${[...shared.words, ...(cfg.words || [])].join("|")})(?![\\p{L}\\p{N}])`, "iu");
const glyphRe = /\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F|[✦✧]/u; // emoji and sparkles; ©, ® and ™ are text
// Code words are matched in their own case ("todo" is Spanish for "all"); phrases in any case.
const placeholderRe = /[Ll]orem ipsum|\bTODO\b|\bTBD\b|[Cc]oming [Ss]oon|COMING SOON|\{\{|\}\}|\bundefined\b|\bNaN\b|\[object Object\]/;
// A repo may allow a phrase that is true for it, with the reason: { "allow": { "coming soon": "the app is not in the stores yet" } }.
const allowed = Object.keys(cfg.allow || {}).map((k) => k.toLowerCase());
// A page that calls its own API on another host (api.example.com) is refused by CORS on 127.0.0.1, which is
// the render's address, not a fault in the page. With live_origin, each cross-origin fetch/XHR is sent as
// that origin and the answer's Access-Control-Allow-Origin is honoured only if it names live_origin
// (rewritten to the local address); an API that would refuse the real site still fails here.
const LIVE = cfg.live_origin;
if (LIVE !== undefined && (typeof LIVE !== "string" || !/^https:\/\/[a-z0-9.-]+(?::\d+)?$/i.test(LIVE))) stop(`live_origin must be an https origin such as https://example.com (got ${JSON.stringify(LIVE)})`);
for (const [k, why] of Object.entries(cfg.allow || {})) if (!String(why).trim()) stop(`allow "${k}" needs its reason`);

const run = (cmd) => { console.log(`$ ${cmd}`); execSync(cmd, { stdio: "inherit", shell: "/bin/bash" }); };
if (cfg.build) run(cfg.build);

// Serving: a directory is served here (x -> x.html or x/index.html, unknown -> 404.html with status 404,
// as Cloudflare Pages and Workers assets do); a command is started and waited for on base_url.
const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript",
  ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".webp": "image/webp", ".gif": "image/gif", ".avif": "image/avif", ".ico": "image/x-icon", ".woff2": "font/woff2",
  ".woff": "font/woff", ".txt": "text/plain", ".xml": "application/xml", ".mp4": "video/mp4", ".wasm": "application/wasm", ".map": "application/json", ".webmanifest": "application/manifest+json" };
async function serveDir(dir) {
  const root = resolve(dir);
  if (!existsSync(root)) stop(`serve directory ${dir} does not exist`);
  const isFile = (p) => existsSync(p) && statSync(p).isFile();
  const server = createServer((req, res) => {
    const url = decodeURIComponent(new URL(req.url, "http://x").pathname);
    // Server code (Pages Functions, a Worker's /api) does not run in a static serve: answer empty, not 404.
    if (/^\/(api|cdn-cgi)\//.test(url)) { res.writeHead(204).end(); return; }
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
  const context = await browser.newContext({ viewport, ...(opts.state ? { storageState: opts.state } : {}) });
  if (LIVE && origin) await context.route((u) => u.origin !== origin && /^https?:$/.test(u.protocol), async (r) => {
    if (!["fetch", "xhr", "eventsource"].includes(r.request().resourceType())) return r.fallback();
    let resp;
    try { resp = await r.fetch({ headers: { ...r.request().headers(), origin: LIVE } }); } catch { return r.abort("failed"); }
    const headers = resp.headers();
    if (headers["access-control-allow-origin"] === LIVE) headers["access-control-allow-origin"] = origin;
    return r.fulfill({ response: resp, headers });
  });
  // Third-party analytics cannot answer a localhost origin (CORS); they are not the page's own errors.
  await context.route(/(cloudflareinsights\.com|clarity\.ms|googletagmanager\.com|google-analytics\.com|plausible\.io|connect\.facebook\.net)/, (r) => r.fulfill({ status: 204, body: "" }));
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
  // A signed-in render that shows the login screen has judged nothing: a fail by name, never a pass.
  // Any visible match counts: a console often has one nav for phones and another for desktops.
  if (opts.signedIn && !(await page.locator(opts.signedIn).locator("visible=true").count().catch(() => 0)))
    fail(row, `${target.label} did not render signed in (no ${opts.signedIn} on screen)`);
  const shot = `${target.label.replace(/[^a-z0-9]+/gi, "_").replace(/^_|_$/g, "") || "home"}-${viewport.width}.png`;
  const light = await page.screenshot({ path: join(OUT, "shots", shot), fullPage: true }).then(() => true, () => false);
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
    // Text drawn by CSS (a ::before table label, an ::after tag) has no text node to walk.
    // Only letters and digits count, so an arrow or icon glyph is never "text".
    for (const el of document.body.querySelectorAll("*")) {
      if (!vis(el) || el.closest("[aria-hidden=true], .sr-only, .visually-hidden")) continue;
      for (const pseudo of []) {
        const s = getComputedStyle(el, pseudo);
        if (s.display === "none" || s.visibility === "hidden" || !s.content || s.content === "none" || s.content === "normal") continue;
        const text = s.content.replace(/attr\(\s*([\w-]+)\s*\)/g, (_, n) => el.getAttribute(n) || "").replace(/["']/g, "").trim();
        const px = parseFloat(s.fontSize);
        if (/[\p{L}\p{N}]/u.test(text) && px < 12) small.push(`${px}px "${text.slice(0, 40)}"`);
      }
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
  const ph = [...facts.text.matchAll(new RegExp(placeholderRe, "g"))].map((m) => m[0]).find((m) => !allowed.includes(m.toLowerCase()));
  if (ph) fail(row, `${target.label} shows placeholder text: "${ph}"`);
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
  // Dark mode (prefers-color-scheme: dark), after the light checks so they judge the untouched page. It is
  // read from computed colours, not screenshot bytes (an animation is not a dark mode): first by media query
  // alone, then after a reload for a site that picks its theme in script at load. "none" means the page does
  // not follow prefers-color-scheme (a toggle-only dark theme also reads "none"); "not read" means it could not
  // be judged in the page's time budget. Informational: never a fail.
  row.dark = "not read";
  const budget = () => Date.now() - t0 < (PAGE_SECS - 20) * 1000;
  const colours = () => page.evaluate(() => ["html", "body", "h1, h2", "main, header, nav"].map((q) => { const el = document.querySelector(q); if (!el) return ""; const c = getComputedStyle(el); return `${c.backgroundColor}|${c.color}`; }).join(";"));
  if (light && budget()) {
    try {
      const before = await colours();
      await page.emulateMedia({ colorScheme: "dark" });
      let after = await colours();
      if (after === before && budget()) { await page.reload({ waitUntil: "load", timeout: 10000 }); after = await colours(); }
      if (after !== before) {
        const d = shot.replace(/\.png$/, "-dark.png");
        await page.screenshot({ path: join(OUT, "shots", d), fullPage: true, animations: "disabled" });
        row.dark = `shots/${d}`;
      } else if (budget()) row.dark = "none";
    } catch { row.dark = "not read"; }
    T("dark");
  }
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
  // No pages listed: the home page plus a spread of up to 7 from the site's own sitemap.xml.
  let pages = cfg.pages;
  if (!pages) {
    pages = ["/"];
    const xml = await fetch(`${srv.url}/sitemap.xml`).then((r) => (r.ok ? r.text() : "")).catch(() => "");
    const locs = [...new Set([...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => { try { return new URL(m[1]).pathname; } catch { return ""; } }).filter((p) => p && p !== "/" && !p.endsWith(".xml")))];
    const step = Math.max(1, Math.floor(locs.length / 7));
    for (let i = 0; i < locs.length && pages.length < 8; i += step) pages.push(locs[i]);
  }
  for (const p of pages) targets.push({ label: p, url: `${srv.url}${p}` });
}
const viewports = kind === "site" || kind === "web-app" ? [{ width: 390, height: 844 }, { width: 1280, height: 800 }] : [{ width: 390, height: 844 }];
// Signing in: the repo's own command, run against the server just started, writes the session.
let state;
const signInFails = [];
if (signIn) {
  // Outside OUT: the session is never part of the uploaded artifact.
  state = join(mkdtempSync(join(tmpdir(), "ship-ready-")), "session.json");
  try { execSync(signIn.cmd, { stdio: "inherit", shell: "/bin/bash", env: { ...process.env, SHIP_READY_BASE_URL: srv.url, SHIP_READY_STATE: state } }); }
  catch (e) { signInFails.push(`the sign-in command failed (exit ${e.status ?? "?"}): ${signIn.cmd}`); }
  let ok = false;
  try { const st = JSON.parse(readFileSync(state, "utf8")); ok = (st.cookies?.length || 0) + (st.origins?.length || 0) > 0; } catch {}
  if (!signInFails.length && !ok) signInFails.push(`the sign-in command wrote no session to $SHIP_READY_STATE: ${signIn.cmd}`);
  if (signInFails.length) targets.length = 0; // nothing signed out is judged as if it were the app
}
const browser = await chromium.launch();
const linkSet = new Set();
for (const t of targets) for (const vp of viewports) {
  const t0 = Date.now();
  // A page that has not finished in PAGE_SECS is a fail by name, never a hung job.
  const row = await Promise.race([
    judge(browser, srv.url, t, vp, { site: kind === "site", state, signedIn: signIn?.signed_in }),
    new Promise((r) => setTimeout(() => { const x = { page: t.label, viewport: `${vp.width}x${vp.height}`, fails: [`${t.label} did not finish rendering at ${vp.width} px within ${PAGE_SECS} s`] }; results.push(x); r(x); }, PAGE_SECS * 1000)),
  ]);
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
const lines = [...signInFails, ...new Set(results.flatMap((r) => r.fails))];
if (rendered === 0) lines.unshift("ZERO pages rendered: list pages (or emails) in ship-ready.json that this check can open");
writeFileSync(join(OUT, "baseline.json"), JSON.stringify({ kind, rendered, pass: lines.length === 0, pages: results.map(({ links, ...r }) => r) }, null, 2));
const summary = [`## ship-ready-baseline: ${lines.length ? "FAIL" : "PASS"} (${rendered} page renders)`, ...lines.map((l) => `- ${l}`)].join("\n");
console.log(summary);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary + "\n");
console.log(`OUTPUT ${lines.length ? "FAIL" : "PASS"} rendered=${rendered} fails=${lines.length}`);
process.exit(lines.length ? 1 : 0);
