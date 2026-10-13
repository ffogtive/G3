// Web oracle driver (Playwright + Chromium) for tools/export-content.mjs.
//
// The frozen web build is loaded from the static server with VIRTUAL TIME: requestAnimationFrame, setTimeout,
// setInterval, performance.now and Date.now are replaced before any page script runs, and Math.random is a seeded
// mulberry32. Frames are then pumped one by one from here, so (a) the spawn can be read before the first frame, and
// (b) a run is bit-for-bit repeatable. The game's own loop is untouched: main.js frame(now) still computes
// dt = min(0.05, (now - last)/1000) — the web's VARIABLE-dt model — we just choose `now`.
import { createRequire } from 'node:module';
import { spawnView } from './goldens.mjs';

const require = createRequire(import.meta.url);
function loadPlaywright() {
  for (const p of ['playwright', '/opt/node22/lib/node_modules/playwright']) { try { return require(p); } catch { /* next */ } }
  throw new Error('playwright not found (expected /opt/node22/lib/node_modules/playwright)');
}

export const MATH_RANDOM_SEED = 0x5eed1007;
const INIT_SCRIPT = (seed) => `(() => {
  let a = ${seed} | 0;
  Math.random = function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const realSetTimeout = window.setTimeout.bind(window);
  const V = { t: 0, seq: 0, timers: [], rafs: [], frames: 0 };
  Object.defineProperty(window, '__V', { value: V });
  const now = () => V.t;
  try { performance.now = now; } catch (e) { /* fallthrough */ }
  if (performance.now !== now) Object.defineProperty(performance, 'now', { value: now, configurable: true });
  const EPOCH = 1767225600000;
  Date.now = () => EPOCH + Math.floor(V.t);
  window.setTimeout = (fn, ms, ...args) => { const id = ++V.seq; V.timers.push({ id, due: V.t + Math.max(0, Number(ms) || 0), fn, args, every: 0 }); return id; };
  window.setInterval = (fn, ms, ...args) => { const id = ++V.seq; const every = Math.max(1, Number(ms) || 0); V.timers.push({ id, due: V.t + every, fn, args, every }); return id; };
  window.clearTimeout = window.clearInterval = (id) => { V.timers = V.timers.filter((x) => x.id !== id); };
  window.requestAnimationFrame = (cb) => { const id = ++V.seq; V.rafs.push({ id, cb }); return id; };
  window.cancelAnimationFrame = (id) => { V.rafs = V.rafs.filter((x) => x.id !== id); };
  const yieldReal = () => new Promise((r) => realSetTimeout(r, 0));   // lets microtasks (promise .then) settle like a real task boundary
  V.runTimers = async () => {
    for (;;) {
      const due = V.timers.filter((x) => x.due <= V.t).sort((p, q) => p.due - q.due || p.id - q.id);
      if (!due.length) return;
      const x = due[0];
      if (x.every) x.due += x.every; else V.timers = V.timers.filter((y) => y !== x);
      try { if (typeof x.fn === 'function') x.fn(...x.args); } catch (e) { console.error(e); }
      await yieldReal();
    }
  };
  V.frame = async (dtMs) => {
    V.t += dtMs;
    await V.runTimers();
    const list = V.rafs; V.rafs = [];
    for (const r of list) { try { r.cb(V.t); } catch (e) { console.error(e); } }
    V.frames++;
    await yieldReal();
  };
})();`;

async function openGame(url, { log = () => {} } = {}) {
  const pw = loadPlaywright();
  const browser = await pw.chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'] });
  const page = await browser.newPage({ viewport: { width: 320, height: 180 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`[console] ${m.text()}`); });
  const origin = new URL(url).origin;
  // only the local static server; external fonts etc. are aborted so the run never depends on the network
  await page.route((u) => !u.href.startsWith(origin + '/'), (r) => r.abort());
  await page.addInitScript(INIT_SCRIPT(MATH_RANDOM_SEED));
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  const t0 = Date.now();
  for (;;) {
    const ph = await page.evaluate(() => (window.__game ? window.__game.phase : null));
    if (ph && ph !== 'boot') break;
    if (Date.now() - t0 > 30000) throw new Error(`web oracle: game did not leave boot (phase=${ph}); errors: ${errors.join(' | ')}`);
    await new Promise((r) => setTimeout(r, 100));
  }
  log(`web: booted ${url} in ${Date.now() - t0} ms`);
  return { browser, page, errors };
}

