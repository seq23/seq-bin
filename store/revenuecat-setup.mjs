// Creates or checks one app's RevenueCat setup from a catalog module in the app's own repo
// (apps/mobile/scripts/revenuecat/setup.ts exports `catalog`). Every app runs this one file.
// Idempotent: anything that already exists is reused; a product whose type differs from the code is
// corrected (the type only changes how RevenueCat treats the product, never the store). Run with the
// project's v2 secret key injected by the Boss OS vault (never on a command line, never in git):
//   cd ~/GitHub/boss-os && npm run -s vault:run -- ~/bin/revenuecat-setup <repo>/apps/mobile/scripts/revenuecat/setup.ts
// Flags: --dry-run reads RevenueCat, prints what differs from the code and changes nothing; --save-keys
// pipes each public SDK key into the vault as REVENUECAT_<APP>_{IOS,ANDROID,TEST}_PUBLIC_KEY (values are
// never printed).
//
// A failed read is "unknown", never "empty": the first failure of any kind (5xx, 429 after retries, a
// network error, a reply that is not JSON, 401/403) stops the run before any further write, so an outage
// can never make a second app, product, entitlement or offering. A re-run is the retry.
// Prints one OUTPUT line, last. Exit 0 = RevenueCat matches the code; 1 = a failure, or drift left
// (a dry run that finds drift); 2 = a NAMED STOP in the setup (no key, wrong project);
// 3 = NAMED STOP [RC_KEY_READ_ONLY] / [RC_KEY_DENIED], a key only the owner can change.
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const API = 'https://api.revenuecat.com/v2';
const STORE_SLOT = { app_store: 'IOS', play_store: 'ANDROID', test_store: 'TEST' };

/**
 * The RevenueCat product type, the same on every store: the code's own kind. Never `one_time`: on Google
 * Play RevenueCat consumes every one-time purchase not marked non_consumable, so a buyer who reinstalls
 * or changes phone gets nothing back from restore (22 Nov 2026, every Play product had been one_time).
 */
export function storeType(appType, kind) {
  if (kind !== 'consumable' && kind !== 'non_consumable') throw Error(`product kind must be consumable or non_consumable, not ${kind}`);
  return kind;
}

/** Every object the catalog needs, as plain lines (also the --dry-run output). */
export function plan(c) {
  const lines = [`apps: app_store ${c.bundleId}, play_store ${c.bundleId}, test_store`];
  for (const p of c.products) lines.push(`product ${p.id} (${p.kind}) on app_store, play_store, test_store`);
  for (const e of c.entitlements) lines.push(`entitlement ${e.key} <- ${e.products.join(', ')}`);
  for (const o of c.offerings) lines.push(`offering ${o.key}${o.current ? ' (current)' : ''}: ${o.packages.join(' > ')}`);
  return lines;
}

/** What is missing or wrong in RevenueCat, compared with the catalog. Empty = matches the code. */
export function diff(c, live) {
  const out = [];
  for (const t of ['app_store', 'play_store', 'test_store']) if (!live.apps.some(a => a.type === t)) out.push(`app ${t} missing`);
  for (const a of live.apps.filter(a => a.type !== 'test_store' && STORE_SLOT[a.type])) {
    const id = a.app_store?.bundle_id ?? a.play_store?.package_name;
    if (id !== c.bundleId) out.push(`app ${a.type} bundle ${id} != ${c.bundleId}`);
  }
  for (const p of c.products) for (const a of live.apps.filter(a => STORE_SLOT[a.type])) {
    const x = live.products.find(x => x.app_id === a.id && x.store_identifier === p.id);
    if (!x) out.push(`product ${p.id} missing on ${a.type}`);
    else if (x.type !== storeType(a.type, p.kind)) out.push(`product ${p.id} on ${a.type} is ${x.type}, code says ${storeType(a.type, p.kind)}`);
  }
  for (const e of c.entitlements) {
    const have = live.entitlementProducts[e.key];
    if (!have) { out.push(`entitlement ${e.key} missing`); continue; }
    for (const id of e.products) if (!have.includes(id)) out.push(`entitlement ${e.key} lacks ${id}`);
  }
  for (const o of c.offerings) {
    const pk = live.offeringPackages[o.key];
    if (!pk) { out.push(`offering ${o.key} missing`); continue; }
    if (o.current && !live.currentOffering?.includes(o.key)) out.push(`offering ${o.key} is not current`);
    for (const id of o.packages) {
      const p = pk.find(x => x.key === id);
      if (!p) out.push(`offering ${o.key} package ${id} missing`);
      else if (!p.products.includes(id)) out.push(`offering ${o.key} package ${id} has no ${id} product`);
    }
    // The paywall order: positions strictly rising in catalog order (a tie leaves the order to chance).
    const pos = o.packages.map(id => pk.find(x => x.key === id)?.position);
    if (pos.every(n => n != null) && pos.some((n, i) => i > 0 && n <= pos[i - 1])) out.push(`offering ${o.key} positions ${pos.join(',')} do not follow ${o.packages.join(' > ')}`);
  }
  return out;
}

