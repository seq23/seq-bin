// The ONE poster to Boss OS Open Loops for ~/bin (housekeeping.mjs and tz-watch.sh). Boss OS upserts a
// row on repo#stop; `cleared: true` closes it. Retries a 5xx once; a 4xx is final.
//
//   node open-loops.mjs '<json body>'   # posts with BOSS_OPEN_LOOPS_TOKEN; prints the action
//   An open row carries next_date "today" | "tomorrow" | YYYY-MM-DD (Central); there is no default.
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const OPEN_LOOPS_URL = process.env.OPEN_LOOPS_URL || "https://boss.sequoiataylor.com/api/boss/open-loops/intake";

// Which day a row is due, in Central. A row that opens must say "today", "tomorrow" or a YYYY-MM-DD; there is
// no default (22 Nov 2026: a default of tomorrow put every land failure on Monday's list, fixable that day).
// A closing post (`cleared: true`) needs none. Returns the resolved body, or throws.
export function withDay(body, now = Date.now()) {
  if (body.cleared === true) return body;
  const ct = (ms) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago" }).format(ms);
  const d = body.next_date;
  const day = d === "today" ? ct(now) : d === "tomorrow" ? ct(now + 86_400_000) : d;
  if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day)) {
    throw new Error(`NAMED STOP [OPEN_LOOPS_NO_DAY] the row ${body.stop ?? "?"} names no day (next_date "today", "tomorrow" or YYYY-MM-DD); nothing was posted`);
  }
  return { ...body, next_date: day };
}

export async function post(body, token, url = OPEN_LOOPS_URL) {
  body = withDay(body);
  for (let attempt = 1; ; attempt++) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
      const text = await r.text();
      if (r.ok) { try { return JSON.parse(text).action ?? JSON.parse(text).data?.action ?? "ok"; } catch { return "ok"; } }
      if (r.status < 500 || attempt >= 2) throw new Error(`HTTP ${r.status}`);
    } catch (e) {
      if (attempt >= 2 || /^HTTP 4/.test(e.message)) throw e;
    }
  }
}

// Run as a script whatever path it was called by: a symlinked dir (macOS /var -> /private/var) made the
// plain URL compare false, and the poster exited 0 having posted nothing (21 Nov 2026).
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const token = process.env.BOSS_OPEN_LOOPS_TOKEN;
  if (!token) { console.error("NAMED STOP [OPEN_LOOPS_TOKEN_MISSING] BOSS_OPEN_LOOPS_TOKEN is not in the environment; nothing was posted."); process.exit(3); }
  const body = JSON.parse(process.argv[2]);
  try { withDay(body); } catch (e) { console.error(e.message); process.exit(2); }
  post(body, token).then((a) => console.log(a), (e) => { console.error(`NAMED STOP [OPEN_LOOPS_POST_FAILED] ${e.message}`); process.exit(9); });
}
