#!/usr/bin/env node
/**
 * Marketplace listings show our real work (owner, 1 Nov 2026): before a listings run,
 * ~/bin/pnp-listings.sh runs this to bring the newest real Porch & Party job photos and clips onto
 * this Mac, so Camille's run can attach them to a listing (Claude in Chrome's file_upload takes a
 * local path). READ-ONLY on every source; it never deletes a file it fetched earlier.
 *
 * Sources, newest first:
 *   1. P&P Studio photo sets (pnpstudio.spryexecutiveos.com → Photos): the CHECKED copies the photo
 *      maker wrote (faces and house numbers already blurred), only from sets that are ready and not
 *      blocked. D1 creator-studios-sample1-db, R2 creator-studios-sample1-files.
 *   2. P&P Studio approved clips (same store), the newest few, for a listing that takes a video.
 *   3. The owner's saved real-job photos on this Mac (~/Work/porch-and-party/real-work-photos).
 * NOT a source: the P&P admin's photos. Its only photo stores are the walk-through checklist
 * (the place before our work, damage notes) and customers' IDs; neither is a picture of finished work.
 *
 * Writes <dir>/manifest.json (file, date, source, kind, shows, touched_up_with_ai) and <dir>/list.txt
 * (the same list in plain words, which the listings run reads). Prints counts and dates only: never
 * a file name, a note or a customer.
 *   real work photos: OUTPUT <n> new, <m> usable     always the last line (new = last 14 days)
 *   NAMED STOP [REAL_PHOTOS_NOT_READ] ...            P&P Studio could not be read; exit 2, and the
 *                                                     files already on this Mac stay usable
 * Run it under the Boss OS vault (the Cloudflare token):
 *   cd ~/GitHub/boss-os && node scripts/vault/vault.mjs run -- node ~/bin/pnp-real-work.mjs
 * Knobs: PNP_REAL_WORK_DIR (default ~/.boss-os/pnp-listings/real-work), PNP_REAL_WORK_OWNER_DIR,
 * PNP_REAL_WORK_WRANGLER (a stand-in for `npx wrangler`, used by tests/test-pnp-real-work.sh).
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const HOME = os.homedir();
const DIR = process.env.PNP_REAL_WORK_DIR || path.join(HOME, ".boss-os", "pnp-listings", "real-work");
const OWNER_DIR = process.env.PNP_REAL_WORK_OWNER_DIR || path.join(HOME, "Work", "porch-and-party", "real-work-photos");
const STUDIO_REPO = path.join(HOME, "GitHub", "creator-studios");
const DB = "creator-studios-sample1-db";
const BUCKET = "creator-studios-sample1-files";
const NEW_DAYS = 14;
const MAX_SETS = 12; // newest photo sets kept on this Mac
const MAX_CLIPS = 3;
const MAX_UPLOAD = 9 * 1024 * 1024; // file_upload refuses 10 MB and over in one call
const SETS_SQL = `SELECT p.id AS id, p.created_at AS at, p.ai_edited AS edited, p.note AS note, i.images AS images FROM photo_packs p JOIN pack_items i ON i.pack_id = p.id AND i.kind = 'carousel' WHERE p.status = 'ready' AND p.privacy IN ('clean', 'fixed') ORDER BY p.created_at DESC LIMIT ${MAX_SETS}`;
const CLIPS_SQL = `SELECT id, created_at AS at, r2_key AS r2_key, hook_text AS note FROM clips WHERE status = 'approved' AND hidden = 0 ORDER BY created_at DESC LIMIT ${MAX_CLIPS}`;

function wrangler(args) {
  const stub = process.env.PNP_REAL_WORK_WRANGLER;
  const [cmd, argv] = stub ? [stub, args] : ["npx", ["wrangler", ...args]];
  return execFileSync(cmd, argv, { cwd: stub ? DIR : STUDIO_REPO, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 180_000, maxBuffer: 32 * 1024 * 1024 });
}
function rows(sql) {
  const out = JSON.parse(wrangler(["d1", "execute", DB, "--remote", "--json", "--command", sql]));
  const r = out?.[0]?.results;
  if (!Array.isArray(r)) throw new Error("no result rows");
  return r;
}
/** Fetch one stored file unless it is already here. True when the file is on this Mac afterwards. */
function fetchFile(key, file) {
  const dest = path.join(DIR, file);
  if (fs.existsSync(dest) && fs.statSync(dest).size > 0) return true;
  const tmp = `${dest}.part`;
  try {
    wrangler(["r2", "object", "get", `${BUCKET}/${key}`, "--file", tmp, "--remote"]);
    if (!fs.existsSync(tmp) || fs.statSync(tmp).size === 0) throw new Error("empty file");
    fs.renameSync(tmp, dest);
    return true;
  } catch {
    fs.rmSync(tmp, { force: true });
    return false;
  }
}
const day = (t) => String(t).slice(0, 10);
const safe = (s) => String(s).replace(/[^A-Za-z0-9._-]/g, "-");
const oneLine = (s) => String(s ?? "").replace(/\s+/g, " ").trim().slice(0, 200);
const firstLine = (e) => String(e?.stderr || e?.message || e).split("\n").find((l) => l.trim())?.trim().slice(0, 160) ?? "unknown error";