/** Thrown by `client` on the first failure; carries the line to print and the exit code. */
class Halt extends Error { constructor(line, code = 1) { super(line); this.line = line; this.code = code; } }

/** RevenueCat v2 calls with one key. Any failure throws Halt, so nothing runs on top of a failed read. */
function client(c, key) {
  const st = { writes: 0 };
  const call = async (method, path, body) => {
    const where = `${method} ${path.split('?')[0]}`;
    for (let attempt = 0; ; attempt++) {
      let r;
      try { r = await globalThis.fetch(API + path, { method, headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined }); }
      catch (e) { throw new Halt(`FAILED RC_UNAVAILABLE RevenueCat unavailable (network) ${where}: ${String(e?.cause?.code ?? e?.message ?? e).slice(0, 200)}`); }
      if (r.status === 429 && attempt < 5) { await new Promise(res => setTimeout(res, 1000 * (attempt + 1))); continue; }
      const text = await r.text().catch(() => '');
      let j;
      try { j = text ? JSON.parse(text) : {}; } catch { j = undefined; }
      const said = String(j?.message ?? text).slice(0, 300);
      if (r.status === 401 || r.status === 403) throw new Halt(method === 'GET'
        ? `NAMED STOP [RC_KEY_DENIED] ${c.secretEnv} cannot read this project (${where}: ${r.status} ${said}). RevenueCat > Project settings > API keys: a v2 secret key with Project configuration read access.`
        : `NAMED STOP [RC_KEY_READ_ONLY] ${c.secretEnv} cannot write (${where}: ${r.status} ${said}). RevenueCat > Project settings > API keys: give that v2 secret key Project configuration: Read & write.`, 3);
      if (r.status >= 500 || r.status === 429) throw new Halt(`FAILED RC_UNAVAILABLE RevenueCat unavailable ${where}: ${r.status} ${said}`);
      if (!r.ok) throw new Halt(`FAILED RC_API_${r.status} ${where}: ${said}`);
      if (j === undefined) throw new Halt(`FAILED RC_BAD_REPLY ${where}: ${r.status} but not JSON: ${text.slice(0, 200)}`);
      if (method !== 'GET') st.writes++;
      return j;
    }
  };
  /** Every item of a list, following next_page. Never [] for a list that could not be read (it throws). */
  const list = async path => {
    const all = [];
    let next = `${path}${path.includes('?') ? '&' : '?'}limit=100`;
    while (next) {
      const j = await call('GET', next);
      if (!Array.isArray(j?.items)) throw new Halt(`FAILED RC_BAD_REPLY GET ${path}: no items list`);
      all.push(...j.items);
      next = j.next_page ? String(j.next_page).replace(/^\/v2/, '') : '';
    }
    return all;
  };
  return { call, list, st };
}

/** The one project the key opens, as its path. */
async function openProject(c, list) {
  const projects = await list('/projects');
  if (projects.length !== 1) throw new Halt(`NAMED STOP [REVENUECAT_PROJECT_UNCLEAR] ${c.secretEnv} opens ${projects.length} projects, want 1`, 2);
  if (c.projectName && projects[0].name !== c.projectName) throw new Halt(`NAMED STOP [REVENUECAT_WRONG_PROJECT] ${c.secretEnv} opens "${projects[0].name}", want "${c.projectName}"`, 2);
  return `/projects/${projects[0].id}`;
}

/** Everything diff() compares, read from RevenueCat. */
async function readLive(P, list) {
  const apps = (await list(`${P}/apps`)).filter(a => STORE_SLOT[a.type]);
  const products = await list(`${P}/products`);
  const offerings = await list(`${P}/offerings`);
  const ents = await list(`${P}/entitlements`);
  const byId = Object.fromEntries(products.map(x => [x.id, x.store_identifier]));
  const live = { apps, products, entitlementProducts: {}, offeringPackages: {}, currentOffering: offerings.filter(o => o.is_current).map(o => o.lookup_key) };
  for (const e of ents) live.entitlementProducts[e.lookup_key] = (await list(`${P}/entitlements/${e.id}/products`)).map(x => x.store_identifier);
  for (const o of offerings) {
    live.offeringPackages[o.lookup_key] = [];
    for (const p of await list(`${P}/offerings/${o.id}/packages`)) live.offeringPackages[o.lookup_key].push({
      key: p.lookup_key, position: p.position, products: (await list(`${P}/packages/${p.id}/products`)).map(x => byId[x.product?.id ?? x.id]) });
  }
  return live;
}