/** Spawn as seen by the live web page before its first frame + the next value of the traffic RNG. */
export async function webSpawn(baseUrl, stageId, opts = {}) {
  const url = `${baseUrl}/game/index.html?stage=${stageId}&mute=1`;
  const { browser, page, errors } = await openGame(url, opts);
  try {
    const r = await page.evaluate(({ src }) => {
      const view = (0, eval)(`(${src})`);
      const G = window.__game;
      const frames = window.__V.frames;
      const out = view(G.objs.traffic, G.objs.boss, G.objs.player);
      const next = G.objs.traffic.rng();
      return { view: out, next, frames, phase: G.phase };
    }, { src: spawnView.toString() });
    if (r.frames !== 0) throw new Error(`web oracle: ${r.frames} frames ran before the spawn snapshot`);
    return { ...r, errors, url };
  } finally { await browser.close(); }
}

/**
 * Records `nTicks` calls of Traffic.update in the live web game: the exact inputs it got (dt, time, phase,
 * player, villains, extras) and the resulting car/opp state + the RNG draws made inside (raw stacks → tagged in Node).
 */
export async function webTicks(baseUrl, stageId, nTicks, { query = 'skip=jam', frameMs = 1000 / 120, log = () => {} } = {}) {
  const url = `${baseUrl}/game/index.html?stage=${stageId}&mute=1${query ? '&' + query : ''}`;
  const { browser, page, errors } = await openGame(url, { log });
  try {
    await page.evaluate(async () => {
      const C = await import('/game/js/config.js');
      const G = window.__game, T = G.objs.traffic, proto = Object.getPrototypeOf(T);
      const R = { ticks: [], outside: [], carIds: T.cars.map((c) => c.id), phase0: G.phase, spawnDraws: null };
      window.__REC = R;
      let draws = null;
      const baseRng = T.rng;
      T.rng = function rng() {
        const v = baseRng();
        const e = [new Error().stack, Math.round(v * 4294967296)];
        if (draws) draws.push(e); else R.outside.push([R.ticks.length, ...e]);
        return v;
      };
      T.update = function update(dt, ctx) {
        const p = ctx.player;
        const inp = {
          dt, time: ctx.time, phase: ctx.phase, allowEvents: !!ctx.allowEvents, jamLike: !!ctx.jamLike, focusS: ctx.focusS ?? null,
          player: { s: p.s, x: p.x, w: p.w, len: p.len, lane: p.lane, v: p.v, mode: p.mode },
          villains: (ctx.villains || []).map((v) => ({ s: v.s, baseS: v.baseS, x: v.x, w: v.w, len: v.len, v: v.v, vNominal: v.vNominal, alive: v.alive })),
          extras: (ctx.extras || []).map((e) => ({ s: e.s, x: e.x, w: e.w, len: e.len, v: e.v, alive: e.alive })),
        };
        draws = [];
        try { return proto.update.call(this, dt, ctx); } finally {
          const out = {
            s: this.cars.map((c) => c.s), v: this.cars.map((c) => c.v), lane: this.cars.map((c) => c.lane), x: {},
            opp_s: this.opp.map((c) => c.s), obstacles: this.obstacles.length, rngRaw: draws,
          };
          for (const c of this.cars) if (c.x !== C.laneX(c.lane)) out.x[c.id] = c.x;
          draws = null;
          R.ticks.push({ i: R.ticks.length, in: inp, out });
        }
      };
    });
    const t0 = Date.now();
    for (let f = 0; ; f++) {
      const n = await page.evaluate(async (ms) => { await window.__V.frame(ms); return window.__REC.ticks.length; }, frameMs);
      if (n >= nTicks) break;
      if (f > nTicks * 3) throw new Error('web oracle: frames are not producing traffic ticks');
      if (f % 100 === 0) log(`web: frame ${f}, ticks ${n}, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    }
    const rec = await page.evaluate((n) => { const R = window.__REC; return { ...R, ticks: R.ticks.slice(0, n), phaseEnd: window.__game.phase }; }, nTicks);
    return { ...rec, errors, url };
  } finally { await browser.close(); }
}
