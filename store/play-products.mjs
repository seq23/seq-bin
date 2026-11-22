// Google Play one-time products for one app, from a catalog module in the app's own repo
// (apps/mobile/scripts/store/play-products.mjs exports `catalog`; the app repo keeps only that list and
// a test of its ids and prices). Every app that sells on Play runs this one file through ~/bin/play-products.
//
// Google retired the inappproducts API for these apps ("Please migrate to the new publishing API", 403),
// so this uses monetization.onetimeproducts: one "buy" purchase option per product, legacy compatible
// (so RevenueCat's plain product id buys it), the USD price from the code and Google's own conversion
// for every other region.
//
// What it never does: delete, deactivate or reprice anything. A product on Play at another US price is a
// MISMATCH line and is left as it is. A product someone switched off on Play (INACTIVE) is reported and
// left off; only DRAFT, which is this script's own half-finished run, is activated. Each product is read
// again just before it is written, so one that appeared since the list (a second run, a Console edit) is
// never overwritten. Launch offers (a time-boxed discount on the buy option) are created once, from the
// dates in the code, and never changed afterwards.
//
// The first failure of any kind (401/403, 429, 5xx, a network error, a reply that is not JSON) stops
// every further write; reads go on, so the run still reports what Play holds. A re-run is the retry and
// finishes only what is missing.
//
// Dry run by default (reads Play, prints the plan, changes nothing); --apply writes, then reads back.
// Exit: 0 = Play matches the code; 3 = dry run, Play still lacks something (run --apply);
//       1 = a failure, a MISMATCH or a product switched off on Play; 2 = a NAMED STOP.
// Prints one OUTPUT line, last.
import { pathToFileURL, fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { googleAccessToken } from './google-token.mjs';

const API = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
export const OPTION_ID = 'buy';
const NOT_FOUND = Symbol('not found');

// ---- money ---------------------------------------------------------------------------------------
const fractionDigits = cur => { try { return new Intl.NumberFormat('en', { style: 'currency', currency: cur }).resolvedOptions().maximumFractionDigits; } catch { return 2; } };
/** An amount to Google's Money, floored to the currency's smallest unit. */
export function money(amount, currencyCode = 'USD') {
  const f = 10 ** fractionDigits(currencyCode);
  const minor = Math.floor(amount * f + 1e-6);
  return { currencyCode, units: String(Math.floor(minor / f)), nanos: (minor % f) * (1e9 / f) };
}
export const amountOf = m => (m ? Number(m.units ?? 0) + (m.nanos ?? 0) / 1e9 : null);
const centsOf = m => (m ? Math.round(amountOf(m) * 100) : null);
const usd = c => `$${(c / 100).toFixed(2)}`;
const cents = n => Math.round(n * 100);

// ---- reading Play's shapes -----------------------------------------------------------------------
const buyOption = p => (p?.purchaseOptions ?? []).find(x => x.purchaseOptionId === OPTION_ID) ?? (p?.purchaseOptions ?? [])[0];
/** The product's US price in cents and its buy option's state, as Play holds them. */
export function liveShape(p) {
  const o = buyOption(p);
  const us = o?.regionalPricingAndAvailabilityConfigs?.find(r => r.regionCode === 'US');
  return { optionId: o?.purchaseOptionId ?? null, state: o?.state ?? null, usCents: us && us.price?.currencyCode === 'USD' ? centsOf(us.price) : null,
    title: p.listings?.[0]?.title ?? null };
}
/** region code -> Money, for a product as Play holds it. */
export const livePrices = p => new Map((buyOption(p)?.regionalPricingAndAvailabilityConfigs ?? []).filter(r => r.price).map(r => [r.regionCode, r.price]));
/** region code -> Money, from Google's conversion of a USD price (US is the code's price exactly). */
export function convertedPrices(priceUsd, conv) {
  const m = new Map(Object.values(conv.convertedRegionPrices ?? {}).map(r => [r.regionCode, r.price]));
  m.set('US', money(priceUsd));
  return m;
}

// ---- ceilings: what was bought first plus this product never costs more than the whole -----------
// ceiling = { whole: id, parts: [id or [ids]] }: each part is one product or a set bought together.
const partName = part => [part].flat().join('+');
/** A part's price in one region (the sum of its products), or null when any of them is missing there or in another currency. */
function partPrice(part, region, currencyCode, pricesOf) {
  let sum = 0;
  for (const id of [part].flat()) {
    const m = pricesOf(id)?.get(region);
    if (!m || m.currencyCode !== currencyCode) return null;
    sum += amountOf(m);
  }
  return sum;
}
/** Regions where `part + this product > whole`. `pricesOf(id)` gives region -> Money. */
export function ceilingBreaks(ceiling, own, pricesOf) {
  const whole = pricesOf(ceiling.whole);
  const out = [];
  if (!whole) return out;
  for (const [region, m] of own) {
    const w = whole.get(region);
    if (!w || w.currencyCode !== m.currencyCode) continue;
    for (const part of ceiling.parts) {
      const k = partPrice(part, region, m.currencyCode, pricesOf);
      if (k != null && k + amountOf(m) > amountOf(w) + 1e-9) out.push(`${region} ${m.currencyCode}: ${partName(part)} ${+k.toFixed(4)} + ${amountOf(m)} > ${ceiling.whole} ${amountOf(w)}`);
    }
  }
  return out;
}
/** Lowers this product's price in each region just enough that no part plus it passes the whole. */
export function capToCeiling(ceiling, own, pricesOf) {
  const whole = pricesOf(ceiling.whole);
  const out = new Map(own);
  for (const [region, m] of own) {
    const w = whole?.get(region);
    if (!w || w.currencyCode !== m.currencyCode) continue;
    let max = amountOf(m);
    for (const part of ceiling.parts) {
      const k = partPrice(part, region, m.currencyCode, pricesOf);
      if (k != null) max = Math.min(max, amountOf(w) - k);
    }
    if (max < amountOf(m)) out.set(region, money(max, m.currencyCode));
  }
  return out;
}

// ---- the plan --------------------------------------------------------------------------------------
/** Why a catalog product cannot be sent to Play, or null. */
export function productStop(p, catalog) {
  if (!(Number.isFinite(p.priceUsd) && p.priceUsd > 0)) return `NAMED STOP [PRICE_MISSING] ${p.id}: no price for it in the app code, so it is not created`;
  if (!p.title || p.title.length > 55) return `NAMED STOP [TITLE_INVALID] ${p.id}: title must be 1-55 characters (${p.title?.length ?? 0})`;
  if (!p.description || p.description.length > 200) return `NAMED STOP [DESCRIPTION_INVALID] ${p.id}: description must be 1-200 characters (${p.description?.length ?? 0})`;
  if (!/^[a-z0-9][a-z0-9_.]*$/.test(p.id)) return `NAMED STOP [ID_INVALID] ${p.id}`;
  if (p.ceiling) {
    const price = id => catalog.products.find(x => x.id === id)?.priceUsd;
    const w = price(p.ceiling.whole);
    for (const part of p.ceiling.parts) {
      const k = [part].flat().reduce((sum, id) => sum + cents(price(id)), 0);
      if (!(k + cents(p.priceUsd) <= cents(w))) return `NAMED STOP [CEILING_USD] ${p.id}: in the code itself ${partName(part)} ${usd(k)} + $${p.priceUsd} passes ${p.ceiling.whole} $${w}`;
    }
  }
  for (const o of p.offers ?? []) {
    if (!(o.priceUsd > 0 && o.priceUsd < p.priceUsd) || !/^[a-z0-9][a-z0-9-]*$/.test(o.id ?? '')) return `NAMED STOP [OFFER_INVALID] ${p.id}/${o.id}: an offer needs an id and a price below $${p.priceUsd}`;
    if (o.startTime && !(Date.parse(o.endTime) > Date.parse(o.startTime))) return `NAMED STOP [OFFER_INVALID] ${p.id}/${o.id}: endTime must come after startTime`;
  }
  return null;
}

/**
 * What --apply would do, from the catalog, Play's product list and each product's offers.
 * Pure, so tests hold it. `liveOffers` maps product id -> the offers Play holds on its buy option.
 */
export function plan(catalog, liveProducts, liveOffers = new Map(), now = Date.now()) {
  const live = new Map(liveProducts.map(p => [p.productId, p]));
  const out = { create: [], activate: [], ok: [], mismatches: [], inactive: [], stops: [], extra: [],
    offerCreate: [], offerActivate: [], offerOk: [], offerWaiting: [] };
  const pricesOf = id => (live.has(id) ? livePrices(live.get(id)) : null);
  for (const p of catalog.products) {
    const stop = productStop(p, catalog);
    if (stop) { out.stops.push(stop); continue; }
    const l = live.get(p.id);
    if (!l) { out.create.push(p); planOffers(p, null, out, now); continue; }
    const s = liveShape(l);
    if (s.usCents !== cents(p.priceUsd)) { out.mismatches.push(`MISMATCH ${p.id}: Play US price ${s.usCents == null ? 'none' : usd(s.usCents)}, code ${usd(cents(p.priceUsd))}; left as it is (never repriced here)`); continue; }
    if (p.ceiling) for (const b of ceilingBreaks(p.ceiling, livePrices(l), pricesOf)) out.mismatches.push(`MISMATCH ${p.id}: costs more than ${p.ceiling.whole} with a part bought first, ${b}; left as it is`);
    if (s.state === 'INACTIVE' || s.state === 'INACTIVE_PUBLISHED') { out.inactive.push(`SWITCHED OFF ${p.id}: switched off on Play (${s.state}); left off. The app still sells it: switch it on in Play Console or take it out of the app code`); continue; }
    if (s.state === 'ACTIVE') out.ok.push(p); else out.activate.push({ ...p, optionId: s.optionId });
    planOffers(p, liveOffers.get(p.id) ?? [], out, now);
  }
  const ids = new Set(catalog.products.map(p => p.id));
  for (const l of liveProducts) if (!ids.has(l.productId)) out.extra.push(l.productId);
  return out;
}
function planOffers(p, have, out, now) {
  for (const o of p.offers ?? []) {
    const l = have?.find(x => x.offerId === o.id);
    if (l) { (l.state === 'DRAFT' ? out.offerActivate : out.offerOk).push({ product: p, offer: o, state: l.state }); continue; }
    if (!o.startTime) out.offerWaiting.push(`WAITING ${p.id}/${o.id}: the launch offer has no start date in the app code yet; nothing to create`);
    else if (Date.parse(o.endTime) <= now) out.offerWaiting.push(`ENDED ${p.id}/${o.id}: its window closed before it was created; not created`);
    else out.offerCreate.push({ product: p, offer: o });
  }
}
const work = pl => pl.create.length + pl.activate.length + pl.offerCreate.length + pl.offerActivate.length;
const counts = pl => `${pl.create.length} to create, ${pl.activate.length} to activate, ${pl.offerCreate.length + pl.offerActivate.length} offers to set up, ${pl.ok.length} already active, ${pl.mismatches.length} mismatches, ${pl.inactive.length} switched off, ${pl.stops.length} named stops`;
const verdict = pl => (pl.stops.length ? 2 : pl.mismatches.length || pl.inactive.length ? 1 : 0);

// ---- request bodies ------------------------------------------------------------------------------
/** The new product, priced per region (`prices`: region -> Money). */
export function productBody(packageName, p, prices, conv) {
  const other = conv?.convertedOtherRegionsPrice ?? {};
  return {
    packageName, productId: p.id,
    listings: [{ languageCode: p.languageCode ?? 'en-US', title: p.title, description: p.description }],
    purchaseOptions: [{
      purchaseOptionId: OPTION_ID,
      buyOption: { legacyCompatible: true, multiQuantityEnabled: false },
      regionalPricingAndAvailabilityConfigs: [...prices].map(([regionCode, price]) => ({ regionCode, price, availability: 'AVAILABLE' })),
      // New regions get Google's USD/EUR conversion; a product with a ceiling gets none, so no new region can break it.
      ...(!p.ceiling && other.usdPrice && other.eurPrice ? { newRegionsConfig: { usdPrice: other.usdPrice, eurPrice: other.eurPrice, availability: 'AVAILABLE' } } : {}),
    }],
  };
}
/** A discount offer on the buy option: US exactly the code's offer price, every other region the same fraction off. */
export function offerBody(packageName, p, o, liveProduct) {
  const regions = (buyOption(liveProduct)?.regionalPricingAndAvailabilityConfigs ?? []).filter(r => r.availability === 'AVAILABLE');
  const fraction = Math.round((1 - o.priceUsd / p.priceUsd) * 10_000) / 10_000;
  return {
    packageName, productId: p.id, purchaseOptionId: OPTION_ID, offerId: o.id,
    discountedOffer: { startTime: new Date(o.startTime).toISOString(), endTime: new Date(o.endTime).toISOString() },
    regionalPricingAndAvailabilityConfigs: regions.map(r => r.regionCode === 'US'
      ? { regionCode: 'US', availability: 'AVAILABLE', absoluteDiscount: money(p.priceUsd - o.priceUsd) }
      : { regionCode: r.regionCode, availability: 'AVAILABLE', relativeDiscount: fraction }),
  };
}

function printPlan(pl, log) {
  for (const s of pl.stops) log(s);
  for (const m of pl.mismatches) log(m);
  for (const m of pl.inactive) log(m);
  for (const p of pl.create) log(`create ${p.id} "${p.title}" ${usd(cents(p.priceUsd))} and activate`);
  for (const p of pl.activate) log(`activate ${p.id} (exists as a draft)`);
  for (const p of pl.ok) log(`ok ${p.id} active at ${usd(cents(p.priceUsd))}`);
  for (const { product, offer } of pl.offerCreate) log(`create offer ${product.id}/${offer.id} $${offer.priceUsd} from ${offer.startTime} to ${offer.endTime}`);
  for (const { product, offer } of pl.offerActivate) log(`activate offer ${product.id}/${offer.id} (exists as a draft)`);
  for (const { product, offer, state } of pl.offerOk) log(`ok offer ${product.id}/${offer.id} ${state} (left as it is)`);
  for (const w of pl.offerWaiting) log(w);
  for (const id of pl.extra) log(`on Play, not in the app code: ${id} (left alone)`);
}

/**
 * c = { app, packageName, products: [{ id, title, description, priceUsd, ceiling?, offers? }] }.
 *   ceiling = { whole: id, parts: [ids] }: in every region, any part plus this product costs no more than the whole.
 *   offers = [{ id, priceUsd, startTime, endTime }]: a launch discount; no startTime yet = WAITING.
 * getToken() returns a Play access token or '' (never printed). fetchFn is injectable for tests.
 * @param {{ app: string, packageName: string, products: any[] }} c
 * @param {{ argv?: string[], getToken: () => Promise<string>, fetchFn?: (url: string, init: any) => Promise<any>, log?: (line: string) => void, now?: number }} opts
 */
export async function run(c, { argv = process.argv.slice(2), getToken, fetchFn = fetch, log = console.log, now = Date.now() }) {
  const apply = argv.includes('--apply');
  const tag = `OUTPUT play-products ${c?.app ?? '?'}`;
  if (!c?.products?.length) { log(`${tag}: NAMED STOP [NO_PRODUCTS_IN_SOURCE] the app code lists no products`); return 1; }
  let token = '';
  try { token = await getToken(); } catch (e) { log(`${tag}: FAILED PLAY_TOKEN ${String(e?.message ?? e).slice(0, 300)}`); return 1; }
  if (!token) { log(`${tag}: NAMED STOP [PLAY_KEY_MISSING] no Play access token (GOOGLE_PLAY_UPLOAD_SA_JSON from the Boss OS vault)`); return 2; }

  const failures = [];
  let denied = false;
  const halted = () => failures.length > 0; // the first failure stops every further write
  const call = async (method, path, body, { missingOk = false } = {}) => {
    const where = `${method} ${path.split('?')[0]}`;
    let r, text = '';
    try {
      r = await fetchFn(`${API}/${c.packageName}${path}`, { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
      text = r.status === 204 ? '' : await r.text();
    } catch (e) { failures.push(`FAILED PLAY_NETWORK ${where}: ${String(e?.cause?.code ?? e?.message ?? e).slice(0, 200)}`); return null; }
    if (missingOk && r.status === 404) return NOT_FOUND;
    if (r.status === 401 || r.status === 403) denied = true;
    if (!r.ok) { failures.push(`FAILED PLAY_API_${r.status} ${where}${r.status === 429 ? ' (rate limited; a re-run finishes the rest)' : ''}: ${text.slice(0, 800)}`); return null; }
    if (!text) return {};
    try { return JSON.parse(text); } catch { failures.push(`FAILED PLAY_BAD_REPLY ${where}: ${r.status} but not JSON: ${text.slice(0, 200)}`); return null; }
  };
  const listAll = async (path, key) => {
    const all = [];
    let pageToken = '';
    do {
      const j = await call('GET', `${path}?pageSize=100${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ''}`);
      if (!j) return null;
      all.push(...(j[key] ?? []));
      pageToken = j.nextPageToken ?? '';
    } while (pageToken);
    return all;
  };
  const offersPath = id => `/oneTimeProducts/${id}/purchaseOptions/${OPTION_ID}/offers`;
  const readPlay = async () => {
    const products = await listAll('/oneTimeProducts', 'oneTimeProducts');
    if (!products) return null;
    const offers = new Map();
    for (const p of c.products) if (p.offers?.length && products.some(x => x.productId === p.id)) {
      const o = await listAll(offersPath(p.id), 'oneTimeProductOffers');
      if (!o) return null;
      offers.set(p.id, o);
    }
    return { products, offers };
  };
  const finish = (summary, code) => {
    for (const f of failures) log(f);
    const why = denied ? 'NAMED STOP [PLAY_PERMISSION_DENIED] Play refused the service account (Play Console > Users and permissions: "Manage store presence" on this app; a new grant can take up to 36 hours to reach the API); ' : '';
    log(`${tag}: ${why}${failures.length ? `FAILED (${failures.length}) ` : ''}${summary}`);
    return failures.length ? 1 : code;
  };

  const before = await readPlay();
  if (!before) return finish('could not read Play; nothing changed', 1);
  const pl = plan(c, before.products, before.offers, now);
  printPlan(pl, log);
  if (!apply) {
    const code = verdict(pl) || (work(pl) ? 3 : 0);
    return finish(`dry run on ${c.packageName}: ${counts(pl)}${work(pl) ? ' (Play lacks these: --apply writes them)' : ''}`, code);
  }

  const n = { created: 0, activated: 0, appeared: 0, offersCreated: 0, offersActivated: 0 };
  const conversions = new Map();
  const convert = async priceUsd => {
    if (!conversions.has(cents(priceUsd))) conversions.set(cents(priceUsd), await call('POST', '/pricing:convertRegionPrices', { price: money(priceUsd) }));
    return conversions.get(cents(priceUsd));
  };
  // The price Play holds for a product, or (for one not created yet) the price this run will give it.
  const planned = new Map();
  const liveById = new Map(before.products.map(p => [p.productId, p]));
  const pricesOf = id => (liveById.has(id) ? livePrices(liveById.get(id)) : planned.get(id) ?? null);
  const activate = (id, optionId) => call('POST', `/oneTimeProducts/${id}/purchaseOptions:batchUpdateStates`,
    { requests: [{ activatePurchaseOptionRequest: { packageName: c.packageName, productId: id, purchaseOptionId: optionId ?? OPTION_ID } }] });

  // Products a ceiling depends on go first, so their real prices are known when the capped one is priced.
  const order = [...pl.create].sort((a, b) => (a.ceiling ? 1 : 0) - (b.ceiling ? 1 : 0));
  for (const p of order) {
    if (halted()) break;
    const conv = await convert(p.priceUsd);
    if (!conv) break;
    if (!conv.regionVersion?.version) { failures.push(`FAILED ${p.id}: price conversion gave no region version`); break; }
    let prices = convertedPrices(p.priceUsd, conv);
    if (p.ceiling) {
      prices = capToCeiling(p.ceiling, prices, pricesOf);
      if (prices.get('US') && cents(amountOf(prices.get('US'))) !== cents(p.priceUsd)) { failures.push(`FAILED ${p.id}: the US price would have to change to stay under ${p.ceiling.whole}`); break; }
    }
    const fresh = await call('GET', `/oneTimeProducts/${p.id}`, undefined, { missingOk: true });
    if (fresh === null) break;
    if (fresh !== NOT_FOUND) { n.appeared++; liveById.set(p.id, fresh); log(`skip ${p.id}: it appeared on Play after the list was read; left exactly as it is`); continue; }
    const q = `allowMissing=true&regionsVersion.version=${encodeURIComponent(conv.regionVersion.version)}&updateMask=listings,purchaseOptions`;
    const made = await call('PATCH', `/onetimeproducts/${p.id}?${q}`, productBody(c.packageName, p, prices, conv));
    if (!made) break;
    n.created++;
    planned.set(p.id, prices);
    if (!(await activate(p.id))) break;
    n.activated++;
  }
  for (const p of pl.activate) { if (halted() || !(await activate(p.id, p.optionId))) break; n.activated++; }

  // Offers go on after their product is live; each is checked again right before it is written.
  for (const { product: p, offer: o } of pl.offerCreate) {
    if (halted()) break;
    const prod = await call('GET', `/oneTimeProducts/${p.id}`);
    if (!prod) break;
    const have = await listAll(offersPath(p.id), 'oneTimeProductOffers');
    if (!have) break;
    if (have.some(x => x.offerId === o.id)) { log(`skip offer ${p.id}/${o.id}: it appeared on Play after the list was read; left exactly as it is`); continue; }
    const made = await call('POST', `${offersPath(p.id)}:batchUpdate`, { requests: [{ oneTimeProductOffer: offerBody(c.packageName, p, o, prod),
      regionsVersion: prod.regionsVersion, allowMissing: true, updateMask: 'discountedOffer,regionalPricingAndAvailabilityConfigs' }] });
    if (!made) break;
    n.offersCreated++;
    if (!(await activateOffer(p.id, o.id))) break;
    n.offersActivated++;
  }
  for (const { product: p, offer: o } of pl.offerActivate) { if (halted() || !(await activateOffer(p.id, o.id))) break; n.offersActivated++; }
  function activateOffer(id, offerId) {
    return call('POST', `${offersPath(id)}:batchUpdateStates`, { requests: [{ activateOneTimeProductOfferRequest: { packageName: c.packageName, productId: id, purchaseOptionId: OPTION_ID, offerId } }] });
  }

  // Read back: what Play now holds for the code, and a second plan that must have nothing left to do.
  const done = `created ${n.created}, activated ${n.activated}, offers ${n.offersCreated} created / ${n.offersActivated} activated${n.appeared ? `, ${n.appeared} appeared meanwhile (left alone)` : ''}`;
  const after = await readPlay();
  if (!after) return finish(`${done}; read-back failed`, 1);
  const byId = new Map(after.products.map(p => [p.productId, liveShape(p)]));
  for (const p of c.products) {
    const s = byId.get(p.id);
    log(s ? `read-back ${p.id}: ${s.state} ${s.usCents == null ? 'no US price' : usd(s.usCents)} "${s.title}"` : `read-back ${p.id}: NOT ON PLAY`);
  }
  const again = plan(c, after.products, after.offers, now);
  for (const m of [...again.mismatches, ...again.inactive]) log(m);
  if (work(again)) {
    if (failures.length) log(`left for the re-run: ${counts(again)}`); // the failure above already explains it
    else failures.push(`FAILED READBACK_NOT_CLEAN: ${counts(again)}`); // every write was accepted, yet Play does not hold it
  }
  const activeCount = c.products.filter(p => byId.get(p.id)?.state === 'ACTIVE').length;
  return finish(`applied on ${c.packageName}: ${done}; read-back ${activeCount}/${c.products.length} active, ${again.mismatches.length} mismatches, ${again.inactive.length} switched off, ${again.stops.length} named stops`, verdict(again));
}

// ---- command line: play-products <catalog module> [--apply] ----------------------------------------
export async function main(argv = process.argv.slice(2), log = console.log) {
  const file = argv.find(a => !a.startsWith('--'));
  try {
    const mod = await import(pathToFileURL(resolve(file)).href);
    if (!mod.catalog) { log(`OUTPUT play-products: NAMED STOP [CATALOG_MISSING] ${file} exports no \`catalog\``); return 2; }
    return await run(mod.catalog, { argv, log, getToken: () => googleAccessToken('GOOGLE_PLAY_UPLOAD_SA_JSON', 'https://www.googleapis.com/auth/androidpublisher') });
  } catch (e) {
    log(`OUTPUT play-products: FAILED UNEXPECTED ${String(e?.stack ?? e).split('\n').slice(0, 3).join(' | ').slice(0, 400)}`);
    return 1;
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(code => { process.exitCode = code; });
