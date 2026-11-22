// The shared Play tool (store/play-products.mjs) against an in-memory Google Play: what it writes,
// what it never touches, and how it behaves when Play or the network fails part-way.
//   node --test tests/store/
import test from 'node:test';
import assert from 'node:assert/strict';
import { run, plan, money, amountOf, ceilingBreaks, livePrices, OPTION_ID } from '../../store/play-products.mjs';

const PKG = 'com.example.app';
const product = (id, priceUsd, extra = {}) => ({ id, title: `Title ${id}`, description: `What ${id} is. Paid once.`, priceUsd, ...extra });
const catalog = (products = [product('kit_a', 14.99), product('kit_b', 29.99), product('bundle', 49.99)]) => ({ app: 'Example', packageName: PKG, products });

// Google's conversion, made up but deterministic: EUR = USD + 1 (so pairs can pass the bundle), JPY = USD x 150.
const convert = usd => ({
  convertedRegionPrices: {
    US: { regionCode: 'US', price: money(usd) },
    DE: { regionCode: 'DE', price: money(usd + 1, 'EUR') },
    JP: { regionCode: 'JP', price: money(Math.round(usd * 150), 'JPY') },
  },
  convertedOtherRegionsPrice: { usdPrice: money(usd), eurPrice: money(usd + 1, 'EUR') },
  regionVersion: { version: '2025/03' },
});

/** A fake Play. `fault(method, path, n)` may return { status, body } or 'throw' to break one call. */
function fakePlay({ products = [], fault = () => null, activateWorks = true, onGetOne } = {}) {
  const db = new Map(products.map(p => [p.productId, structuredClone(p)]));
  const offers = new Map();
  const calls = [];
  let n = 0;
  const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, text: async () => (typeof body === 'string' ? body : JSON.stringify(body ?? {})) });
  const fetchFn = async (url, init) => {
    const path = url.split(`/applications/${PKG}`)[1];
    const method = init.method;
    calls.push(`${method} ${path.split('?')[0]}`);
    const f = fault(method, path, ++n);
    if (f === 'throw') throw Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNRESET' } });
    if (f) return reply(f.status, f.body);
    const body = init.body ? JSON.parse(init.body) : null;
    let m;
    if (method === 'GET' && path.startsWith('/oneTimeProducts?')) return db.size ? reply(200, { oneTimeProducts: [...db.values()] }) : { ok: true, status: 204, text: async () => '' };
    if (method === 'POST' && path === '/pricing:convertRegionPrices') return reply(200, convert(amountOf(body.price)));
    if ((m = path.match(/^\/oneTimeProducts\/([^/?]+)\/purchaseOptions\/buy\/offers\?/)) && method === 'GET') return reply(200, { oneTimeProductOffers: offers.get(m[1]) ?? [] });
    if ((m = path.match(/^\/oneTimeProducts\/([^/?]+)\/purchaseOptions\/buy\/offers:batchUpdate$/))) {
      const o = body.requests[0].oneTimeProductOffer;
      offers.set(m[1], [...(offers.get(m[1]) ?? []), { ...o, state: 'DRAFT' }]);
      return reply(200, { oneTimeProductOffers: [o] });
    }
    if ((m = path.match(/^\/oneTimeProducts\/([^/?]+)\/purchaseOptions\/buy\/offers:batchUpdateStates$/))) {
      const o = offers.get(m[1]).find(x => x.offerId === body.requests[0].activateOneTimeProductOfferRequest.offerId);
      o.state = 'ACTIVE';
      return reply(200, {});
    }
    if ((m = path.match(/^\/oneTimeProducts\/([^/?:]+)$/)) && method === 'GET') {
      onGetOne?.(m[1], db);
      return db.has(m[1]) ? reply(200, db.get(m[1])) : reply(404, { error: { code: 404 } });
    }
    if ((m = path.match(/^\/onetimeproducts\/([^/?]+)\?/)) && method === 'PATCH') {
      db.set(m[1], { ...body, regionsVersion: { version: '2025/03' }, purchaseOptions: body.purchaseOptions.map(o => ({ ...o, state: 'DRAFT' })) });
      return reply(200, db.get(m[1]));
    }
    if ((m = path.match(/^\/oneTimeProducts\/([^/?]+)\/purchaseOptions:batchUpdateStates$/))) {
      if (activateWorks) for (const o of db.get(m[1]).purchaseOptions) o.state = 'ACTIVE';
      return reply(200, {});
    }
    return reply(500, `unexpected ${method} ${path}`);
  };
  return { fetchFn, db, offers, calls };
}
const go = async (c, play, argv = [], now) => {
  const lines = [];
  const code = await run(c, { argv, getToken: async () => 'token', fetchFn: play.fetchFn, log: l => lines.push(l), now });
  return { code, lines, out: lines.at(-1) };
};
const onPlay = (id, usCents, state = 'ACTIVE') => ({ productId: id, listings: [{ title: id }], purchaseOptions: [{ purchaseOptionId: OPTION_ID, state,
  regionalPricingAndAvailabilityConfigs: [{ regionCode: 'US', price: money(usCents / 100), availability: 'AVAILABLE' }] }] });

