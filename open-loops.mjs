// The ONE poster to Boss OS Open Loops for ~/bin (housekeeping.mjs and tz-watch.sh). Boss OS upserts a
// row on repo#stop; `cleared: true` closes it. Retries a 5xx once; a 4xx is final.
//
//   node open-loops.mjs '<json body>'   # posts with BOSS_OPEN_LOOPS_TOKEN; prints the action
export const OPEN_LOOPS_URL = process.env.OPEN_LOOPS_URL || "https://boss.sequoiataylor.com/api/boss/open-loops/intake";

export async function post(body, token, url = OPEN_LOOPS_URL) {
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

if (import.meta.url === `file://${process.argv[1]}`) {
  const token = process.env.BOSS_OPEN_LOOPS_TOKEN;
  if (!token) { console.error("NAMED STOP [OPEN_LOOPS_TOKEN_MISSING] BOSS_OPEN_LOOPS_TOKEN is not in the environment; nothing was posted."); process.exit(3); }
  const body = JSON.parse(process.argv[2]);
  // Tomorrow in Central, unless the caller says otherwise.
  body.next_date ??= new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago" }).format(Date.now() + 86_400_000);
  post(body, token).then((a) => console.log(a), (e) => { console.error(`NAMED STOP [OPEN_LOOPS_POST_FAILED] ${e.message}`); process.exit(9); });
}
