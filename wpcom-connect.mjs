#!/usr/bin/env node
// wpcom-connect.mjs — one-time "Approve" sign-in for a WordPress.com account, so a job can post by itself.
//
//   cd ~/GitHub/boss-os && npm run -s vault:run -- node ~/bin/wpcom-connect.mjs <prefix>
//   prefix: founder   (hello@founderoperatorlibrary.com: the 3 library sites)  -> WPCOM_FOUNDER_*
//           kmp       (the KeepMyProof account: keepmyproof.wordpress.com)     -> KMP_WPCOM_*
//
// Why not an application password: WordPress.com only offers them with two-step login on (8 Nov 2026).
// The authorization-code flow gives a token that does not expire, with no password stored anywhere.
// Before running: create an app at developer.wordpress.com/apps/new in THAT account, Type "Web",
// Redirect URL exactly  http://localhost:8765/wpcom-callback
// Asks for the Client ID and Secret in macOS pop-ups (secret hidden), opens the Approve page in Chrome,
// proves the token by listing the account's sites, saves 3 values to the vault. Prints no secret.
import http from 'node:http';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const PREFIX = { founder: 'WPCOM_FOUNDER_', kmp: 'KMP_WPCOM_' }[process.argv[2]];
const fail = (m) => { console.log(`NAMED STOP [WPCOM_CONNECT] ${m}`); process.exit(2); };
if (!PREFIX) fail('say which account: founder or kmp.');
const PORT = 8765, REDIRECT = `http://localhost:${PORT}/wpcom-callback`;

function ask(label, hidden) {
  const script = `display dialog ${JSON.stringify(label)} default answer "" ${hidden ? 'with hidden answer ' : ''}buttons {"Cancel","OK"} default button "OK" with title "WordPress connect"`;
  let out;
  try { out = execFileSync('osascript', ['-e', script, '-e', 'text returned of result'], { encoding: 'utf8' }); }
  catch { fail('cancelled.'); }
  const v = out.replace(/\n$/, '').trim();
  if (!v) fail(`${label}: nothing entered.`);
  return v;
}
function save(name, value) {
  execFileSync('npm', ['run', '-s', 'vault:set', name], { cwd: `${process.env.HOME}/GitHub/boss-os`, input: value, stdio: ['pipe', 'ignore', 'inherit'] });
  console.log(`saved to the vault as ${name}`);
}

const clientId = ask('WordPress.com app: Client ID (a number)', false);
if (!/^\d+$/.test(clientId)) fail('the Client ID is a number; copy it from the app page.');
const clientSecret = ask('WordPress.com app: Client Secret', true);
const state = crypto.randomBytes(16).toString('hex');

const code = await new Promise((resolve, reject) => {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, REDIRECT);
    if (u.pathname !== '/wpcom-callback') { res.writeHead(404).end(); return; }
    const ok = u.searchParams.get('state') === state && u.searchParams.get('code');
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
      .end(ok ? '<p style="font:18px system-ui">Connected. You can close this tab.</p>' : '<p style="font:18px system-ui">Not connected. Close this tab and run it again.</p>');
    server.close();
    ok ? resolve(u.searchParams.get('code')) : reject(new Error(u.searchParams.get('error') || 'no code'));
  }).listen(PORT, '127.0.0.1', () => {
    const auth = new URL('https://public-api.wordpress.com/oauth2/authorize');
    Object.entries({ client_id: clientId, redirect_uri: REDIRECT, response_type: 'code', scope: 'global', state })
      .forEach(([k, v]) => auth.searchParams.set(k, v));
    execFileSync('open', ['-a', 'Google Chrome', auth.toString()]);
    console.log('Opened the Approve page in Chrome. Waiting up to 10 minutes...');
  });
  setTimeout(() => { server.close(); reject(new Error('no Approve click within 10 minutes')); }, 600000).unref();
}).catch((e) => fail(e.message));

const tokRes = await fetch('https://public-api.wordpress.com/oauth2/token', { method: 'POST',
  headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, redirect_uri: REDIRECT, grant_type: 'authorization_code', code }) });
const tok = await tokRes.json().catch(() => ({}));
if (!tokRes.ok || !tok.access_token) fail(`WordPress.com refused (${tokRes.status} ${tok.error ?? ''}). Check the Client Secret and the Redirect URL on the app page.`);
const sitesRes = await fetch('https://public-api.wordpress.com/rest/v1.1/me/sites?fields=ID,URL', { headers: { authorization: `Bearer ${tok.access_token}` } });
const sites = (await sitesRes.json().catch(() => ({}))).sites ?? [];
if (!sitesRes.ok || sites.length === 0) fail(`the token works but sees no sites (${sitesRes.status}).`);
save(`${PREFIX}CLIENT_ID`, clientId);
save(`${PREFIX}CLIENT_SECRET`, clientSecret);
save(`${PREFIX}ACCESS_TOKEN`, tok.access_token);
console.log(`OUTPUT connected ${process.argv[2]}: ${sites.length} site(s): ${sites.map((s) => s.URL.replace(/^https?:\/\//, '')).join(', ')}`);
