#!/usr/bin/env node
// token-report — which Claude jobs burned the most tokens, and why (28 Nov 2026, her yes to the token cuts:
// "Count the cost of every job … which jobs used the most tokens that day, and why").
//
// It reads the usage records Claude Code already leaves on this Mac (~/.claude/projects/*/*.jsonl, and each
// session's subagents/agent-*.jsonl with its .meta.json), streaming them line by line. Per session and per
// subagent run: total tokens (input + cache read + cache write + output, each API call once), API calls, tool
// calls, and the top 3 causes, measured by the tool results that entered its context: how many tokens each
// kind of result brought in, and how many it CARRIED (that size times every later call that re-read it, up to
// the next compaction). Boss OS's own model ledger (/api/boss/system/cost) is read too, through the vault.
//
//   token-report [--days N]            last N days (default 1); a short table, and JSON in ~/Work/tasks/measure/
//   token-report --days 7 --out FILE   e.g. the baseline
//   token-report --compare BASE.json [--current CUR.json]
//        builder, reviewer and helper tokens per finished run, this week (or CUR) against BASE; writes the
//        verdict line to ~/Work/tasks/measure/tokens-compare.txt: WORKING (a drop of a third or more),
//        NOT WORKING, or NOT CHECKED (too few finished runs to say)
//   token-report --nightly             launchd 23:30 CT: the Mac's window (mac-window check ANY), yesterday's
//        report, the week against the baseline (tokens-compare.txt, read by this PR's outcome check), and
//        daily files past 60 days removed (the baseline and week files are kept)
//   --root DIR (default ~/.claude/projects)  --min-rows N (default 1)  --no-boss (Boss OS reads "not read: switched off")
//
// PRIVATE BY DESIGN: it prints and writes only counts, tool names, agent types, repo names and short task
// descriptions (a subagent's own description, a session's title), with anything shaped like an email address or
// a key replaced. Never message text, commands, file contents or tool output. Everything stays on this Mac.
//
// Exit: 0 written · 1 compare NOT WORKING · 3 NAMED STOP [NO_TRANSCRIPTS] nothing in the window ·
// 4 NAMED STOP [UNREADABLE_FORMAT] transcripts found but no usage record could be read · 5 NAMED STOP
// [TOO_FEW_ROWS] · 6 compare NOT CHECKED · 64 usage. The last line is always `OUTPUT token-report …`.
import { createReadStream, mkdirSync, readFileSync, readdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { join, basename, dirname } from "node:path";
import { homedir } from "node:os";
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const HOME = homedir();
export const MEASURE = process.env.TOKEN_REPORT_DIR || join(HOME, "Work/tasks/measure");
const IMAGE_TOKENS = 1600; // one screenshot at the API's largest size (~1.15 megapixels / 750)
export const ROLES = ["builder", "reviewer", "helper"];

// ---------- privacy: the only free text that leaves a transcript ----------
export function clean(s, max = 70) {
  if (typeof s !== "string") return "";
  return s
    .replace(/[\w.%+-]+@[\w-]+(?:\.[\w-]+)+/g, "[email]")
    .replace(/\b(?:sk-[\w-]{8,}|gh[opsu]_[A-Za-z0-9]{8,}|github_pat_\w{8,}|xox[abp]-[\w-]{8,}|AKIA[A-Z0-9]{8,}|AIza[\w-]{8,}|eyJ[\w-]{10,}\.[\w-]+\.?[\w-]*)/g, "[secret]")
    .replace(/\b(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{32,}\b/g, "[secret]")
    .replace(/\s+/g, " ").trim().slice(0, max);
}

// ---------- what kind of tool result entered the context ----------
export function category(name, input) {
  if (!name) return "other";
  if (name === "Bash") {
    const c = String(input?.command ?? "");
    if (/(^|[;&|(]\s*|\bcd [^;&]+&&\s*)gh\s/.test(c) || /^\s*gh\s/.test(c)) return "gh";
    return "Bash";
  }
  if (name.startsWith("mcp__claude-in-chrome__")) return "browser (Chrome)";
  if (name === "Agent" || name === "Task") return "subagent reports";
  if (name === "Grep" || name === "Glob") return "search";
  if (name === "WebFetch" || name === "WebSearch") return "web";
  if (name.startsWith("mcp__")) return "mcp:" + name.split("__")[1];
  return name;
}

export function repoOf(cwd, projectDir) {
  const c = String(cwd || "");
  let m = c.match(/\/\.boss-os\/([^/]+?)(?:-runs)?(?:\/|$)/);
  if (m) return "boss-os:" + m[1];
  m = c.match(/\/GitHub\/([^/]+)/);
  if (m) return m[1];
  if (c === HOME || c === HOME + "/") return "home";
  if (c) return /^\/(private\/)?(tmp|var)\//.test(c) ? "tmp" : basename(c);
  return basename(projectDir || "?");
}

// ---------- one transcript, streamed ----------
export async function readTranscript(file, sinceMs) {
  const r = { file, calls: 0, tools: 0, tokens: 0, input: 0, cacheRead: 0, cacheWrite: 0, output: 0, models: {},
              cats: {}, cwd: "", title: "", firstTs: null, lastTs: null, bad: 0, usageLines: 0, maxContext: 0 };
  const seen = new Set(); const toolById = new Map(); let open = []; // results not yet finalised for carry
  const finalise = () => { for (const x of open) { const c = (r.cats[x.cat] ??= { entered: 0, carried: 0, n: 0 }); c.carried += x.size * (r.calls - x.at); } open = []; };
  const rl = createInterface({ input: createReadStream(file, { encoding: "utf8" }), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line) continue;
    if (line.startsWith('{"type":"')) {
      if (line.startsWith('{"type":"ai-title"') || line.startsWith('{"type":"custom-title"')) {
        try { const d = JSON.parse(line); const t = d.aiTitle ?? d.customTitle ?? d.title; if (t) r.title = t; } catch { r.bad++; }
      }
      continue; // api-request blobs and the like: no usage of their own
    }
    let d; try { d = JSON.parse(line); } catch { r.bad++; continue; }
    if (d.type === "system" && d.subtype === "compact_boundary") { finalise(); continue; }
    const ts = d.timestamp ? Date.parse(d.timestamp) : NaN;
    if (!r.cwd && d.cwd) r.cwd = d.cwd;
    const msg = d.message;
    if (d.type === "assistant" && msg) {
      for (const b of Array.isArray(msg.content) ? msg.content : []) if (b?.type === "tool_use") { toolById.set(b.id, category(b.name, b.input)); if (!(ts < sinceMs)) r.tools++; }
      const u = msg.usage; const id = msg.id || d.requestId;
      if (u && id && !seen.has(id)) {
        seen.add(id); r.usageLines++;
        if (ts < sinceMs) continue;
        const inp = u.input_tokens | 0, cr = u.cache_read_input_tokens | 0, cw = u.cache_creation_input_tokens | 0, out = u.output_tokens | 0;
        r.calls++; r.input += inp; r.cacheRead += cr; r.cacheWrite += cw; r.output += out; r.tokens += inp + cr + cw + out;
        r.maxContext = Math.max(r.maxContext, inp + cr + cw);
        if (msg.model) r.models[msg.model] = (r.models[msg.model] ?? 0) + 1;
        if (!Number.isNaN(ts)) { r.firstTs ??= ts; r.lastTs = ts; }
      }
    } else if (d.type === "user" && Array.isArray(msg?.content)) {
      if (ts < sinceMs) continue;
      for (const b of msg.content) {
        if (b?.type !== "tool_result") continue;
        const cat = toolById.get(b.tool_use_id) ?? "other";
        const parts = typeof b.content === "string" ? [{ type: "text", text: b.content }] : Array.isArray(b.content) ? b.content : [];
        for (const p of parts) {
          const isImg = p?.type === "image";
          const size = isImg ? IMAGE_TOKENS : Math.ceil(String(p?.text ?? "").length / 4);
          const k = isImg ? "screenshots/images" : cat;
          const c = (r.cats[k] ??= { entered: 0, carried: 0, n: 0 }); c.entered += size; c.n++;
          open.push({ cat: k, size, at: r.calls });
        }
      }
    }
  }
  finalise();
  return r;
}

function listTranscripts(root, sinceMs) {
  const out = [];
  let dirs; try { dirs = readdirSync(root, { withFileTypes: true }); } catch { return null; }
  for (const p of dirs) {
    if (!p.isDirectory()) continue;
    const pd = join(root, p.name);
    let ents; try { ents = readdirSync(pd, { withFileTypes: true }); } catch { continue; }
    for (const e of ents) {
      const f = join(pd, e.name);
      if (e.isFile() && e.name.endsWith(".jsonl")) { try { if (statSync(f).mtimeMs >= sinceMs) out.push({ file: f, project: p.name, kind: "main" }); } catch {} }
      else if (e.isDirectory()) {
        const sd = join(f, "subagents");
        let subs; try { subs = readdirSync(sd); } catch { continue; }
        for (const s of subs) if (s.endsWith(".jsonl")) {
          const sf = join(sd, s);
          try { if (statSync(sf).mtimeMs >= sinceMs) out.push({ file: sf, project: p.name, kind: "subagent", parent: e.name }); } catch {}
        }
      }
    }
  }
  return out;
}

function meta(file) {
  try { return JSON.parse(readFileSync(file.replace(/\.jsonl$/, ".meta.json"), "utf8")); } catch { return {}; }
}

export function topCauses(cats, n = 3) {
  const total = Object.values(cats).reduce((a, c) => a + c.carried, 0) || 1;
  return Object.entries(cats).sort((a, b) => b[1].carried - a[1].carried).slice(0, n)
    .map(([k, c]) => ({ cause: k, results: c.n, entered: c.entered, carried: c.carried, share: Math.round((100 * c.carried) / total) }));
}

// ---------- Boss OS's own ledger, through the vault; never a 0 when it was not read ----------
function readBoss(days) {
  if (process.env.TOKEN_REPORT_BOSS === "off") return Promise.resolve({ read: false, why: "not read: switched off" });
  const js = `import('./scripts/ops/lib/duty-kit.mjs').then(async (m) => { const api = await m.bossApi(); const d = await api.get('/system/cost?days=${days}'); console.log(JSON.stringify({ byModel: (d.by_model ?? []).map((x) => ({ model: x.display_name ?? x.model_id, in_tokens: x.in_tokens, out_tokens: x.out_tokens })), byEmployee: (d.by_employee ?? []).map((x) => ({ employee: x.name ?? x.employee_id, calls: x.calls })) })); }).catch((e) => { console.error(String(e.message).slice(0, 160)); process.exit(1); })`;
  return new Promise((res) => {
    execFile("npm", ["run", "-s", "vault:run", "--", "node", "--input-type=module", "-e", js], { cwd: process.env.TOKEN_REPORT_BOSS_CWD || join(HOME, "GitHub/boss-os"), timeout: 60_000, maxBuffer: 4 << 20 }, (err, stdout, stderr) => {
      if (err) return res({ read: false, why: "not read: " + clean(String(stderr || err.message).split("\n").filter(Boolean).pop() ?? "", 120) });
      try { const j = JSON.parse(String(stdout).trim().split("\n").pop()); return res({ read: true, ...j }); }
      catch { return res({ read: false, why: "not read: its answer could not be parsed" }); }
    });
  });
}

const fmt = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e3 ? Math.round(n / 1e3) + "K" : String(n));
const median = (a) => { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const centralDay = (ms = Date.now()) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago" }).format(ms);

export async function report({ root, days, minRows = 1, boss = true }) {
  const sinceMs = Date.now() - days * 86_400_000;
  const files = listTranscripts(root, sinceMs);
  if (files === null) return { stop: "NO_TRANSCRIPTS", why: `the transcript folder ${root} could not be read`, code: 3 };
  if (!files.length) return { stop: "NO_TRANSCRIPTS", why: `no transcript under ${root} changed in the last ${days} day(s)`, code: 3 };
  const rows = []; let usage = 0, bad = 0;
  for (const f of files) {
    const t = await readTranscript(f.file, sinceMs);
    usage += t.usageLines; bad += t.bad;
    if (!t.calls) continue;
    const m = f.kind === "subagent" ? meta(f.file) : {};
    const repo = repoOf(t.cwd, f.project);
    const role = f.kind === "subagent" ? (m.agentType || "subagent") : repo.startsWith("boss-os:") ? repo : "main";
    rows.push({
      id: basename(f.file, ".jsonl").replace(/^agent-/, "").slice(0, 12), kind: f.kind, role, repo,
      task: clean(f.kind === "subagent" ? m.description : t.title) || (f.kind === "subagent" ? "(no description)" : "(untitled session)"),
      finished: f.kind === "subagent" ? m.finished === true : null,
      tokens: t.tokens, input: t.input, cacheRead: t.cacheRead, cacheWrite: t.cacheWrite, output: t.output,
      calls: t.calls, toolCalls: t.tools, maxContext: t.maxContext, models: Object.keys(t.models),
      causes: topCauses(t.cats), causeTotals: t.cats,
    });
  }
  if (!usage) return { stop: "UNREADABLE_FORMAT", why: `${files.length} transcript(s) found but no usage record could be read (${bad} unreadable lines)`, code: 4 };
  if (rows.length < minRows) return { stop: "TOO_FEW_ROWS", why: `${rows.length} job(s) with usage in the window, fewer than the ${minRows} required`, code: 5 };
  rows.sort((a, b) => b.tokens - a.tokens);
  const byRole = {};
  for (const r of rows) {
    const g = (byRole[r.role] ??= { runs: 0, finished: 0, tokens: 0, perRun: [], perFinished: [] });
    g.runs++; g.tokens += r.tokens; g.perRun.push(r.tokens);
    if (r.finished) { g.finished++; g.perFinished.push(r.tokens); }
  }
  for (const g of Object.values(byRole)) { g.medianPerRun = median(g.perRun); g.medianPerFinished = median(g.perFinished); delete g.perRun; delete g.perFinished; }
  const causeAll = {};
  for (const r of rows) for (const [k, c] of Object.entries(r.causeTotals)) { const x = (causeAll[k] ??= { entered: 0, carried: 0, n: 0 }); x.entered += c.entered; x.carried += c.carried; x.n += c.n; }
  for (const r of rows) delete r.causeTotals;
  return {
    generated: new Date().toISOString(), day: centralDay(), days, transcripts: files.length, unreadableLines: bad,
    totalTokens: rows.reduce((a, r) => a + r.tokens, 0), jobs: rows.length, byRole, topCauses: topCauses(causeAll, 6),
    bossOs: boss ? await readBoss(days) : { read: false, why: "not read: switched off" }, rows,
  };
}

export function table(rep, n = 15) {
  const L = [`Tokens, last ${rep.days} day(s) to ${rep.day}: ${fmt(rep.totalTokens)} in ${rep.jobs} jobs (${rep.transcripts} transcripts)`];
  L.push("  tokens  calls tools role/repo                         task                                     top causes (carried)");
  for (const r of rep.rows.slice(0, n)) {
    L.push(`  ${fmt(r.tokens).padStart(6)} ${String(r.calls).padStart(6)} ${String(r.toolCalls).padStart(5)} ${(r.role + " " + r.repo).slice(0, 33).padEnd(33)} ${r.task.slice(0, 40).padEnd(40)} ${r.causes.map((c) => `${c.cause} ${c.share}%`).join(", ")}`);
  }
  L.push("By role: " + Object.entries(rep.byRole).sort((a, b) => b[1].tokens - a[1].tokens).slice(0, 8).map(([k, g]) => `${k} ${fmt(g.tokens)} (${g.runs} runs, median ${fmt(g.medianPerRun)})`).join("; "));
  L.push("Causes overall (carried): " + rep.topCauses.map((c) => `${c.cause} ${c.share}%`).join(", "));
  L.push("Boss OS ledger: " + (rep.bossOs.read ? (rep.bossOs.byModel ?? []).slice(0, 4).map((m) => `${m.model} ${fmt((m.in_tokens | 0) + (m.out_tokens | 0))}`).join(", ") + "; calls by employee: " + (rep.bossOs.byEmployee ?? []).map((e) => `${e.employee} ${e.calls}`).join(", ") || "read, no model calls in the window" : rep.bossOs.why));
  return L.join("\n");
}

// ---------- before and after ----------
// Tokens per finished builder, reviewer and helper run, each role on its own. The week's figure weights each
// role by the BASELINE's run counts, so a week with more (cheaper) reviews and fewer builds cannot pass as a cut.
export function perRole(rep) {
  const roles = {};
  for (const role of ROLES) {
    const fin = rep.rows.filter((r) => r.role === role && r.finished);
    roles[role] = { finished: fin.length, perFinished: fin.length ? Math.round(fin.reduce((a, r) => a + r.tokens, 0) / fin.length) : null };
  }
  return roles;
}

export function compare(base, cur, minRuns = 3) {
  const b = perRole(base), c = perRole(cur);
  const both = ROLES.filter((r) => b[r].finished >= minRuns && c[r].finished >= minRuns);
  const detail = ROLES.map((r) => `${r} ${b[r].perFinished == null ? "-" : fmt(b[r].perFinished)} → ${c[r].perFinished == null ? "-" : fmt(c[r].perFinished)} (${b[r].finished}/${c[r].finished} runs)`).join(", ");
  if (!both.includes("builder") || both.length < 2)
    return { verdict: "NOT CHECKED", code: 6, line: `VERDICT: NOT CHECKED — too few finished runs to compare (need ${minRuns} each week, builders and one more role); ${detail}` };
  const w = both.reduce((a, r) => a + b[r].finished, 0);
  const before = both.reduce((a, r) => a + b[r].finished * b[r].perFinished, 0) / w;
  const after = both.reduce((a, r) => a + b[r].finished * c[r].perFinished, 0) / w;
  const drop = 1 - after / before, pct = Math.round(drop * 100);
  const head = `${both.join("/")} tokens per finished task ${fmt(before)} → ${fmt(after)} (${pct >= 0 ? "−" : "+"}${Math.abs(pct)}%, the baseline's mix); ${detail}`;
  return drop >= 1 / 3
    ? { verdict: "WORKING", code: 0, drop, line: `VERDICT: WORKING — ${head}` }
    : { verdict: "NOT WORKING", code: 1, drop, line: `VERDICT: NOT WORKING — ${head}; the cut needed is a third or more` };
}

// ---------- the nightly run ----------
export const BASELINE = process.env.TOKEN_REPORT_BASELINE || join(MEASURE, "tokens-baseline-2026-11-28.json");
async function nightly(a) {
  const mw = process.env.TOKEN_REPORT_MAC_WINDOW ?? join(dirname(fileURLToPath(import.meta.url)), "mac-window");
  if (mw !== "off") {
    const w = await new Promise((res) => execFile(mw, ["check", "ANY"], { timeout: 30_000 }, (err, out, e) => res({ rc: err ? (err.code ?? 9) : 0, text: String(out || e).trim() })));
    if (w.rc === 1) { console.log(w.text || "OUTSIDE_WINDOW token-report ANY"); console.log("OUTPUT token-report 0 jobs (outside the Mac's window; it waits)"); return 0; }
    if (w.rc !== 0) { console.log(`NAMED STOP [MAC_WINDOW_UNREAD] mac-window check exited ${w.rc}: ${clean(w.text, 160)}`); console.log("OUTPUT token-report 0 jobs"); return 3; }
  }
  mkdirSync(MEASURE, { recursive: true });
  const rep = await report({ root: a.root, days: 1, minRows: a.minRows, boss: a.boss });
  if (rep.stop) { console.log(`NAMED STOP [${rep.stop}] ${rep.why}`); console.log("OUTPUT token-report 0 jobs"); return rep.code; }
  const out = join(MEASURE, `tokens-${rep.day}.json`);
  writeFileSync(out, JSON.stringify(rep, null, 1));
  console.log(table(rep, 5));
  let base = null; try { base = JSON.parse(readFileSync(BASELINE, "utf8")); } catch (e) { console.log(`compare: NAMED STOP [BASELINE_UNREAD] ${BASELINE}: ${e.code ?? e.message}`); }
  if (base) {
    const week = await report({ root: a.root, days: 7, minRows: 1, boss: false });
    const v = week.stop ? { line: `VERDICT: NOT CHECKED — the week could not be read: NAMED STOP [${week.stop}] ${week.why}` } : compare(base, week);
    if (!week.stop) writeFileSync(join(MEASURE, `tokens-week-${week.day}.json`), JSON.stringify(week, null, 1));
    writeFileSync(join(MEASURE, "tokens-compare.txt"), `${v.line}\n(${centralDay()}: ${BASELINE} against the last 7 days)\n`);
    console.log("compare: " + v.line);
  }
  const cutoff = Date.now() - 60 * 86_400_000;
  for (const f of readdirSync(MEASURE)) if (/^tokens-(week-)?\d{4}-\d{2}-\d{2}\.json$/.test(f)) { const p = join(MEASURE, f); try { if (statSync(p).mtimeMs < cutoff) unlinkSync(p); } catch {} }
  console.log(`JSON: ${out}`);
  console.log(`OUTPUT token-report ${rep.jobs} jobs ${rep.totalTokens} tokens`);
  return 0;
}

// ---------- command line ----------
async function main(argv) {
  const a = { days: 1, root: join(HOME, ".claude/projects"), minRows: 1, boss: true };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = argv[i + 1];
    if (k === "--days") { a.days = Number(v); i++; } else if (k === "--out") { a.out = v; i++; }
    else if (k === "--root") { a.root = v; i++; } else if (k === "--min-rows") { a.minRows = Number(v); i++; }
    else if (k === "--compare") { a.compare = v; i++; } else if (k === "--current") { a.current = v; i++; }
    else if (k === "--no-boss") a.boss = false;
    else if (k === "--nightly") a.nightly = true;
    else { console.error("usage: token-report [--days N] [--out FILE] [--root DIR] [--min-rows N] [--no-boss] | --compare BASE.json [--current CUR.json]"); return 64; }
  }
  if (a.nightly) return nightly(a);
  if (!(a.days > 0)) { console.error("usage: --days must be a number above 0"); return 64; }
  mkdirSync(MEASURE, { recursive: true });
  if (a.compare) {
    let base, cur;
    try { base = JSON.parse(readFileSync(a.compare, "utf8")); } catch (e) { console.log(`NAMED STOP [BASELINE_UNREAD] ${a.compare}: ${e.code ?? e.message}`); console.log("OUTPUT token-report compare: not checked"); return 6; }
    if (a.current) { try { cur = JSON.parse(readFileSync(a.current, "utf8")); } catch (e) { console.log(`NAMED STOP [CURRENT_UNREAD] ${a.current}: ${e.code ?? e.message}`); console.log("OUTPUT token-report compare: not checked"); return 6; } }
    else {
      cur = await report({ root: a.root, days: 7, minRows: a.minRows, boss: false });
      if (cur.stop) { console.log(`NAMED STOP [${cur.stop}] ${cur.why}`); console.log("OUTPUT token-report compare: not checked"); return 6; }
      writeFileSync(join(MEASURE, `tokens-week-${cur.day}.json`), JSON.stringify(cur, null, 1));
    }
    const v = compare(base, cur);
    writeFileSync(join(MEASURE, "tokens-compare.txt"), `${v.line}\n(${centralDay()}: ${a.compare} against ${a.current ?? "the last 7 days"})\n`);
    console.log(v.line);
    console.log(`OUTPUT token-report compare: ${v.verdict}`);
    return v.code;
  }
  const rep = await report(a);
  if (rep.stop) { console.log(`NAMED STOP [${rep.stop}] ${rep.why}`); console.log("OUTPUT token-report 0 jobs"); return rep.code; }
  const out = a.out || join(MEASURE, `tokens-${rep.day}.json`);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(rep, null, 1));
  console.log(table(rep));
  console.log(`JSON: ${out}`);
  console.log(`OUTPUT token-report ${rep.jobs} jobs ${rep.totalTokens} tokens`);
  return 0;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then((c) => process.exit(c), (e) => { console.log(`NAMED STOP [TOKEN_REPORT_CRASHED] ${clean(e.message, 160)}`); console.log("OUTPUT token-report 0 jobs"); process.exit(9); });
}
