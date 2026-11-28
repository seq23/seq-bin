// chatgpt-searches-capture.js — the in-page capture the ChatGPT session pastes into chatgpt.com (seq-bin
// chatgpt-searches). The runner fills __CFG__ (site, questions, our domains and names) and hands the whole text to
// the session, which must paste it unchanged: the runner compares every install call in the event stream with
// this text and refuses a night's captures from any other script. Everything the report says about a chat comes
// from what this code returns (searches from the answer stream, sites from its search results and citations, the
// request ChatGPT received), never from the session's own retelling.
//
// The Claude in Chrome tool returns about 1000 characters and refuses text that looks like a query string, so
// every result is JSON with = & ? < > escaped, cut into 700-character chunks: CSQ1|<n>|<i>|<of>|<chunk>.
(() => {
  const CFG = __CFG__;
  const W = window;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const esc = (o) => JSON.stringify(o).replace(/[=&?<>]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
  if (!W.__csqS) {
    const of = W.fetch;
    W.__csqS = [];
    W.fetch = async function (...a) {
      const res = await of.apply(this, a);
      try {
        const u = String((a[0] && a[0].url) || a[0]).split("?")[0];
        if (/\/backend-api\/(f\/)?conversation$/.test(u)) {
          let body = null;
          try { body = a[1] && typeof a[1].body === "string" ? a[1].body : null; } catch (e) { body = null; }
          const rec = { status: res.status, body, t: "", end: false };
          W.__csqS.push(rec);
          const c = res.clone();
          if ((res.headers.get("content-type") || "").includes("event-stream")) {
            (async () => {
              const rd = c.body.getReader(); const dec = new TextDecoder();
              for (;;) { const { done, value } = await rd.read(); if (done) break; rec.t += dec.decode(value, { stream: true }); }
              rec.end = true;
            })().catch(() => { rec.end = true; });
          } else c.text().then((x) => { rec.t = x; rec.end = true; }).catch(() => { rec.end = true; });
        }
      } catch (e) { /* the page's own request is never touched */ }
      return res;
    };
  }
  W.__csqQ = W.__csqQ || {};
  W.__csqR = {};
  const LIMIT_RE = /temporary limit|you've reached|you have reached|too many requests|usage cap|limit resets/i;
  const composer = () => document.querySelector('div.ProseMirror[contenteditable="true"]');
  const signedIn = () => !!document.querySelector('[aria-label="Open profile menu"], [data-testid="accounts-profile-button"]');
  const pageText = () => ((document.querySelector("main") || document.body || {}).innerText) || "";
  const complete = (rec) => rec.end || /"type":\s*"message_stream_complete"|\ndata: \[DONE\]/.test(rec.t);
  function state() {
    if (!/(^|[?&])temporary-chat=true/.test(location.search.slice(1))) return "NOT_TEMP";
    if (!signedIn()) return "SIGNED_OUT";
    if (!composer()) return "NO_COMPOSER";
    if (LIMIT_RE.test(pageText())) return "LIMIT";
    return "READY";
  }
  function answerText() {
    const els = [...document.querySelectorAll('[data-dil-response], [data-message-author-role="assistant"], .markdown')]
      .filter((e) => (e.innerText || "").trim().length > 50);
    return els.length ? els[els.length - 1].innerText : "";
  }
  const strip = (u) => String(u).replace(/^https?:\/\/(www\.)?/i, "").replace(/[?#].*$/, "").replace(/\/$/, "");
  const host = (u) => strip(u).split("/")[0].toLowerCase();
  function parse(rec) {
    const queries = [], read = new Set(), cited = new Set();
    const addQ = (q) => { if (typeof q === "string" && q.trim() && !queries.includes(q.trim())) queries.push(q.trim()); };
    const ctxOf = (k) => (/search_result_groups/.test(k) ? "read" : /content_references|safe_urls|citations/.test(k) ? "cited" : null);
    const walk = (o, ctx) => {
      if (typeof o === "string") { if (ctx && /^https?:\/\//.test(o)) (ctx === "read" ? read : cited).add(strip(o)); return; }
      if (!o || typeof o !== "object") return;
      if (Array.isArray(o)) { for (const x of o) walk(x, ctx); return; }
      if (typeof o.p === "string" && "v" in o) {
        if (/search_model_queries/.test(o.p)) { const v = o.v; (Array.isArray(v) ? v : (v && v.queries) || [v]).forEach(addQ); }
        walk(o.v, ctxOf(o.p) || ctx);
      }
      for (const [k, v] of Object.entries(o)) {
        if (k === "p" || (k === "v" && typeof o.p === "string")) continue;
        if (k === "search_model_queries" && v && Array.isArray(v.queries)) v.queries.forEach(addQ);
        walk(v, ctxOf(k) || ctx);
      }
    };
    for (const line of rec.t.split("\n")) {
      if (!line.startsWith("data: ") || line === "data: [DONE]") continue;
      try { walk(JSON.parse(line.slice(6)), null); } catch (e) { /* a keep-alive or a cut line */ }
    }
    // A link streams in pieces ("apps.apple.c", then the rest): keep only whole ones, and never ChatGPT's own hosts.
    const whole = (set) => { const a = [...set].filter((u) => !/(^|\.)(openai\.com|chatgpt\.com|oaiusercontent\.com)$/.test(host(u))); return a.filter((u) => !a.some((o) => o !== u && o.startsWith(u))); };
    return { queries, read: whole(read), cited: whole(cited) };
  }
  function build(n) {
    const rec = W.__csqS[W.__csqQ[n]];
    if (!rec) return { q: n, error: "NO_REQUEST" };
    let b = {};
    try { b = JSON.parse(rec.body || "{}"); } catch (e) { b = {}; }
    const parts = (((b.messages || [])[0] || {}).content || {}).parts || [];
    const sent = parts.filter((p) => typeof p === "string").join(" ");
    const cid = (rec.t.match(/"conversation_id":\s*"([0-9a-f-]{36})"/) || [])[1] || null;
    const msc = rec.t.match(/"model_set_context":\s*"((?:[^"\\]|\\.)*)"/);
    const slug = (rec.t.match(/"resolved_model_slug":\s*"([^"]+)"/) || [])[1] || null;
    const { queries, read, cited } = parse(rec);
    const text = answerText();
    const lower = text.toLowerCase();
    const ours = CFG.ours.domains.map((d) => d.toLowerCase());
    const mine = (u) => ours.some((d) => host(u) === d || host(u).endsWith("." + d));
    const readDomains = [...new Set(read.map(host))];
    return {
      q: n, site: CFG.site, sent, asked: CFG.qs[n - 1], cid, status: rec.status, complete: complete(rec),
      temporary: b.history_and_training_disabled === true, memory: msc ? (msc[1] ? "present" : "empty") : "unknown",
      search_on: Array.isArray(b.system_hints) && b.system_hints.includes("search"), model: slug || b.model || null,
      queries, read_pages: read.length, read_domains: readDomains.slice(0, 40), read_domains_total: readDomains.length,
      cited: cited.slice(0, 25).map((u) => u.slice(0, 110)), cited_total: cited.length,
      ours_read: read.filter(mine).slice(0, 5), ours_cited: cited.filter(mine).slice(0, 5),
      ours_named: CFG.ours.names.filter((x) => lower.includes(x.toLowerCase())).concat(CFG.ours.domains.filter((d) => lower.includes(d.toLowerCase()))),
      answer_chars: text.length,
    };
  }
  W.__csq = {
    state: () => "CSQS|" + state(),
    ask: async (n) => {
      let st = state();
      for (let i = 0; i < 30 && st === "NO_COMPOSER"; i++) { await sleep(500); st = state(); }
      if (st !== "READY") return "CSQA|" + n + "|" + st;
      const q = CFG.qs[n - 1];
      if (!q) return "CSQA|" + n + "|NO_SUCH_QUESTION";
      const ed = composer(); ed.focus();
      document.execCommand("insertText", false, q);
      await sleep(600);
      if (!ed.innerText.includes(q)) return "CSQA|" + n + "|NOT_TYPED";
      const send = document.querySelector('button[data-testid="send-button"], button[aria-label="Send"]');
      if (!send || send.disabled) return "CSQA|" + n + "|NO_SEND_BUTTON";
      const before = W.__csqS.length;
      send.click();
      for (let i = 0; i < 20 && W.__csqS.length === before; i++) await sleep(400);
      if (W.__csqS.length === before) return "CSQA|" + n + "|NOT_SENT";
      W.__csqQ[n] = W.__csqS.length - 1;
      return "CSQA|" + n + "|SENT";
    },
    wait: async (n) => {
      const rec = W.__csqS[W.__csqQ[n]];
      if (!rec) return "CSQW|" + n + "|NO_REQUEST";
      for (let i = 0; i < 36; i++) {
        if (rec.status === 429) return "CSQW|" + n + "|LIMIT";
        if (rec.status !== 200) return "CSQW|" + n + "|HTTP_" + rec.status;
        if (complete(rec)) { await sleep(1500); return "CSQW|" + n + "|DONE"; }
        await sleep(1000);
      }
      if (LIMIT_RE.test(pageText())) return "CSQW|" + n + "|LIMIT";
      return "CSQW|" + n + "|RUNNING";
    },
    out: (n, i) => {
      if (!W.__csqR[n]) W.__csqR[n] = esc(build(n));
      const s = W.__csqR[n], size = 700, of = Math.max(1, Math.ceil(s.length / size));
      if (i < 0 || i >= of) return "CSQ1|" + n + "|" + i + "|" + of + "|";
      return "CSQ1|" + n + "|" + i + "|" + of + "|" + s.slice(i * size, (i + 1) * size);
    },
    names: (n, list) => {
      const lower = answerText().toLowerCase();
      const got = (Array.isArray(list) ? list : []).map((x) => String(x).trim()).filter((x) => x.length >= 2 && x.length <= 60).slice(0, 14);
      return "CSQN|" + n + "|" + esc({ named: got.filter((x) => lower.includes(x.toLowerCase())), rejected: got.filter((x) => !lower.includes(x.toLowerCase())), answer_chars: lower.length });
    },
  };
  return "CSQ-READY|" + CFG.site + "|" + CFG.qs.length + "|" + state();
})();
