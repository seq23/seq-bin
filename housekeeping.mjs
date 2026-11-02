#!/usr/bin/env node
// Nightly Mac housekeeping → Boss OS Open Loops (approved 1 Nov 2026). Run by housekeeping.sh, which
// injects BOSS_OPEN_LOOPS_TOKEN from the Boss OS vault. Three checks, each opening or closing its own
// Open Loops row (repo seq23/seq-bin, one row per stop code, upserted by Boss OS on repo#STOP):
//
//   1. Unsaved work: every checkout with changes older than 24 h (by file mtime) → one row per checkout.
//      Clean → the row closes. Never commits, stashes or discards anything. Paths and counts only:
//      no file contents leave the Mac. A ~/GitHub/.wt-* worktree with a change in the last 24 h belongs
//      to a running agent and is left alone.
//   2. Backup: needs-decision.txt from drive-backup.sh (DRIVE_BACKUP_BIG_FOLDER) → a row she decides;
//      a DRIVE_BACKUP_TOO_SLOW / DRIVE_BACKUP_FAILED stop in today's backup log, or no log at all → a
//      row Claude fixes.
//   3. Rules clean-up: the 1st of the month, or ~/.claude/CLAUDE.md over 2,000 words → one row a month.
//
// Rule 0: every outcome is a line in the log. A post that fails, or a missing token, is a NAMED STOP
// with a non-zero exit, never a silent 0. HOUSEKEEPING_DRY_RUN=1 prints the payloads and posts nothing.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { post } from "./open-loops.mjs";

const HOME = process.env.HOME;
const REPO = "seq23/seq-bin";
const DRY = process.env.HOUSEKEEPING_DRY_RUN === "1";
const DAY = 86_400_000;
const NOW = Date.now();
const WORD_LIMIT = 2000;
const STATE_DIR = path.join(HOME, "Library/Application Support/housekeeping");
const STATE_FILE = path.join(STATE_DIR, "state.json");
const BACKUP_STATE = path.join(HOME, "Library/Application Support/drive-backup");
const BACKUP_LOGS = path.join(HOME, "Library/Logs/drive-backup");

const stop = (code, exit, words) => Object.assign(new Error(`NAMED STOP [${code}] ${words}`), { exit });
const dayIn = (ms, tz) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(ms);
// Overridable for the test only; the job itself reads the clock.
const TODAY_CT = process.env.HOUSEKEEPING_TODAY || dayIn(NOW, "America/Chicago");
const TODAY_LOCAL = process.env.HOUSEKEEPING_TODAY || dayIn(NOW, undefined); // drive-backup names its log in the Mac's zone
const TOMORROW = dayIn(Date.parse(`${TODAY_CT}T12:00:00Z`) + DAY, "UTC");
const tilde = (p) => (p.startsWith(HOME + "/") ? "~/" + p.slice(HOME.length + 1) : p);
const slug = (p) => tilde(p).replace(/^~\//, "").replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").toUpperCase().slice(0, 70) || "HOME";
const base = { repo: REPO, owner: "claude", business: "personal", next_date: TOMORROW };

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch { return { unsaved: [], rules: [] }; }
}

// ─── 1. Unsaved work ────────────────────────────────────────────────────────────────────────────────
function checkouts() {
  const list = [path.join(HOME, "bin")];
  const gh = path.join(HOME, "GitHub");
  if (fs.existsSync(gh)) for (const n of fs.readdirSync(gh).sort()) list.push(path.join(gh, n));
  list.push(path.join(HOME, ".boss-os/runtime"), path.join(HOME, "aplayer-mode"));
  return [...new Set(list)].filter((p) => fs.existsSync(path.join(p, ".git")));
}

function mtimeOf(p) {
  // A deleted file has no mtime; its nearest surviving folder changed when it went.
  for (let q = p; ; q = path.dirname(q)) {
    try { return fs.lstatSync(q).mtimeMs; } catch { if (q === path.dirname(q)) return NOW; }
  }
}

function changes(dir) {
  const out = execFileSync("git", ["-C", dir, "status", "--porcelain=v1", "-z", "--untracked-files=all"], { encoding: "utf8", maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "pipe"] });
  const parts = out.split("\0").filter(Boolean);
  const files = [];
  for (let i = 0; i < parts.length; i++) {
    const xy = parts[i].slice(0, 2);
    files.push(parts[i].slice(3));
    if (xy[0] === "R" || xy[0] === "C") i++; // the rename's old path follows; one change, not two
  }
  return files.map((f) => mtimeOf(path.join(dir, f)));
}