test('plan: creates what is missing, activates only drafts, reports a switched-off product and a price mismatch, never touches extras', () => {
  const c = catalog([product('new', 9.99), product('draft', 9.99), product('live', 9.99), product('off', 9.99), product('wrong', 9.99), product('noprice', null)]);
  const pl = plan(c, [onPlay('draft', 999, 'DRAFT'), onPlay('live', 999), onPlay('off', 999, 'INACTIVE'), onPlay('wrong', 1299), onPlay('legacy', 100)]);
  assert.deepEqual(pl.create.map(p => p.id), ['new']);
  assert.deepEqual(pl.activate.map(p => p.id), ['draft']);
  assert.deepEqual(pl.ok.map(p => p.id), ['live']);
  assert.match(pl.inactive.join(), /SWITCHED OFF off/);
  assert.match(pl.mismatches.join(), /MISMATCH wrong: Play US price \$12\.99, code \$9\.99/);
  assert.match(pl.stops.join(), /PRICE_MISSING\] noprice/);
  assert.deepEqual(pl.extra, ['legacy']);
});

test('a dry run with products still to create exits 3, never 0, and writes nothing', async () => {
  const play = fakePlay();
  const r = await go(catalog(), play);
  assert.equal(r.code, 3);
  assert.match(r.out, /3 to create.*Play lacks these/);
  assert.ok(play.calls.every(c => c.startsWith('GET')));
});

test('apply creates and activates every product, reads back, and a second dry run exits 0', async () => {
  const play = fakePlay();
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 0, r.lines.join('\n'));
  assert.match(r.out, /created 3, activated 3.*read-back 3\/3 active/);
  const kit = play.db.get('kit_a');
  assert.equal(kit.purchaseOptions[0].buyOption.legacyCompatible, true);
  assert.deepEqual(livePrices(kit).get('US'), money(14.99));
  assert.equal((await go(catalog(), play)).code, 0);
});

test('a product priced differently on Play is never written, deleted or repriced', async () => {
  const play = fakePlay({ products: [onPlay('kit_a', 1999)] });
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 1);
  assert.match(r.lines.join('\n'), /MISMATCH kit_a/);
  assert.ok(!play.calls.some(c => c.includes('kit_a') && !c.startsWith('GET')), play.calls.join('\n'));
  assert.ok(!play.calls.some(c => c.startsWith('DELETE')));
  assert.deepEqual(livePrices(play.db.get('kit_a')).get('US'), money(19.99));
});

test('a product someone switched off on Play is reported and never switched back on', async () => {
  const play = fakePlay({ products: [onPlay('kit_a', 1499, 'INACTIVE')] });
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 1);
  assert.match(r.lines.join('\n'), /SWITCHED OFF kit_a/);
  assert.ok(!play.calls.includes('POST /oneTimeProducts/kit_a/purchaseOptions:batchUpdateStates'));
  assert.equal(play.db.get('kit_a').purchaseOptions[0].state, 'INACTIVE');
});

