// One Google access token from a service account key (the JWT-bearer exchange), no libraries.
// The key comes from the Boss OS vault as JSON in an environment variable; nothing is printed.
import crypto from 'node:crypto';

/** An access token for `scope`, or '' when the env var is empty. Throws when Google refuses, with its reply. */
export async function googleAccessToken(envName, scope, fetchFn = fetch) {
  const raw = process.env[envName];
  if (!raw) return '';
  const info = JSON.parse(raw);
  if (!info.client_email || !info.private_key) throw Error(`${envName} is not a service account key`);
  const b64 = v => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');
  const iat = Math.floor(Date.now() / 1000);
  const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({ iss: info.client_email, scope, aud: 'https://oauth2.googleapis.com/token', iat, exp: iat + 3600 })}`;
  const sig = crypto.createSign('RSA-SHA256').update(unsigned).end().sign(String(info.private_key).replace(/\\n/g, '\n')).toString('base64url');
  const r = await fetchFn('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${sig}` }) });
  const text = await r.text();
  if (!r.ok) throw Error(`token ${r.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text).access_token ?? '';
}
