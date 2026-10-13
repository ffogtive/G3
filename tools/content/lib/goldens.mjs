// Node side of the goldens (NATIVE_PORT 3-3 / 4-2 T0): spawn layouts, tagged RNG traces, tick-golden replay.
// Runs the frozen web modules unmodified (real vehicles.js through vehicles-spy.mjs, which only records specs).
import { f17 } from './stable-json.mjs';
import { tracingRng, tagOf, siteStr } from './rng-trace.mjs';
import { resolveVariant } from './vehicle-kinds.mjs';

/**
 * Plain function (no closure over module scope) so it can be sent into the browser with toString():
 * the fields both the Node run and the live web page can see on traffic / boss / player.
 */
export function spawnView(T, B, P) {
  const n = (x) => (x === undefined ? null : x);
  return {
    cars: T.cars.map((c) => ({
      id: c.id, kind: c.kind, lane: c.lane, x: c.x, s: c.s, v: c.v, len: c.len, w: c.w,
      isWall: c.isWall, wallOffset: n(c.wallOffset), isCheater: c.isCheater, cheaterV: n(c.cheaterV),
      personal: c.personal, phase: c.phase, slow: c.slow, lcT: c.lcT, lcDur: c.lcDur, vFree: c.vFree,
      mini: c.mini ? { type: c.mini.type, hp: c.mini.hp, max: c.mini.max, cool: c.mini.cool } : null,
    })),
    obstacles: T.obstacles.map((o) => ({ id: o.id, kind: o.kind, s: o.s, x: o.x, len: o.len, w: o.w, smash: o.smash, hazard: !!o.hazardCar })),
    opp: T.opp.map((c) => ({ j: c.j, s: c.s, v: c.v })),
    villains: B.villains.map((v) => ({
      index: v.index, kind: v.kind, lanePos: v.lanePos, x: v.x, s: v.s, baseS: v.baseS, len: v.len, w: v.w, h: v.h,
      v: v.v, vNominal: v.vNominal, stopped: v.stopped, zig: v.zig, hp: v.hp,
    })),
    player: { kind: P.vkind, s: P.s, lane: P.lane, x: P.x, len: P.len, w: P.w, v: P.v },
    traffic: {
      sTail: T.sTail, frontLine: T.frontLine, frontV: T.frontV, jamSpeed: T.jamSpeed, laneKind: T.laneKind,
      zigzag: T.zigzag, shoulderClosed: T.shoulderClosed, night: T.night,
      approach: Object.fromEntries(Object.entries(T.approach).filter(([k]) => k !== 'hint')),
    },
  };
}

/** main.js setupStage, minus world/fx/ui (none of which touch the traffic RNG). */
export function setupLikeWeb(M, stage, rng) {
  const { THREE, CFG, Traffic, BossManager, Player } = M;
  const scene = new THREE.Scene();
  const A = { ...CFG.TUNE.approach, ...(stage.approach || {}) };
  const noShoulder = ['closed', 'none'].includes(A.shoulder);
  const jamLen = noShoulder ? Math.min(stage.jamLength, A.jamLength ?? 85) : stage.jamLength;
  const startS = 0;
  const startLane = noShoulder ? (A.startLane ?? 1) : 3;
  const frontS = startS + jamLen + 30;
  const night = !!(CFG.SKY[stage.sky] || CFG.SKY.day).night;
  const boss = new BossManager(scene, { /* fx stub */ }, { play() {} });
  boss.night = night;
  boss.spawn(stage, frontS);
  const traffic = new Traffic(scene);
  const player = new Player(scene);
  traffic.spawnJam(stage, boss.villains, { s: startS, lane: startLane }, rng, night);
  player.reset(startS, startLane);
  return { traffic, boss, player, setup: { startS, startLane, jamLen, frontS, night, noShoulder, seed: stage.id * 1000 + 7 } };
}