function checkUnsaved(state, posts, log) {
  const seen = new Set();
  let read = 0, skipped = 0;
  for (const dir of checkouts()) {
    const code = `UNSAVED_${slug(dir)}`;
    let times;
    try { times = changes(dir); } catch (e) { log.push(`could not read ${tilde(dir)}: ${String(e.stderr || e.message).split("\n")[0]}`); continue; }
    read++;
    seen.add(code);
    const old = times.filter((t) => t < NOW - DAY);
    if (path.basename(dir).startsWith(".wt-") && times.some((t) => t >= NOW - DAY)) {
      skipped++; log.push(`left alone ${tilde(dir)}: a running agent's worktree (changed in the last 24 h)`); continue;
    }
    if (old.length === 0) { posts.push({ ...base, stop: code, cleared: true, finish_line: "saved to GitHub or discarded on purpose" }); continue; }
    const n = times.length, oldest = dayIn(Math.min(...old), "America/Chicago");
    posts.push({
      ...base, stop: code,
      title: `Unsaved edits in ${tilde(dir)} (${n} file${n === 1 ? "" : "s"}, oldest ${oldest})`,
      finish_line: "saved to GitHub or discarded on purpose",
      next_step: `${n} changed file${n === 1 ? "" : "s"} in ${tilde(dir)}, the oldest from ${oldest}. Look at them, then save them to GitHub in a pull request or discard them on purpose. The nightly check never touches them itself.`,
    });
  }
  // A checkout that is gone (a removed worktree) cannot be dirty any more: close its row.
  for (const code of state.unsaved || []) if (!seen.has(code)) posts.push({ ...base, stop: code, cleared: true, finish_line: "saved to GitHub or discarded on purpose" });
  return { read, skipped, seen };
}