/**
 * For play-products, before it writes to Play: is every catalog product on RevenueCat's play_store app,
 * with the code's type? Until it is, a Play sale could be consumed (one_time) or unknown to the app.
 * Returns { ok: true } or { ok: false, why, code }: code 1 = RevenueCat could not be read (FAILED, an outage),
 * 2 = a NAMED STOP, 3 = a key only the owner can change. Read-only.
 */
export async function playTypesReady(c) {
  if (!c?.secretEnv || !c?.products?.length) return { ok: false, code: 2, why: 'NAMED STOP [RC_CATALOG_MISSING] the Play catalog names no RevenueCat catalog (catalog.revenuecat)' };
  const key = process.env[c.secretEnv];
  if (!key) return { ok: false, code: 2, why: `NAMED STOP [REVENUECAT_SECRET_MISSING] ${c.secretEnv} is not in the vault` };
  try {
    const { list } = client(c, key);
    const P = await openProject(c, list);
    const play = (await list(`${P}/apps`)).filter(a => a.type === 'play_store');
    if (play.length !== 1) return { ok: false, code: 2, why: `NAMED STOP [RC_TYPES_NOT_READY] RevenueCat has ${play.length} Play apps, want 1` };
    const products = (await list(`${P}/products`)).filter(x => x.app_id === play[0].id);
    const wrong = c.products.flatMap(p => {
      const x = products.find(x => x.store_identifier === p.id);
      return !x ? [`${p.id} missing`] : x.type !== storeType('play_store', p.kind) ? [`${p.id} is ${x.type}, code says ${p.kind}`] : [];
    });
    return wrong.length ? { ok: false, code: 2, why: `NAMED STOP [RC_TYPES_NOT_READY] RevenueCat's Play products do not match the code yet (run ~/bin/revenuecat-setup first): ${wrong.join('; ')}` } : { ok: true };
  } catch (e) {
    if (e instanceof Halt) return { ok: false, code: e.code, why: e.code === 1 ? `${e.line} (could not confirm RevenueCat's Play product types)` : e.line };
    throw e;
  }
}