/** Full spawn golden for one stage + its tagged RNG trace. Must run in a fresh process (CAR_ID is module state). */
export function spawnGolden(M, stageId, VK) {
  const stage = M.STAGES.find((s) => s.id === stageId);
  if (!stage) throw new Error(`no stage ${stageId}`);
  const seed = stage.id * 1000 + 7;
  const log = [];
  const base = M.mulberry32(seed);
  const rng = tracingRng(base, log);
  const { traffic, boss, player, setup } = setupLikeWeb(M, stage, rng);
  const next = base();
  const view = spawnView(traffic, boss, player);
  // spec details only visible in Node (vehicles-spy): color/seed/variant per car, obstacle internals, opp kinds
  view.cars.forEach((c, i) => {
    const spec = traffic.cars[i].mesh.userData.__spec;
    c.color = spec.opts.color >>> 0;
    c.seed = spec.opts.seed;
    c.variant = resolveVariant(VK, c.kind, spec.opts);
    c.frontRow = c.isWall;
  });
  view.obstacles.forEach((o, i) => {
    const g = traffic.obstacles[i].mesh;
    if (o.kind === 'breakdown') {
      const car = g.children[0], spec = car.userData.__spec;
      o.detail = { carKind: spec.kind, color: spec.opts.color >>> 0, variant: resolveVariant(VK, spec.kind, spec.opts), rotY: car.rotation.y, carLen: car.userData.length, triangle: g.children.length > 1 };
    } else if (o.kind === 'debris') {
      const kids = g.children;
      o.detail = { boxes: kids.slice(0, -1).map((b) => ({ x: b.position.x, z: b.position.z, rotY: b.rotation.y })), tireX: kids[kids.length - 1].position.x };
    } else o.detail = { pieces: g.children.length };
  });
  view.opp.forEach((c, i) => { const spec = traffic.opp[i].mesh.userData.__spec; c.kind = spec.kind; c.color = spec.opts.color >>> 0; });
  view.villains.forEach((v, i) => { v.color = boss.villains[i].spec.color >>> 0; v.name = boss.villains[i].name; });
  const frontRow = [0, 1, 2, 3].map((l) => { const c = view.cars.find((x) => x.isWall && x.lane === l); return c ? c.id : null; });
  const trace = log.map((e, i) => ({ i, tag: tagOf(e.site, e.caller), site: siteStr(e.site), caller: siteStr(e.caller), u32: e.u32, f: f17(e.u32 / 4294967296) }));
  const counts = {};
  for (const t of trace) counts[t.tag] = (counts[t.tag] || 0) + 1;
  return {
    spawn: {
      stage: stageId, title: stage.title, setup, frontRow,
      counts: { cars: view.cars.length, walls: frontRow.filter((x) => x != null).length, cheaters: view.cars.filter((c) => c.isCheater).length, minis: view.cars.filter((c) => c.mini).length, obstacles: view.obstacles.length, opp: view.opp.length },
      rng: { seed, draws: log.length, next: { u32: Math.round(next * 4294967296), f: f17(next) } },
      ...view,
    },
    trace: { stage: stageId, seed, algorithm: 'mulberry32', draws: log.length, next_u32: Math.round(next * 4294967296), tag_counts: counts, calls: trace },
  };
}

/**
 * Replays a recorded tick golden through the Node traffic core: same spawn, then for every tick the recorded
 * inputs (player, villains, extras, phase, time, dt). Proves the golden is a sufficient spec for the C++ port.
 * @returns {{ ok: boolean, ticks: number, firstDiff: string|null }}
 */
const SIN = Math.sin;
export function replayTicks(M, golden) {
  const stage = M.STAGES.find((s) => s.id === golden.stage);
  const log = [];
  const base = M.mulberry32(stage.id * 1000 + 7);
  const rng = tracingRng(base, log);
  const { traffic } = setupLikeWeb(M, stage, rng);
  if (JSON.stringify(traffic.cars.map((c) => c.id)) !== JSON.stringify(golden.car_ids)) return { ok: false, ticks: 0, firstDiff: 'car ids differ after spawn' };
  const spawnDraws = log.length;
  if (spawnDraws !== golden.spawn_rng_draws) return { ok: false, ticks: 0, firstDiff: `spawn rng draws ${spawnDraws} != ${golden.spawn_rng_draws}` };
  const player = { isPlayer: true };
  const villains = golden.ticks[0].in.villains.map(() => ({ isVillain: true }));
  const extras = [];
  let mark = log.length;
  for (const tk of golden.ticks) {
    Object.assign(player, tk.in.player);
    tk.in.villains.forEach((v, i) => Object.assign(villains[i], v));
    extras.length = 0;
    for (const e of tk.in.extras) extras.push({ ...e });
    // libm independence: the only transcendental that feeds the sim state is sin(t*0.42 + lane*1.9) (traffic.js:406);
    // take it from the recording, exactly as a C++ replay must (V8 builds differ: Node=fdlibm, Chrome=glibc port).
    const lfArgs = tk.in.sinLf.map((_, l) => tk.in.time * 0.42 + l * 1.9);
    Math.sin = (x) => { const k = lfArgs.indexOf(x); return k >= 0 ? tk.in.sinLf[k] : SIN(x); };
    try {
      traffic.update(tk.in.dt, { dt: tk.in.dt, time: tk.in.time, player, villains, extras, phase: tk.in.phase, allowEvents: tk.in.allowEvents, jamLike: tk.in.jamLike, focusS: tk.in.focusS });
    } finally { Math.sin = SIN; }
    const drawn = log.slice(mark).map((e) => [tagOf(e.site, e.caller), e.u32]);
    mark = log.length;
    const o = tk.out;
    const cmp = (name, a, b) => { for (let i = 0; i < Math.max(a.length, b.length); i++) if (a[i] !== b[i]) return `tick ${tk.i} ${name}[${i}]: replay ${a[i]} != web ${b[i]}`; return null; };
    const d = cmp('s', traffic.cars.map((c) => c.s), o.s) || cmp('v', traffic.cars.map((c) => c.v), o.v)
      || cmp('lane', traffic.cars.map((c) => c.lane), o.lane) || cmp('opp_s', traffic.opp.map((c) => c.s), o.opp_s)
      || cmp('x', traffic.cars.map((c) => c.x), traffic.cars.map((c, i) => (o.x[c.id] !== undefined ? o.x[c.id] : M.CFG.laneX(o.lane[i]))))
      || (traffic.obstacles.length !== o.obstacles ? `tick ${tk.i} obstacles ${traffic.obstacles.length} != ${o.obstacles}` : null)
      || (JSON.stringify(drawn) !== JSON.stringify(o.rng) ? `tick ${tk.i} rng draws ${JSON.stringify(drawn)} != ${JSON.stringify(o.rng)}` : null);
    if (d) return { ok: false, ticks: tk.i, firstDiff: d };
  }
  return { ok: true, ticks: golden.ticks.length, firstDiff: null };
}