// ─── 2. Backup ─────────────────────────────────────────────────────────────────────────────────────
function checkBackup(posts, log) {
  const nd = path.join(BACKUP_STATE, "needs-decision.txt");
  if (fs.existsSync(nd)) {
    const folders = fs.readFileSync(nd, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
    posts.push({
      ...base, owner: "sequoia", stop: "BACKUP_BIG_FOLDER",
      title: `Backup held back a big folder: ${folders.join(", ")} — back up or skip?`.slice(0, 200),
      finish_line: "every held-back folder is either backed up or on the skip list",
      next_step: `Held back from the nightly backup: ${folders.join(", ")}. To back one up, Claude adds its name to big-folders-ok.txt in the drive-backup settings folder and the next night uploads it; to skip it, Claude adds it to the backup's skip list.`.slice(0, 400),
    });
  } else posts.push({ ...base, stop: "BACKUP_BIG_FOLDER", owner: "sequoia", cleared: true, finish_line: "every held-back folder is either backed up or on the skip list" });

  const logFile = path.join(BACKUP_LOGS, `${TODAY_LOCAL}.log`);
  let found = null;
  if (!fs.existsSync(logFile)) found = "DID_NOT_RUN";
  else {
    const size = fs.statSync(logFile).size, fd = fs.openSync(logFile, "r"), len = Math.min(size, 256 << 10);
    const buf = Buffer.alloc(len); fs.readSync(fd, buf, 0, len, size - len); fs.closeSync(fd);
    const m = [...buf.toString("utf8").matchAll(/NAMED STOP:? \[?DRIVE_BACKUP_(TOO_SLOW|FAILED)\]?/g)].pop();
    if (m) found = m[1];
  }
  const words = {
    TOO_SLOW: ["Last night's backup ran out of time before it finished", "Find what made it slow (the log names where it stopped) and make the next run finish inside its hour."],
    FAILED: ["Last night's backup failed", "Read the backup log for the error; a token or client_id error means reconnecting Drive (rclone config reconnect gdrive:)."],
    DID_NOT_RUN: ["Last night's backup did not run", "Find why the drive-backup job did not run (launchctl list com.seq.drive-backup) and get it running again."],
  };
  for (const k of Object.keys(words)) {
    const stopCode = `BACKUP_${k}`;
    if (k === found) posts.push({ ...base, stop: stopCode, title: words[k][0], finish_line: "the nightly backup finishes cleanly", next_step: `${words[k][1]} Log: ~/Library/Logs/drive-backup/${TODAY_LOCAL}.log` });
    else posts.push({ ...base, stop: stopCode, cleared: true, finish_line: "the nightly backup finishes cleanly" });
  }
  log.push(`backup: ${fs.existsSync(nd) ? "big folder held back; " : ""}${found ? `stop ${found}` : "clean"}`);
}

// ─── 3. Rules clean-up trigger ─────────────────────────────────────────────────────────────────────
function checkRules(state, posts, log) {
  const f = path.join(HOME, ".claude/CLAUDE.md");
  if (!fs.existsSync(f)) { log.push("rules: ~/.claude/CLAUDE.md not found, not checked"); return null; }
  const words = fs.readFileSync(f, "utf8").split(/\s+/).filter(Boolean).length;
  const first = TODAY_CT.endsWith("-01"), long = words > WORD_LIMIT;
  log.push(`rules: ${words} words${first ? ", 1st of the month" : ""}`);
  if (!first && !long) return null; // any open row stays open until the review is done
  const code = `RULES_CLEANUP_${TODAY_CT.slice(0, 7).replace("-", "_")}`;
  if ((state.rules || []).includes(code)) { log.push(`rules: ${code} already posted this month`); return null; }
  const reason = [first && "1st of the month", long && "over 2,000 words"].filter(Boolean).join(" and ");
  posts.push({
    ...base, stop: code,
    title: `Rules clean-up due (${reason}, ${words.toLocaleString("en-US")} words)`,
    finish_line: "her approval on a keep/tighten/merge/move/cut review artifact",
    next_step: "Review every rule in ~/.claude/CLAUDE.md as keep, tighten, merge, move or cut on one artifact page, get her approval, then apply it.",
  });
  return code;
}

async function main() {
  const state = readState();
  const posts = [], log = [];
  const { read, skipped, seen } = checkUnsaved(state, posts, log);
  if (read === 0) throw stop("NOTHING_CHECKED", 2, "no checkout could be read (~/bin, ~/GitHub/*, ~/.boss-os/runtime, ~/aplayer-mode); nothing was posted.");
  checkBackup(posts, log);
  const rulesCode = checkRules(state, posts, log);
  for (const l of log) console.log(l);
  const open = posts.filter((p) => !p.cleared);
  if (DRY) { for (const p of posts) console.log("DRY_RUN", JSON.stringify(p)); console.log(`housekeeping dry run: ${read} checkouts read, ${open.length} rows to open, ${posts.length - open.length} to clear`); return; }
  const token = process.env.BOSS_OPEN_LOOPS_TOKEN;
  if (!token) throw stop("OPEN_LOOPS_TOKEN_MISSING", 3, "BOSS_OPEN_LOOPS_TOKEN is not in the environment; run through housekeeping.sh (it injects it from the Boss OS vault). Nothing was posted.");
  const actions = {}, failed = [];
  for (const p of posts) {
    try { const a = await post(p, token); actions[a] = (actions[a] || 0) + 1; if (!p.cleared || a === "closed") console.log(`${a}: ${p.stop}${p.title ? ` — ${p.title}` : ""}`); }
    catch (e) { failed.push(`${p.stop} (${e.message})`); }
  }
  if (failed.length === 0) {
    const next = { unsaved: [...new Set([...open.map((p) => p.stop).filter((s) => s.startsWith("UNSAVED_") && seen.has(s))])], rules: [...(state.rules || [])] };
    // Keep rows for skipped agent worktrees on the list so they are closed once those finish.
    for (const c of state.unsaved || []) if (seen.has(c) && !posts.some((p) => p.stop === c)) next.unsaved.push(c);
    if (rulesCode) next.rules.push(rulesCode);
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(next, null, 2));
  }
  console.log(`housekeeping ${TODAY_CT}: ${read} checkouts read (${skipped} agent worktrees left alone); ${posts.length} posts: ${Object.entries(actions).map(([k, v]) => `${v} ${k}`).join(", ") || "none"}`);
  if (failed.length) throw stop("OPEN_LOOPS_POST_FAILED", 9, `${failed.length} of ${posts.length} posts to Boss OS Open Loops failed: ${failed.slice(0, 3).join("; ")}. Boss OS may be down or the token retired; the next nightly run posts again.`);
}

main().catch((e) => { console.error(e.message); process.exit(e.exit ?? 1); });