fs.mkdirSync(DIR, { recursive: true });
let previous = [];
try { previous = JSON.parse(fs.readFileSync(path.join(DIR, "manifest.json"), "utf8")).photos ?? []; } catch { previous = []; }

const items = [];
let stop = null;
let missed = 0;

// 1 + 2. P&P Studio.
try {
  for (const set of rows(SETS_SQL)) {
    let keys = [];
    try { keys = JSON.parse(set.images); } catch { keys = []; }
    keys.forEach((key, i) => {
      const file = `studio-${day(set.at)}-${safe(set.id)}-${i + 1}${path.extname(String(key)) || ".jpg"}`;
      if (!fetchFile(key, file)) { missed += 1; return; }
      items.push({ file, date: day(set.at), source: "P&P Studio photo set (checked copy)", kind: "photo", shows: oneLine(set.note), touched_up_with_ai: !!set.edited });
    });
  }
  for (const clip of rows(CLIPS_SQL)) {
    const file = `studio-clip-${day(clip.at)}-${safe(clip.id)}${path.extname(String(clip.r2_key)) || ".mp4"}`;
    if (!fetchFile(clip.r2_key, file)) { missed += 1; continue; }
    if (fs.statSync(path.join(DIR, file)).size > MAX_UPLOAD) continue; // too big to attach
    items.push({ file, date: day(clip.at), source: "P&P Studio approved clip", kind: "clip", shows: oneLine(clip.note), touched_up_with_ai: true });
  }
} catch (e) {
  stop = `P&P Studio could not be read (${firstLine(e)})`;
  // Keep what an earlier run fetched: those files are still real work.
  for (const p of previous) if (String(p.source).startsWith("P&P Studio") && fs.existsSync(path.join(DIR, p.file))) items.push(p);
}

// 3. The owner's saved real-job photos on this Mac.
let ownerNotes = "";
if (fs.existsSync(OWNER_DIR)) {
  try { ownerNotes = fs.readFileSync(path.join(OWNER_DIR, "README.md"), "utf8").trim(); } catch { ownerNotes = ""; }
  for (const name of fs.readdirSync(OWNER_DIR).sort()) {
    if (!/\.(jpe?g|png|webp)$/i.test(name)) continue;
    const src = path.join(OWNER_DIR, name);
    const st = fs.statSync(src);
    if (st.size > MAX_UPLOAD) continue;
    const file = `owner-${safe(name)}`;
    if (!fs.existsSync(path.join(DIR, file))) fs.copyFileSync(src, path.join(DIR, file));
    items.push({ file, date: day(st.mtime.toISOString()), source: "the owner's saved real-job photos", kind: "photo", shows: path.parse(name).name.replace(/[-_]+/g, " "), touched_up_with_ai: null });
  }
}

items.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.file.localeCompare(b.file)));
const cutoff = day(new Date(Date.now() - NEW_DAYS * 86_400_000).toISOString());
const fresh = items.filter((p) => p.date >= cutoff).length;

fs.writeFileSync(path.join(DIR, "manifest.json"), JSON.stringify({ generated: new Date().toISOString(), new_days: NEW_DAYS, owner_notes: ownerNotes, photos: items }, null, 2));
const ai = (p) => (p.kind === "clip" ? "a Studio clip: carries Studio's Made-with-AI note" : p.touched_up_with_ai === true ? "touched up with AI" : p.touched_up_with_ai === false ? "not marked as AI-edited" : "see the owner's notes below");
const list = [
  `REAL WORK ON THIS MAC, newest first (${items.length} files, ${fresh} from the last ${NEW_DAYS} days). Folder: ${DIR}`,
  ...items.map((p) => `- ${path.join(DIR, p.file)} | ${p.date} | ${p.kind} | ${p.source} | ${ai(p)} | ${p.shows || "not described: look at it"}`),
  ...(ownerNotes ? ["", "The owner's notes on her saved photos:", ownerNotes] : []),
  ...(items.length ? [] : ["(none: use the site photos as before)"]),
];
fs.writeFileSync(path.join(DIR, "list.txt"), `${list.join("\n")}\n`);

if (missed) console.log(`NOTE [REAL_PHOTOS_SOME_MISSED] ${missed} stored files could not be fetched this run; they are fetched again on the next run.`);
if (stop) console.log(`NAMED STOP [REAL_PHOTOS_NOT_READ] ${stop}; the run goes on with the ${items.length} real-work files already on this Mac.`);
console.log(`newest real work: ${items[0]?.date ?? "none"}`);
console.log(`real work photos: OUTPUT ${fresh} new, ${items.length} usable`);
process.exit(stop ? 2 : 0);
