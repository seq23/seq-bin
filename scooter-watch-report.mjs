/**
 * Partner-tail report sender (scooter-watch), 6 Oct 2026.
 *
 * Sends one plain-text email through Resend's API from os@westpeek.ventures (the west-peek-os
 * Worker's existing sender, wrangler.toml WP_OS_EMAIL_FROM) to her westpeek.ventures mailbox (OWNER_ADDR).
 *
 * Run ONLY under the vault runner so RESEND_API_KEY is injected by name and never crosses a
 * command line or a log:
 *   cd ~/GitHub/west-peek-os && node scripts/vault/vault.mjs run -- node ~/bin/scooter-watch-report.mjs <report-file> [subject]
 *
 * <report-file>  plain text; becomes the body verbatim.
 * [subject]      optional; defaults to "Partner tail: <first line of the file>".
 *
 * Prints "sent id=<resend id>" on success and exits 0; prints the provider's status/message and
 * exits 1 otherwise. The key is read from process.env inside this file and appears nowhere else.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
// Mail addresses live outside git (no owner emails in a public repo): ~/.config/seq-bin/addresses.env
function addr(name) {
  const f = `${homedir()}/.config/seq-bin/addresses.env`;
  let txt = "";
  try { txt = readFileSync(f, "utf8"); } catch {}
  const m = txt.match(new RegExp(`^${name}="?([^"\\n]+)`, "m"));
  const v = process.env[name] || (m && m[1]);
  if (!v) { console.error(`STOP: ${name} not set — add it to ${f}`); process.exit(2); }
  return v;
}


const FROM = "os@westpeek.ventures";
const TO = addr("OWNER_ADDR");
const ENDPOINT = "https://api.resend.com/emails";

const file = process.argv[2];
if (!file) {
  console.error("usage: node scooter-watch-report.mjs <report-file> [subject]");
  process.exit(2);
}
const key = process.env.RESEND_API_KEY;
if (!key) {
  console.error("RESEND_API_KEY not set — run under `node scripts/vault/vault.mjs run --` from west-peek-os");
  process.exit(2);
}
const text = readFileSync(file, "utf8");
const firstLine = text.split("\n").find((l) => l.trim()) ?? "report";
const subject = (process.argv[3] && process.argv[3].trim()) || `Partner tail: ${firstLine.trim().slice(0, 120)}`;

const ctl = new AbortController();
const timer = setTimeout(() => ctl.abort(), 15_000);
let res, body;
try {
  res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [TO], subject, text }),
    signal: ctl.signal,
  });
  body = await res.json().catch(() => ({}));
} finally {
  clearTimeout(timer);
}
if (!res.ok || !body?.id) {
  console.error(`resend ${res?.status ?? "?"}: ${body?.message ?? body?.name ?? "no id returned"}`);
  process.exit(1);
}
console.log(`sent id=${body.id} to=${TO} subject=${JSON.stringify(subject)}`);
