// Web reference shot for the native jam look (NATIVE_PORT 2 "T2 웹 동일 카메라 샷 쌍", M1a).
//
// 가설: the frozen web build driven by a virtual clock gives a repeatable frame; dumping its camera + car state lets
//       native/tests/shot_jam.gd rebuild the SAME moment from the SAME camera, so a side-by-side compares only the look.
//
//   node native/view/dev/web_shot.mjs --out=<dir> [--t=6] [--w=585] [--h=1266] [--url=http://localhost:8090/game/index.html]
//
// Writes <dir>/web_jam.png (canvas only, HUD hidden), <dir>/web_jam_ui.png (with the DOM HUD) and
// <dir>/web_state.json (camera, player, cars, opposite cars, obstacles, villains at that frame).
// Needs the static server on :8090 serving the repo root and Playwright Chromium (swiftshader).
// Lives in native/view/dev/ (.gdignore) because the view owner owns no repo-root tools/ path except bake-audio.mjs.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
function loadPlaywright() {
  for (const p of ['playwright', '/opt/node22/lib/node_modules/playwright']) { try { return require(p); } catch { /* next */ } }
  throw new Error('playwright not found');
}
const arg = (k, d) => { const a = process.argv.find((x) => x.startsWith(`--${k}=`)); return a ? a.slice(k.length + 3) : d; };
const OUT = path.resolve(arg('out', '.'));
const T = +arg('t', 6);
const W = +arg('w', 585), H = +arg('h', 1266);
const URL0 = arg('url', 'http://localhost:8090/game/index.html') + '?stage=1&mute=1&skip=jam';
const FRAME_MS = 1000 / 60;

// virtual clock + seeded Math.random (same scheme as tools/content/lib/web-oracle.mjs)
const INIT = `(() => {
  let a = 0x5eed1007 | 0;
  Math.random = function () { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const realSetTimeout = window.setTimeout.bind(window);
  const V = { t: 0, seq: 0, timers: [], rafs: [] };
  Object.defineProperty(window, '__V', { value: V });
  const now = () => V.t;
  try { performance.now = now; } catch (e) {}
  if (performance.now !== now) Object.defineProperty(performance, 'now', { value: now, configurable: true });
  Date.now = () => 1767225600000 + Math.floor(V.t);
  window.setTimeout = (fn, ms, ...args) => { const id = ++V.seq; V.timers.push({ id, due: V.t + Math.max(0, Number(ms) || 0), fn, args, every: 0 }); return id; };
  window.setInterval = (fn, ms, ...args) => { const id = ++V.seq; const every = Math.max(1, Number(ms) || 0); V.timers.push({ id, due: V.t + every, fn, args, every }); return id; };
  window.clearTimeout = window.clearInterval = (id) => { V.timers = V.timers.filter((x) => x.id !== id); };
  window.requestAnimationFrame = (cb) => { const id = ++V.seq; V.rafs.push({ id, cb }); return id; };
  window.cancelAnimationFrame = (id) => { V.rafs = V.rafs.filter((x) => x.id !== id); };
  V.frame = (dtMs) => {
    V.t += dtMs;
    for (;;) {
      const due = V.timers.filter((x) => x.due <= V.t).sort((p, q) => p.due - q.due || p.id - q.id);
      if (!due.length) break;
      const x = due[0];
      if (x.every) x.due += x.every; else V.timers = V.timers.filter((y) => y !== x);
      try { x.fn(...x.args); } catch (e) { console.error(e); }
    }
    const list = V.rafs; V.rafs = [];
    for (const r of list) { try { r.cb(V.t); } catch (e) { console.error(e); } }
  };
})();`;