test('a product that appears on Play after the list was read is left exactly as it is', async () => {
  const play = fakePlay({ onGetOne: (id, db) => { if (id === 'kit_b' && !db.has(id)) db.set(id, onPlay('kit_b', 2599, 'ACTIVE')); } });
  const r = await go(catalog(), play, ['--apply']);
  assert.match(r.lines.join('\n'), /skip kit_b: it appeared on Play/);
  assert.ok(!play.calls.some(c => c === 'PATCH /onetimeproducts/kit_b'));
  assert.deepEqual(livePrices(play.db.get('kit_b')).get('US'), money(25.99));
  assert.equal(r.code, 1, 'its price differs from the code, so the read-back reports the mismatch');
});

test('403: stops at the first refusal, creates nothing, names the permission stop', async () => {
  const play = fakePlay({ fault: (m, p) => (p.startsWith('/pricing') ? { status: 403, body: { error: { message: 'The caller does not have permission' } } } : null) });
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 1);
  assert.match(r.out, /NAMED STOP \[PLAY_PERMISSION_DENIED\].*created 0/);
  assert.equal(play.calls.filter(c => c.startsWith('POST /pricing')).length, 1);
  assert.equal(play.db.size, 0);
});

for (const [name, fault, pattern] of [
  ['429 rate limit', { status: 429, body: { error: { message: 'Quota exceeded' } } }, /FAILED PLAY_API_429 PATCH .*re-run finishes/],
  ['503 outage', { status: 503, body: 'Service Unavailable' }, /FAILED PLAY_API_503 PATCH/],
  ['network error', 'throw', /FAILED PLAY_NETWORK PATCH .*ECONNRESET/],
  ['a 200 reply that is not JSON', { status: 200, body: '<html>maintenance</html>' }, /FAILED PLAY_BAD_REPLY PATCH/],
]) test(`${name} on the second write: OUTPUT line last, exit 1, no crash; a re-run finishes and the next dry run exits 0`, async () => {
  let patches = 0;
  const play = fakePlay({ fault: (m) => (m === 'PATCH' && ++patches === 2 ? fault : null) });
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 1);
  assert.match(r.lines.join('\n'), pattern);
  assert.match(r.out, /^OUTPUT play-products Example: FAILED \(1\) applied on .*created 1, activated 1/);
  assert.equal(play.db.size, 1, 'nothing after the failure was written');
  const again = await go(catalog(), play, ['--apply']);
  assert.equal(again.code, 0, again.lines.join('\n'));
  assert.match(again.out, /created 2/);
  assert.equal((await go(catalog(), play)).code, 0);
});

test('a half-finished run (created, activation failed) is finished by the re-run', async () => {
  let n = 0;
  const play = fakePlay({ fault: (m, p) => (p.endsWith('purchaseOptions:batchUpdateStates') && ++n === 1 ? { status: 500, body: 'boom' } : null) });
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 1);
  assert.equal(play.db.get('kit_a').purchaseOptions[0].state, 'DRAFT');
  const dry = await go(catalog(), play);
  assert.equal(dry.code, 3);
  assert.match(dry.lines.join('\n'), /activate kit_a \(exists as a draft\)/);
  const again = await go(catalog(), play, ['--apply']);
  assert.equal(again.code, 0, again.lines.join('\n'));
  assert.match(again.out, /read-back 3\/3 active/);
});

test('the read-back catches a write Play accepted but did not keep', async () => {
  const play = fakePlay({ activateWorks: false });
  const r = await go(catalog(), play, ['--apply']);
  assert.equal(r.code, 1);
  assert.match(r.lines.join('\n'), /FAILED READBACK_NOT_CLEAN: 0 to create, 3 to activate/);
});

test('a failed or unreadable list changes nothing and still prints the OUTPUT line', async () => {
  for (const f of ['throw', { status: 200, body: 'not json' }, { status: 500, body: 'x' }]) {
    const play = fakePlay({ fault: (m, p) => (p.startsWith('/oneTimeProducts?') ? f : null) });
    const r = await go(catalog(), play, ['--apply']);
    assert.equal(r.code, 1);
    assert.match(r.out, /could not read Play; nothing changed/);
    assert.ok(play.calls.every(c => c.startsWith('GET')));
  }
});

