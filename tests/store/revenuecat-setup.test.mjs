// The shared RevenueCat tool (store/revenuecat-setup.mjs) against an in-memory RevenueCat v2.
//   node --test tests/store/
import test from 'node:test';
import assert from 'node:assert/strict';
import { storeType, diff, run, playTypesReady } from '../../store/revenuecat-setup.mjs';

const catalog = {
  app: 'Example', projectName: 'Example', vaultPrefix: 'EX', secretEnv: 'EXAMPLE_RC_TEST_KEY', bundleId: 'com.example.app',
  products: [{ id: 'kit', kind: 'non_consumable', name: 'Kit' }, { id: 'extra_event', kind: 'consumable', name: 'Extra event' }],
  entitlements: [{ key: 'kit', name: 'Kit', products: ['kit'] }],
  offerings: [{ key: 'default', name: 'Default', current: true, packages: ['kit', 'extra_event'] }],
};

test('no store ever gets one_time: on Play that would make RevenueCat consume a non-consumable purchase', () => {
  for (const store of ['app_store', 'play_store', 'test_store']) {
    assert.equal(storeType(store, 'non_consumable'), 'non_consumable');
    assert.equal(storeType(store, 'consumable'), 'consumable');
    assert.throws(() => storeType(store, 'one_time'));
  }
});

/** A fake RevenueCat holding one project; `products` seeds what already exists. */
function fakeRc({ products = [], fault = () => null, readOnly = false, pageSize = 0 } = {}) {
  const s = { apps: [], products: structuredClone(products), ents: [], entProducts: {}, offs: [], pkgs: [], pkgProducts: {}, posts: [] };
  let id = 0;
  const next = p => `${p}${++id}`;
  const reply = (status, body) => ({ ok: status < 300, status, text: async () => (typeof body === 'string' ? body : JSON.stringify(body)) });
  s.apps.push({ id: 'app_ios', type: 'app_store', app_store: { bundle_id: catalog.bundleId } }, { id: 'app_play', type: 'play_store', play_store: { package_name: catalog.bundleId } }, { id: 'app_test', type: 'test_store' });
  const fetchFn = async (url, init) => {
    const path = url.replace('https://api.revenuecat.com/v2', '').split('?')[0];
    const body = init.body ? JSON.parse(init.body) : null;
    const f = fault(init.method, path);
    if (f === 'throw') throw Object.assign(new TypeError('fetch failed'), { cause: { code: 'ENOTFOUND' } });
    if (f) return reply(f.status, f.body);
    if (init.method === 'POST' && readOnly) return reply(403, { message: 'The API key needs at least the project_configuration:products:read_write permission defined' });
    if (init.method === 'POST') s.posts.push(`${path} ${JSON.stringify(body)}`);
    const after = new URL(url).searchParams.get('starting_after');
    const items = list => {
      if (!pageSize) return reply(200, { items: list });
      const from = Number(after ?? 0); // the fake's cursor is an offset
      return reply(200, { items: list.slice(from, from + pageSize), next_page: from + pageSize < list.length ? `/v2${path}?limit=100&starting_after=${from + pageSize}` : null });
    };
    let m;
    if (path === '/projects') return items([{ id: 'proj', name: 'Example' }]);
    if (path === '/projects/proj/apps') return items(s.apps);
    if (path === '/projects/proj/products' && init.method === 'GET') return items(s.products);
    if (path === '/projects/proj/products') { const p = { id: next('prod'), ...body }; s.products.push(p); return reply(201, p); }
    if ((m = path.match(/^\/projects\/proj\/products\/([^/]+)$/))) { const p = s.products.find(x => x.id === m[1]); Object.assign(p, body); return reply(200, p); }
    if (path === '/projects/proj/entitlements' && init.method === 'GET') return items(s.ents);
    if (path === '/projects/proj/entitlements') { const e = { id: next('ent'), ...body }; s.ents.push(e); s.entProducts[e.id] = []; return reply(201, e); }
    if ((m = path.match(/^\/projects\/proj\/entitlements\/([^/]+)\/products$/))) return items(s.entProducts[m[1]].map(pid => s.products.find(p => p.id === pid)));
    if ((m = path.match(/^\/projects\/proj\/entitlements\/([^/]+)\/actions\/attach_products$/))) { s.entProducts[m[1]].push(...body.product_ids); return reply(200, {}); }
    if (path === '/projects/proj/offerings' && init.method === 'GET') return items(s.offs);
    if (path === '/projects/proj/offerings') { const o = { id: next('off'), ...body }; s.offs.push(o); return reply(201, o); }
    if ((m = path.match(/^\/projects\/proj\/offerings\/([^/]+)$/))) { Object.assign(s.offs.find(o => o.id === m[1]), body); return reply(200, {}); }
    if ((m = path.match(/^\/projects\/proj\/offerings\/([^/]+)\/packages$/)) && init.method === 'GET') return items(s.pkgs.filter(p => p.off === m[1]));
    if ((m = path.match(/^\/projects\/proj\/offerings\/([^/]+)\/packages$/))) { const p = { id: next('pkg'), off: m[1], ...body }; s.pkgs.push(p); s.pkgProducts[p.id] = []; return reply(201, p); }
    if ((m = path.match(/^\/projects\/proj\/packages\/([^/]+)\/products$/))) return items(s.pkgProducts[m[1]].map(pid => ({ product: { id: pid } })));
    if ((m = path.match(/^\/projects\/proj\/packages\/([^/]+)\/actions\/attach_products$/))) { s.pkgProducts[m[1]].push(...body.products.map(p => p.product_id)); return reply(200, {}); }
    if ((m = path.match(/^\/projects\/proj\/packages\/([^/]+)$/))) { Object.assign(s.pkgs.find(p => p.id === m[1]), body); return reply(200, {}); }
    return reply(500, `unexpected ${init.method} ${path}`);
  };
  return { s, fetchFn };
}
async function withRc(rc, fn) {
  const saved = [globalThis.fetch, console.log, process.env.EXAMPLE_RC_TEST_KEY];
  const lines = [];
  globalThis.fetch = rc.fetchFn; console.log = l => lines.push(String(l)); process.env.EXAMPLE_RC_TEST_KEY = 'test-key';
  try { return { code: await fn(), lines }; } finally { [globalThis.fetch, console.log] = saved; if (saved[2] === undefined) delete process.env.EXAMPLE_RC_TEST_KEY; else process.env.EXAMPLE_RC_TEST_KEY = saved[2]; }
}