const pw = loadPlaywright();
const browser = await pw.chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1, hasTouch: true, isMobile: true });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
const origin = new URL(URL0).origin;
await page.route((u) => !u.href.startsWith(origin + '/'), (r) => r.abort());
await page.addInitScript(INIT);
await page.goto(URL0, { waitUntil: 'load', timeout: 60000 });
for (let i = 0; i < 300; i++) {
  const ph = await page.evaluate(() => window.__game?.phase ?? null);
  if (ph && ph !== 'boot') break;
  await page.evaluate(() => window.__V.frame(16));
  await new Promise((r) => setTimeout(r, 50));
}
// fast-forward without drawing (draw cost dominates under swiftshader), then draw the last 8 frames for real
const n = Math.round(T * 1000 / FRAME_MS);
await page.evaluate(async ({ n, ms }) => {
  const r = window.__game.objs.renderer, real = r.render.bind(r);
  r.render = () => {};
  for (let i = 0; i < n - 8; i++) window.__V.frame(ms);
  r.render = real;
  for (let i = 0; i < 8; i++) window.__V.frame(ms);
}, { n, ms: FRAME_MS });

const state = await page.evaluate(() => {
  const G = window.__game, { camera, traffic, player, boss, world } = G.objs;
  const e = camera.matrixWorld.elements; // column-major; -Z column = forward
  const fwd = [-e[8], -e[9], -e[10]];
  const pos = [camera.position.x, camera.position.y, camera.position.z];
  const lampOf = (m) => {
    const ud = m?.userData || {};
    const vis = (o) => !!(o && o.visible !== false);
    const bl = ud.blinkers || [];
    return {
      brake: ud.brake ? ud.brake.material?.color?.getHex?.() === 0xffffff : false,
      hazard: ud.hazard ? ud.hazard.material?.color?.getHex?.() === 0xffffff : false,
      head: ud.head ? ud.head.material?.color?.getHex?.() === 0xffffff : false,
      blinkL: vis(bl[0]), blinkR: vis(bl[1]),
    };
  };
  const car = (c) => ({ id: c.id, kind: c.kind, lane: c.lane, x: c.x, s: c.s, yaw: c.yaw || 0, v: c.v, blinkSide: c.blinkSide || null,
    pitch: c.mesh?.userData?.body?.rotation?.x || 0, ...lampOf(c.mesh) });
  return {
    t: G.time, realTime: G.realTime, phase: G.phase,
    camera: { pos, fwd, up: [e[4], e[5], e[6]], fov: camera.fov, aspect: camera.aspect, near: camera.near, far: camera.far },
    player: { x: player.x, s: player.s, v: player.v, lane: player.lane, yaw: player.mesh?.rotation?.y || 0, ...lampOf(player.mesh) },
    cars: traffic.cars.map(car),
    opp: traffic.opp.map((c) => ({ ...car(c), rotY: c.mesh?.rotation?.y || 0, worldX: c.mesh?.position?.x, worldZ: c.mesh?.position?.z })),
    obstacles: traffic.obstacles.map((o) => ({ id: o.id, kind: o.kind, s: o.s, x: o.x, len: o.len,
      hazard: o.hazardCar ? lampOf(o.hazardCar).hazard : false })),
    villains: boss.villains.map((v) => ({ kind: v.kind, x: v.x, s: v.s, px: v.mesh.position.x, pz: v.mesh.position.z, yaw: v.mesh.rotation.y, ...lampOf(v.mesh) })),
    sun: world.sunDir ? [world.sunDir.x, world.sunDir.y, world.sunDir.z] : null,
    canvas: [G.objs.renderer.domElement.width, G.objs.renderer.domElement.height],
  };
});
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, 'web_state.json'), JSON.stringify(state, null, 1));
const hide = await page.addStyleTag({ content: 'body > *:not(#game){display:none !important}' });
await page.screenshot({ path: path.join(OUT, 'web_jam.png') });
await hide.evaluate((n) => n.remove());
await page.screenshot({ path: path.join(OUT, 'web_jam_ui.png') });
console.log(`web_shot: t=${state.t.toFixed(3)} phase=${state.phase} cars=${state.cars.length} cam=${state.camera.pos.map((v) => v.toFixed(2))} fov=${state.camera.fov.toFixed(2)}`);
if (errors.length) console.log('page errors:', errors.slice(0, 5).join(' | '));
await browser.close();
