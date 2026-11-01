/**
 * Read-only Gmail metadata lookup for the partner tail (scooter-watch), 6 Oct 2026.
 *
 * Domain-wide delegation impersonating her westpeek.ventures mailbox (OWNER_ADDR), `format=metadata` only
 * (From/To/Cc/Date/Subject/Message-ID headers — no body is ever fetched). Same mechanism as the
 * reader retired on 25 Sep 2026 (scooter-watch-mail.mjs.retired-2026-09-25), revived on her
 * instruction of 6 Oct 2026: mail Scooter sends her WITHOUT os@joinwestpeek.com on it is listed
 * in the digest as "went around Porter" — nothing is tailed for it.
 *
 * Run ONLY under the vault runner so GSC_SERVICE_ACCOUNT_JSON is injected by name:
 *   cd ~/GitHub/west-peek-os && node scripts/vault/vault.mjs run -- node ~/bin/scooter-watch-mail.mjs <since-ISO> [seen-file]
 *
 * Prints one JSON array of {id, gmail_id, date, from, to, cc, subject} for mail from
 * Scooter's mailbox (PARTNER_ADDR) received after <since-ISO>, oldest first. `id` is the RFC Message-ID
 * without angle brackets — the same value west-peek-os stores in inbound_message.message_id — so
 * the watch can dedupe one email seen through both sources. Gmail ids listed in [seen-file] as
 * "gm:<id>" are skipped before any metadata fetch, so the per-tick cost stays one list call.
 */
import { readFileSync as readAddrFile } from "node:fs";
import { homedir } from "node:os";
// Mail addresses live outside git (no owner emails in a public repo): ~/.config/seq-bin/addresses.env
function addr(name) {
  const f = `${homedir()}/.config/seq-bin/addresses.env`;
  let txt = "";
  try { txt = readAddrFile(f, "utf8"); } catch {}
  const m = txt.match(new RegExp(`^${name}="?([^"\\n]+)`, "m"));
  const v = process.env[name] || (m && m[1]);
  if (!v) { console.error(`STOP: ${name} not set — add it to ${f}`); process.exit(2); }
  return v;
}
const MAILBOX = addr("OWNER_ADDR");
const PARTNER = addr("PARTNER_ADDR");
const SINCE = process.argv[2];
const SEEN_FILE = process.argv[3];
if (!SINCE) {
  console.error("usage: node scooter-watch-mail.mjs <ISO-8601-since> [seen-file]");
  process.exit(2);
}
const raw = process.env.GSC_SERVICE_ACCOUNT_JSON;
if (!raw) {
  console.error("GSC_SERVICE_ACCOUNT_JSON not set — run under `node scripts/vault/vault.mjs run --` from west-peek-os");
  process.exit(2);
}
const sinceEpochSec = Math.floor(new Date(SINCE).getTime() / 1000);
if (!Number.isFinite(sinceEpochSec)) {
  console.error(`bad since: ${SINCE}`);
  process.exit(2);
}

let seen = new Set();
if (SEEN_FILE) {
  const { readFileSync, existsSync } = await import("node:fs");
  if (existsSync(SEEN_FILE)) {
    seen = new Set(readFileSync(SEEN_FILE, "utf8").split("\n").filter((l) => l.startsWith("gm:")).map((l) => l.slice(3)));
  }
}

const b64url = (buf) => Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function accessToken(creds) {
  const { createSign } = await import("node:crypto");
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: creds.client_email,
    sub: MAILBOX,
    scope: "https://www.googleapis.com/auth/gmail.readonly",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 600,
  }));
  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${claims}`);
  const jwt = `${header}.${claims}.${b64url(signer.sign(creds.private_key))}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const json = await res.json();
  if (!json.access_token) throw new Error(`token exchange failed: ${json.error ?? "?"} ${json.error_description ?? ""}`);
  return json.access_token;
}

const token = await accessToken(JSON.parse(raw));
const g = async (p) => {
  const res = await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${p}`, { headers: { authorization: `Bearer ${token}` } });
  const json = await res.json();
  if (!res.ok) throw new Error(`gmail ${p.split("?")[0]} failed: ${res.status} ${json.error?.message ?? ""}`);
  return json;
};

const q = `from:${PARTNER} after:${sinceEpochSec}`;
const list = await g(`messages?includeSpamTrash=true&maxResults=100&q=${encodeURIComponent(q)}`);

const out = [];
for (const m of list.messages ?? []) {
  if (seen.has(m.id)) continue;
  const d = await g(`messages/${m.id}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Date&metadataHeaders=Subject&metadataHeaders=Message-ID`);
  const hd = {};
  for (const h of d.payload?.headers ?? []) hd[h.name.toLowerCase()] = h.value;
  const mid = (hd["message-id"] ?? "").trim().replace(/^<|>$/g, "");
  out.push({
    id: mid || `gm:${m.id}`,
    gmail_id: m.id,
    date: d.internalDate ? new Date(Number(d.internalDate)).toISOString() : (hd.date ?? ""),
    from: hd.from ?? "",
    to: hd.to ?? "",
    cc: hd.cc ?? "",
    subject: hd.subject ?? "",
  });
}
out.sort((a, b) => new Date(a.date) - new Date(b.date));
console.log(JSON.stringify(out));