test('a Play product held as one_time is corrected to the code type, and the read-back proves it', async () => {
  const rc = fakeRc({ products: [
    { id: 'old1', app_id: 'app_play', store_identifier: 'kit', type: 'one_time' },
    { id: 'old2', app_id: 'app_play', store_identifier: 'extra_event', type: 'one_time' },
  ] });
  const r = await withRc(rc, () => run(catalog, []));
  assert.equal(r.code, 0, r.lines.join('\n'));
  assert.equal(rc.s.products.find(p => p.id === 'old1').type, 'non_consumable');
  assert.equal(rc.s.products.find(p => p.id === 'old2').type, 'consumable');
  assert.ok(rc.s.products.every(p => p.type !== 'one_time'));
  assert.ok(!rc.s.posts.some(p => p.startsWith('/projects/proj/products {') && p.includes('"store_identifier":"kit","app_id":"app_play"')), 'corrected in place, not duplicated');
  assert.match(r.lines.join('\n'), /type kit on play_store: one_time -> non_consumable/);
});

test('the read-back check fails when a product type differs from the code', () => {
  const live = {
    apps: [{ id: 'a', type: 'play_store', play_store: { package_name: catalog.bundleId } }],
    products: [{ app_id: 'a', store_identifier: 'kit', type: 'one_time' }, { app_id: 'a', store_identifier: 'extra_event', type: 'consumable' }],
    entitlementProducts: { kit: ['kit'] }, offeringPackages: { default: [{ key: 'kit', position: 1, products: ['kit'] }, { key: 'extra_event', position: 2, products: ['extra_event'] }] }, currentOffering: ['default'],
  };
  const out = diff(catalog, live);
  assert.ok(out.some(l => l === 'product kit on play_store is one_time, code says non_consumable'), out.join('\n'));
});

const FAULTS = { 'a 503': { status: 503, body: 'down' }, 'a network error': 'throw', 'a reply that is not JSON': { status: 200, body: '<html>' } };
const LISTS = ['/projects', '/projects/proj/apps', '/projects/proj/products', '/projects/proj/entitlements', '/projects/proj/offerings'];

test('a failed list is unknown, never empty: an outage on any list writes nothing, says why, and a re-run finishes', async () => {
  for (const [name, f] of Object.entries(FAULTS)) for (const list of LISTS) {
    const rc = fakeRc();
    const r = await withRc({ fetchFn: (u, i) => (i.method === 'GET' && u.split('?')[0].endsWith(list) && !u.includes('starting_after') ? (f === 'throw' ? Promise.reject(Object.assign(new TypeError('fetch failed'), { cause: { code: 'ENOTFOUND' } })) : Promise.resolve({ ok: f.status < 300, status: f.status, text: async () => f.body })) : rc.fetchFn(u, i)) }, () => run(catalog, []));
    const writesBefore = list === '/projects' || list === '/projects/proj/apps' ? 0 : list === '/projects/proj/products' ? 2 : null;
    if (writesBefore === 0) assert.equal(rc.s.posts.length, 0, `${name} on ${list}: ${rc.s.posts.join(' | ')}`);
    assert.equal(r.code, 1, `${name} on ${list}: ${r.lines.join('\n')}`);
    assert.match(r.lines.at(-2), /^FAILED RC_(UNAVAILABLE|BAD_REPLY)/, `${name} on ${list}`);
    assert.match(r.lines.at(-1), /^OUTPUT revenuecat-setup Example: FAILED; (could not finish reading RevenueCat; nothing changed|stopped after \d+ writes)/);
    // Nothing was created on top of the failed read: one of each, never two.
    const again = await withRc(rc, () => run(catalog, []));
    assert.equal(again.code, 0, `re-run after ${name} on ${list}: ${again.lines.join('\n')}`);
    assert.equal(rc.s.apps.filter(a => a.type === 'app_store').length, 1, `${name} on ${list}: duplicate app`);
    for (const id of ['kit', 'extra_event']) assert.equal(rc.s.products.filter(p => p.store_identifier === id).length, 3, `${name} on ${list}: duplicate ${id}`);
    assert.equal(rc.s.ents.length, 1, `${name} on ${list}: duplicate entitlement`);
    assert.equal(rc.s.offs.length, 1, `${name} on ${list}: duplicate offering`);
  }
});