export async function run(c, argv = process.argv.slice(2)) {
  const tag = `OUTPUT revenuecat-setup ${c.app}`;
  const key = process.env[c.secretEnv];
  if (!key) { console.log(`${tag}: NAMED STOP [REVENUECAT_SECRET_MISSING] ${c.secretEnv} is not in the vault`); return 2; }
  const { call, list, st } = client(c, key);
  const errors = [];
  try {
    const P = await openProject(c, list);
    if (argv.includes('--dry-run')) {
      const drift = diff(c, await readLive(P, list));
      for (const l of drift) console.log(`would fix: ${l}`);
      console.log(`${tag}: dry run, ${drift.length ? `${drift.length} differences from the code (run without --dry-run to fix them)` : 'RevenueCat matches the code'}; nothing changed`);
      return drift.length ? 1 : 0;
    }

    // Apps
    let apps = await list(`${P}/apps`);
    const wantApps = [
      { type: 'app_store', name: `${c.app} (iOS)`, app_store: { bundle_id: c.bundleId } },
      { type: 'play_store', name: `${c.app} (Android)`, play_store: { package_name: c.bundleId } },
    ];
    for (const w of wantApps) if (!apps.some(a => a.type === w.type)) await call('POST', `${P}/apps`, w);
    apps = (await list(`${P}/apps`)).filter(a => STORE_SLOT[a.type]);

    // Products, one per store app
    let products = await list(`${P}/products`);
    for (const p of c.products) for (const a of apps) {
      if (products.some(x => x.app_id === a.id && x.store_identifier === p.id)) continue;
      const body = { store_identifier: p.id, app_id: a.id, type: storeType(a.type, p.kind), display_name: p.name };
      if (a.type === 'test_store') body.title = p.name;
      await call('POST', `${P}/products`, body);
    }
    products = await list(`${P}/products`);
    // A product made with the wrong type (before 22 Nov 2026: one_time on Play) is corrected in place.
    for (const x of products) {
      const p = c.products.find(p => p.id === x.store_identifier);
      const a = apps.find(a => a.id === x.app_id);
      if (p && a && x.type !== storeType(a.type, p.kind)) {
        await call('POST', `${P}/products/${x.id}`, { type: storeType(a.type, p.kind) });
        console.log(`type ${p.id} on ${a.type}: ${x.type} -> ${storeType(a.type, p.kind)}`);
      }
    }
    products = await list(`${P}/products`);
    const idsFor = sid => products.filter(x => x.store_identifier === sid).map(x => x.id);

    // Entitlements
    const ents = await list(`${P}/entitlements`);
    for (const e of c.entitlements) {
      const ent = ents.find(x => x.lookup_key === e.key) ?? await call('POST', `${P}/entitlements`, { lookup_key: e.key, display_name: e.name });
      const have = (await list(`${P}/entitlements/${ent.id}/products`)).map(x => x.id);
      const add = e.products.flatMap(idsFor).filter(id => !have.includes(id));
      if (add.length) await call('POST', `${P}/entitlements/${ent.id}/actions/attach_products`, { product_ids: add });
    }

    // Offerings and packages, in the order the paywall shows them
    const offerings = await list(`${P}/offerings`);
    for (const o of c.offerings) {
      const off = offerings.find(x => x.lookup_key === o.key) ?? await call('POST', `${P}/offerings`, { lookup_key: o.key, display_name: o.name });
      const pkgs = await list(`${P}/offerings/${off.id}/packages`);
      for (const [i, sid] of o.packages.entries()) {
        const pkg = pkgs.find(x => x.lookup_key === sid) ?? await call('POST', `${P}/offerings/${off.id}/packages`, { lookup_key: sid, display_name: c.products.find(p => p.id === sid)?.name ?? sid, position: i + 1 });
        const have = (await list(`${P}/packages/${pkg.id}/products`)).map(x => x.product?.id ?? x.id);
        const add = idsFor(sid).filter(id => !have.includes(id));
        if (add.length) await call('POST', `${P}/packages/${pkg.id}/actions/attach_products`, { products: add.map(product_id => ({ product_id, eligibility_criteria: 'all' })) });
      }
      // RevenueCat keeps neither the position given at creation nor a forward pass of updates (it
      // shifts the others); setting every position from the last package back to the first holds.
      const now = await list(`${P}/offerings/${off.id}/packages`);
      if (o.packages.some((sid, i) => now.find(x => x.lookup_key === sid)?.position !== i + 1))
        for (const [i, sid] of [...o.packages.entries()].reverse()) {
          const pkg = now.find(x => x.lookup_key === sid);
          if (pkg) await call('POST', `${P}/packages/${pkg.id}`, { position: i + 1 });
        }
      if (o.current && !off.is_current) await call('POST', `${P}/offerings/${off.id}`, { is_current: true });
    }

    // Read everything back and compare with the code
    const live = await readLive(P, list);
    const missing = diff(c, live);

    // Public SDK keys into the vault, values never printed
    const saved = [];
    if (argv.includes('--save-keys')) for (const a of live.apps) {
      const k = (await list(`${P}/apps/${a.id}/public_api_keys`))[0]?.key;
      const name = `REVENUECAT_${c.vaultPrefix}_${STORE_SLOT[a.type]}_PUBLIC_KEY`;
      if (!k) { errors.push(`FAILED RC_NO_PUBLIC_KEY ${a.type}`); continue; }
      const r = spawnSync('npm', ['run', '-s', 'vault:set', name], { input: k, cwd: process.env.BOSS_OS_DIR ?? `${homedir()}/GitHub/boss-os`, encoding: 'utf8' });
      if (r.status === 0) saved.push(name); else errors.push(`FAILED VAULT_SET ${name}`);
    }
    for (const l of [...errors, ...missing]) console.log(l);
    console.log(`${tag}: ${live.apps.length} apps, ${c.products.length} products x ${live.apps.length}, ${c.entitlements.length} entitlements, ${c.offerings.length} offerings; ${missing.length} mismatches, ${errors.length} errors${saved.length ? `; saved to the vault as ${saved.join(', ')}` : ''}`);
    return errors.length || missing.length ? 1 : 0;
  } catch (e) {
    if (!(e instanceof Halt)) throw e;
    console.log(e.line);
    console.log(`${tag}: ${e.code === 1 ? 'FAILED; ' : ''}${st.writes ? `stopped after ${st.writes} writes; a re-run finishes the rest` : 'could not finish reading RevenueCat; nothing changed'}`);
    return e.code;
  }
}

// ---- command line: revenuecat-setup <catalog module> [--dry-run] [--save-keys] ----------------------
export async function main(argv = process.argv.slice(2)) {
  const file = argv.find(a => !a.startsWith('--'));
  try {
    const mod = await import(pathToFileURL(resolve(file)).href);
    if (!mod.catalog) { console.log(`OUTPUT revenuecat-setup: NAMED STOP [CATALOG_MISSING] ${file} exports no \`catalog\``); return 2; }
    return await run(mod.catalog, argv);
  } catch (e) {
    console.log(`OUTPUT revenuecat-setup: FAILED UNEXPECTED ${String(e?.stack ?? e).split('\n').slice(0, 3).join(' | ').slice(0, 400)}`);
    return 1;
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(code => { process.exitCode = code; });
