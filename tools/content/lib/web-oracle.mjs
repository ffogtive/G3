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
 * Mutating Traffic calls made from OUTSIDE update (main.js: honk, rageHorn, miniHit, smash, release, dropWalls, jolt,
 * emitBrakeWave) are recorded as events between ticks with the player state at call time, their RNG draws and a
 * summary of their return value; obstacles removed directly by main.js (tow splice) show up as in.obstacleIds.
 * noDraw: replace renderer.render with the scene/camera matrix updates it performs (game logic sees the same matrices).
 */
export async function webTicks(baseUrl, stageId, nTicks, { query = 'skip=jam', frameMs = 1000 / 120, noDraw = false, log = () => {} } = {}) {
  const url = `${baseUrl}/game/index.html?stage=${stageId}&mute=1${query ? '&' + query : ''}`;
  const { browser, page, errors } = await openGame(url, { log });
  try {
    await page.evaluate(async ({ noDraw }) => {
      const C = await import('/game/js/config.js');
      const G = window.__game, T = G.objs.traffic, proto = Object.getPrototypeOf(T);
      if (noDraw) {
        G.objs.renderer.render = (scene, camera) => {
          if (scene.matrixWorldAutoUpdate === true) scene.updateMatrixWorld();
          if (camera.parent === null && camera.matrixWorldAutoUpdate === true) camera.updateMatrixWorld();
        };
      }
      const R = { ticks: [], events: [], outside: [], carIds: T.cars.map((c) => c.id), phase0: G.phase };
      window.__REC = R;
      let cur = null;      // draw sink of the call being recorded (update or event)
      let depth = 0;
      const baseRng = T.rng;
      T.rng = function rng() {
        const v = baseRng();
        const e = [new Error().stack, Math.round(v * 4294967296)];
        if (cur) cur.push(e); else R.outside.push([R.ticks.length, ...e]);
        return v;
      };
      const P = G.objs.player;
      const snapPlayer = (p) => ({ s: p.s, x: p.x, w: p.w, len: p.len, lane: p.lane, v: p.v, mode: p.mode, lcT: p.lcT, stats: { tow: !!p.stats?.tow, siren: !!p.stats?.siren } });
      const ser = (a) => {
        if (a === undefined) return { $undef: true };
        if (a === P) return '$player';
        if (a && typeof a === 'object') {
          if (T.cars.includes(a)) return { $car: a.id };
          if (T.obstacles.includes(a)) return { $obs: a.id };
          if (a.isVillain) return { $villain: a.index };
          if (Array.isArray(a)) return a.map(ser);
          return Object.fromEntries(Object.entries(a).filter(([, v]) => v === null || typeof v !== 'object' || Array.isArray(v)).map(([k, v]) => [k, ser(v)]));
        }
        return a;
      };
      const ids = (arr) => (arr || []).map((x) => x && (x.id ?? (x === P ? '$player' : x.isVillain ? `$villain${x.index}` : null)));
      const summarize = (name, r) => {
        if (r == null) return r ?? null;
        if (name === 'rageHorn') return { smashed: ids(r.smashed), towed: ids(r.towed), cheaters: ids(r.cheaters), startled: ids(r.startled) };
        if (name === 'smash') return { pieces: r.pieces.length };
        if (name === 'honk' || name === 'letIn') return r.car ? { kind: r.kind, car: ids([r.car])[0] } : { car: ids([r])[0] };
        return typeof r === 'object' ? null : r;
      };
      let obsIds = T.obstacles.map((o) => o.id);
      for (const name of ['honk', 'rageHorn', 'miniHit', 'smash', 'release', 'dropWalls', 'jolt', 'emitBrakeWave', 'letIn']) {
        T[name] = function (...args) {
          if (depth > 0) return proto[name].apply(this, args);
          const ev = { tick: R.ticks.length, m: name, args: args.map(ser), player: snapPlayer(P), rngRaw: [] };
          const prev = cur; cur = ev.rngRaw; depth++;
          try { const r = proto[name].apply(this, args); ev.ret = summarize(name, r); return r; } finally {
            depth--; cur = prev; R.events.push(ev); obsIds = T.obstacles.map((o) => o.id);
          }
        };
      }
      T.update = function update(dt, ctx) {
        const p = ctx.player;
        const inp = {
          dt, time: ctx.time, phase: ctx.phase, allowEvents: !!ctx.allowEvents, jamLike: !!ctx.jamLike, focusS: ctx.focusS ?? null,
          player: { s: p.s, x: p.x, w: p.w, len: p.len, lane: p.lane, v: p.v, mode: p.mode },
          villains: (ctx.villains || []).map((v) => ({ s: v.s, baseS: v.baseS, x: v.x, w: v.w, len: v.len, v: v.v, vNominal: v.vNominal, alive: v.alive })),
          extras: (ctx.extras || []).map((e) => ({ s: e.s, x: e.x, w: e.w, len: e.len, v: e.v, alive: e.alive })),
          // Math.sin of the packed-lane stop&go factor, same expression as traffic.js:406 (t = ctx.time, lane 0..4).
          // Recorded because libm sin differs between engines in the last ulp (see golden.math).
          sinLf: [0, 1, 2, 3, 4].map((l) => Math.sin(ctx.time * 0.42 + l * 1.9)),
        };
        const nowIds = this.obstacles.map((o) => o.id);
        if (nowIds.join() !== obsIds.join()) inp.obstacleIds = nowIds;   // removed directly by main.js (e.g. tow splice)
        const draws = [];
        const prev = cur; cur = draws; depth++;
        try { return proto.update.call(this, dt, ctx); } finally {
          depth--; cur = prev;
          const out = {
            s: this.cars.map((c) => c.s), v: this.cars.map((c) => c.v), lane: this.cars.map((c) => c.lane), xs: this.cars.map((c) => c.x), x: {},
            opp_s: this.opp.map((c) => c.s), obstacles: this.obstacles.length, rngRaw: draws,
          };
          for (const c of this.cars) if (c.x !== C.laneX(c.lane)) out.x[c.id] = c.x;
          obsIds = this.obstacles.map((o) => o.id);
          R.ticks.push({ i: R.ticks.length, in: inp, out, phaseAfter: G.phase });
        }
      };
    }, { noDraw });
    const t0 = Date.now();
    for (let f = 0; ; f++) {
      const n = await page.evaluate(async (ms) => { await window.__V.frame(ms); return window.__REC.ticks.length; }, frameMs);
      if (n >= nTicks) break;
      if (f > nTicks * 3) throw new Error('web oracle: frames are not producing traffic ticks');
      if (f % 200 === 0) log(`web: frame ${f}, ticks ${n}, phase ${await page.evaluate(() => window.__game.phase)}, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    }
    const rec = await page.evaluate((n) => { const R = window.__REC; return { ...R, ticks: R.ticks.slice(0, n), events: R.events.filter((e) => e.tick < n), phaseEnd: window.__game.phase }; }, nTicks);
    return { ...rec, errors, url };
  } finally { await browser.close(); }
}