test('a 503 on /projects says RevenueCat is unavailable, never that the key sees 0 projects', async () => {
  const r = await withRc(fakeRc({ fault: (m, p) => (p === '/projects' ? { status: 503, body: 'down' } : null) }), () => run(catalog, []));
  assert.equal(r.code, 1);
  assert.match(r.lines.join('\n'), /RevenueCat unavailable GET \/projects: 503/);
  assert.doesNotMatch(r.lines.join('\n'), /PROJECT_UNCLEAR|0 projects/);
});

test('a key that cannot write is NAMED STOP RC_KEY_READ_ONLY naming the key, exit 3, after the first refused write', async () => {
  const rc = fakeRc({ readOnly: true, products: [{ id: 'old1', app_id: 'app_play', store_identifier: 'kit', type: 'one_time' }] });
  const r = await withRc(rc, () => run(catalog, []));
  assert.equal(r.code, 3, r.lines.join('\n'));
  assert.match(r.lines.join('\n'), /NAMED STOP \[RC_KEY_READ_ONLY\] EXAMPLE_RC_TEST_KEY cannot write/);
  assert.match(r.lines.at(-1), /nothing changed$/);
});

test('--dry-run reads RevenueCat, lists the drift, exits non-zero and writes nothing; a matching project exits 0', async () => {
  const rc = fakeRc({ products: [{ id: 'old1', app_id: 'app_play', store_identifier: 'kit', type: 'one_time' }] });
  const r = await withRc(rc, () => run(catalog, ['--dry-run']));
  assert.equal(r.code, 1, r.lines.join('\n'));
  assert.ok(r.lines.includes('would fix: product kit on play_store is one_time, code says non_consumable'), r.lines.join('\n'));
  assert.equal(rc.s.posts.length, 0);
  assert.equal(rc.s.products.find(p => p.id === 'old1').type, 'one_time');
  assert.equal((await withRc(rc, () => run(catalog, []))).code, 0);
  const clean = await withRc(rc, () => run(catalog, ['--dry-run']));
  assert.equal(clean.code, 0, clean.lines.join('\n'));
  assert.match(clean.lines.at(-1), /RevenueCat matches the code; nothing changed/);
  const down = await withRc(fakeRc({ fault: (m, p) => (p === '/projects/proj/products' ? { status: 503, body: 'down' } : null) }), () => run(catalog, ['--dry-run']));
  assert.equal(down.code, 1);
  assert.match(down.lines.join('\n'), /RevenueCat unavailable GET \/projects\/proj\/products/);
});

test('every page of a list is read: products past the first page are never created twice', async () => {
  const rc = fakeRc({ pageSize: 2 });
  assert.equal((await withRc(rc, () => run(catalog, []))).code, 0);
  const posts = rc.s.posts.length;
  const again = await withRc(rc, () => run(catalog, []));
  assert.equal(again.code, 0, again.lines.join('\n'));
  assert.equal(rc.s.posts.length, posts, 'a second run writes nothing');
  assert.equal(rc.s.products.length, 6);
});

test('the Play order guard is ready only when every Play product has the code type', async () => {
  const rc = fakeRc({ products: [{ id: 'old1', app_id: 'app_play', store_identifier: 'kit', type: 'one_time' }] });
  const notYet = await withRc(rc, () => playTypesReady(catalog));
  assert.equal(notYet.code.ok, false);
  assert.match(notYet.code.why, /RC_TYPES_NOT_READY.*kit is one_time.*extra_event missing/);
  assert.equal((await withRc(rc, () => run(catalog, []))).code, 0);
  assert.deepEqual((await withRc(rc, () => playTypesReady(catalog))).code, { ok: true });
  const down = await withRc(fakeRc({ fault: (m, p) => (p === '/projects/proj/products' ? 'throw' : null) }), () => playTypesReady(catalog));
  assert.equal(down.code.ok, false, 'an unreadable RevenueCat is never ready');
  assert.equal((await playTypesReady(undefined)).ok, false);
});