test('zero products in the code exits 1; a product with no price is a named stop (2) and is not created', async () => {
  assert.equal((await go(catalog([]), fakePlay())).code, 1);
  const play = fakePlay();
  const r = await go(catalog([product('kit_a', 14.99), product('free', null)]), play, ['--apply']);
  assert.equal(r.code, 2);
  assert.ok(!play.db.has('free'));
});

test('a ceiling: in every region a part bought first plus the upgrade never costs more than the whole', async () => {
  // kit_a alone and kit_a + kit_c bought together both lead to this upgrade.
  const c = catalog([product('kit_a', 14.99), product('kit_c', 0.5), product('bundle', 49.99), product('upgrade', 34.49, { ceiling: { whole: 'bundle', parts: ['kit_a', ['kit_a', 'kit_c']] } })]);
  const play = fakePlay();
  const r = await go(c, play, ['--apply']);
  assert.equal(r.code, 0, r.lines.join('\n'));
  const p = id => livePrices(play.db.get(id));
  assert.deepEqual(p('upgrade').get('US'), money(34.49), 'the US price is the code price');
  assert.equal(amountOf(p('upgrade').get('DE')), 33.5, 'EUR capped to 50.99 - (15.99 + 1.50), the set bought together');
  assert.deepEqual(ceilingBreaks(c.products[3].ceiling, p('upgrade'), p), []);
  assert.equal(play.db.get('upgrade').purchaseOptions[0].newRegionsConfig, undefined, 'no unchecked new-region price');
  // The same ceiling against products already on Play at a breaking price is a mismatch, not a write.
  const broken = fakePlay({ products: ['kit_a', 'kit_c', 'bundle', 'upgrade'].map(id => play.db.get(id)) });
  broken.db.get('upgrade').purchaseOptions[0].regionalPricingAndAvailabilityConfigs.find(x => x.regionCode === 'DE').price = money(36, 'EUR');
  const b = await go(c, broken, ['--apply']);
  assert.equal(b.code, 1);
  assert.match(b.lines.join('\n'), /MISMATCH upgrade: costs more than bundle .*DE EUR: kit_a\+kit_c/);
  assert.match(plan(catalog([product('kit_a', 14.99), product('bundle', 19.99), product('up', 9.99, { ceiling: { whole: 'bundle', parts: ['kit_a'] } })]), []).stops.join(), /CEILING_USD\] up/);
  assert.ok(!broken.calls.some(x => x.startsWith('PATCH')));
});

test('a launch offer is created once from the dates in the code, US exactly the offer price; no date yet is WAITING, not drift', async () => {
  const now = Date.parse('2027-01-01T00:00:00Z');
  const dated = catalog([product('plan', 14.99, { offers: [{ id: 'launch', priceUsd: 9.99, startTime: '2027-01-02T00:00:00Z', endTime: '2027-02-01T00:00:00Z' }] })]);
  const play = fakePlay();
  assert.equal((await go(dated, play, [], now)).code, 3);
  const r = await go(dated, play, ['--apply'], now);
  assert.equal(r.code, 0, r.lines.join('\n'));
  const [o] = play.offers.get('plan');
  assert.equal(o.state, 'ACTIVE');
  assert.deepEqual(o.regionalPricingAndAvailabilityConfigs.find(x => x.regionCode === 'US').absoluteDiscount, money(5));
  assert.equal(o.regionalPricingAndAvailabilityConfigs.find(x => x.regionCode === 'DE').relativeDiscount, 0.3336);
  assert.equal(o.discountedOffer.endTime, '2027-02-01T00:00:00.000Z');
  assert.deepEqual(livePrices(play.db.get('plan')).get('US'), money(14.99), 'the list price stays the code price');
  const twice = await go(dated, play, ['--apply'], now);
  assert.equal(twice.code, 0);
  assert.ok(!play.calls.slice(-6).some(x => x.endsWith('offers:batchUpdate')), 'an existing offer is never rewritten');

  const undated = catalog([product('plan', 14.99, { offers: [{ id: 'launch', priceUsd: 9.99, startTime: null, endTime: null }] })]);
  const w = await go(undated, fakePlay({ products: [onPlay('plan', 1499)] }), [], now);
  assert.equal(w.code, 0);
  assert.match(w.lines.join('\n'), /WAITING plan\/launch/);
});
