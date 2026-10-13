#!/usr/bin/env node
// tools/export-content.mjs — M1-0 one-time export of the FROZEN web build (web-frozen = 753549a) for the native port.
//
// 가설: ✅ 네이티브가 쓸 콘텐츠(카탈로그 → 100판, TUNE, 상점, 잔챙이, 대사, 카드, 하늘, 접근·정체·시그니처 표, 차 치수)는
//       동결된 game/js 모듈을 DOM 없이 Node에서 그대로 돌려 JSON으로 뽑을 수 있다(vehicles.js도 원본 그대로 동작).
//       ✅ 1-1 traffic RNG(mulberry32(1007))와 spawnJam 결과·호출 지점 태그 트레이스는 Node에서 골든으로 뽑히고,
//       브라우저 웹 오라클(Playwright, 가상 시간)과 값이 완전히 같다. 틱 골든은 기록한 입력만으로 재생된다.
//
// Usage (static server serving the repo root on :8090 for the web parts — see native/data/README.md):
//   node tools/export-content.mjs            # write native/data/src/*.json + native/tests/golden/*.json
//   node tools/export-content.mjs --check    # recompute everything, fail if any output differs from disk
//   options: --no-web (skip Playwright parts) --web-url=http://localhost:8090 --ticks=600 --web-query=skip=jam
//            --allow-dirty (game/ differs from web-frozen) --force (overwrite hand-edited native/data/src files)
//
// Never edits game/js. game/js modules are imported unmodified; vehicles.js is reached through
// tools/content/lib/vehicles-spy.mjs, which re-exports it and only records each mesh's build spec (seed/color).
import { register } from 'node:module';
register('./content/lib/spy-hooks.mjs', import.meta.url);

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { dirname, resolve, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { stableStringify, f17, deepEqual } from './content/lib/stable-json.mjs';
import { scanStrings, hasHangul, extractConst, evalLiteral } from './content/lib/js-source.mjs';
import { K, TRAFFIC, SETUP, HAPTICS } from './content/lib/tables.mjs';
import { normalizeStages, denormalizeHandmade, validateStages, STAGE_SCHEMA_VERSION } from './content/lib/stages.mjs';
import { vehicleKindsTable } from './content/lib/vehicle-kinds.mjs';
import { spawnGolden, replayTicks } from './content/lib/goldens.mjs';
import { tagOf, parseChromeStack, siteStr } from './content/lib/rng-trace.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const GAME = resolve(ROOT, 'game/js');
const SRC_DIR = resolve(ROOT, 'native/data/src');
const GOLDEN_DIR = resolve(ROOT, 'native/tests/golden');
const WEB_FROZEN_SHA = '753549a';
const GOLDEN_STAGES = [1, 5, 6];

const argv = process.argv.slice(2);
const flag = (k) => argv.includes(`--${k}`);
const opt = (k, d) => { const a = argv.find((x) => x.startsWith(`--${k}=`)); return a ? a.slice(k.length + 3) : d; };
const log = (...a) => { if (!flag('quiet')) console.error(...a); };

// ───────────────────────────── module loading (after the hook is registered)
async function loadModules() {
  const imp = (p) => import(pathToFileURL(resolve(GAME, p)).href);
  const THREE = await import('three');
  const CFG = await imp('config.js');
  const SG = await imp('stagegen.js');
  const CATALOG = (await imp('data/villain_catalog.js')).default;
  const TR = await imp('traffic.js');
  const { BossManager } = await imp('boss.js');
  const { Player } = await imp('player.js');
  const VEH = await import(pathToFileURL(resolve(ROOT, 'tools/content/lib/vehicles-spy.mjs')).href);
  const STAGES = SG.buildStages(CATALOG, CFG.STAGES);
  return { THREE, CFG, SG, CATALOG, Traffic: TR.Traffic, mulberry32: TR.mulberry32, occupies: TR.occupies, BossManager, Player, VEH, STAGES };
}

// ───────────────────────────── workers (fresh process = fresh CAR_ID counter, like a fresh page load)
if (argv[0] === '--worker') {
  const M = await loadModules();
  const VK = vehicleKindsTable(M.VEH, M.CFG.PLAYER_COLOR);
  if (argv[1] === 'spawn') {
    const id = +argv[2];
    const g = spawnGolden(M, id, VK);
    const out = {
      [`spawn_stage${id}.json`]: stableStringify(goldenHeader({ ...g.spawn, kind: 'spawn' }, `spawnJam layout of stage ${id} (main.js setupStage path), before the first update`)),
      [`rng_trace_stage${id}.json`]: stableStringify(goldenHeader({ ...g.trace, kind: 'rng_trace' }, `every traffic rng() call during stage ${id} spawnJam: call index, call-site tag, value. The C++ port must make the same calls in the same tag order (NATIVE_PORT 3-3: the trace is the contract)`), { inlineScalarArrays: 24 }),
    };
    await writeOut(JSON.stringify(out));
  } else if (argv[1] === 'replay') {
    const golden = JSON.parse(readFileSync(0, 'utf8'));
    await writeOut(JSON.stringify(replayTicks(M, golden)));
  } else throw new Error(`unknown worker ${argv[1]}`);
  process.exit(0);
}
// stdout is a pipe: wait for the write to flush before exiting (process.exit would truncate it)
function writeOut(text) { return new Promise((res, rej) => process.stdout.write(text, (e) => (e ? rej(e) : res()))); }

function goldenHeader(obj, description) {
  return { schema_version: 1, web_frozen_sha: WEB_FROZEN_SHA, generator: 'tools/export-content.mjs', description, ...obj };
}

function runWorker(args, input) {
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--worker', ...args], { input, maxBuffer: 1 << 28, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`worker ${args.join(' ')} failed:\n${r.stderr}`);
  return JSON.parse(r.stdout);
}

// ───────────────────────────── helpers
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const gameSrc = (p) => readFileSync(resolve(GAME, p), 'utf8');

/** K(value, 'file:line') tree → { plain values + `_src` maps }, verifying each value against its cited source line. */
function materialize(node, errors, path = '') {
  if (node instanceof K) throw new Error('materialize: K at root');
  if (Array.isArray(node)) return node.map((x, i) => (x instanceof K ? checkK(x, errors, `${path}[${i}]`) : materialize(x, errors, `${path}[${i}]`)));
  if (node && typeof node === 'object') {
    const out = {}, src = {};
    for (const [key, v] of Object.entries(node)) {
      if (v instanceof K) { out[key] = checkK(v, errors, `${path}.${key}`); src[key] = v.src; }
      else out[key] = materialize(v, errors, `${path}.${key}`);
    }
    if (Object.keys(src).length) out._src = src;
    return out;
  }
  return node;
}
function checkK(kv, errors, path) {
  const [file, lineS] = kv.src.split(':');
  const text = gameSrc(file).split('\n')[+lineS - 1] || '';
  const code = text.replace(/\/\/.*$/, '');
  if (kv.pattern != null) {
    if (!code.includes(kv.pattern)) errors.push(`${path}: ${kv.src} does not contain ${JSON.stringify(kv.pattern)}: ${text.trim()}`);
  } else if (typeof kv.value === 'number') {
    const nums = (code.match(/(?<![\w.$])\d+(?:\.\d+)?(?:e-?\d+)?|(?<![\w.$])\.\d+/gi) || []).map(Number);
    if (!nums.some((n) => n === Math.abs(kv.value))) errors.push(`${path}: ${kv.value} not on ${kv.src}: ${text.trim()}`);
  } else errors.push(`${path}: non-numeric K needs a pattern`);
  return kv.value;
}

// ───────────────────────────── content tables
function exportConfig(M, errors) {
  const C = M.CFG;
  const { approach, ...tune } = C.TUNE;
  return {
    schema_version: 1,
    source: `game/js/config.js + inline constants of traffic.js/main.js @ web-frozen ${WEB_FROZEN_SHA}`,
    road: {
      laneW: C.LANE_W, numLanes: C.NUM_LANES, shoulderLane: C.SHOULDER_LANE, shoulderW: C.SHOULDER_W,
      medianGap: C.MEDIAN_GAP, medianW: C.MEDIAN_W, medianX: C.MEDIAN_X, roadLeft: C.ROAD_LEFT, roadRight: C.ROAD_RIGHT,
      oppLaneX: [0, 1, 2, 3].map(C.OPP_LANE_X), oppRoadLeft: C.OPP_ROAD_LEFT, segLen: C.SEG_LEN,
      laneX: [0, 1, 2, 3, 4].map(C.laneX),
      _doc: 'laneX(i) = (i - (numLanes-1)/2) * laneW; s = distance along the road, world z = -s (NATIVE_PORT 3-4)',
    },
    units: { kmh: C.KMH },
    fonts: { display: C.FONT_DISPLAY, ui: C.FONT_UI },
    npc: {
      kinds: C.NPC_KINDS.map(([k, w]) => [k, w]),
      colorsMono: [...C.NPC_COLORS_MONO], colorsPop: [...C.NPC_COLORS_POP], playerColor: C.PLAYER_COLOR,
      _doc: 'ORDER MATTERS: pickWeighted walks kinds in this order; colors are indexed by floor(rng*len)',
    },
    tune: { ...tune, _doc: 'TUNE from config.js; TUNE.approach lives in approach.json (default)' },
    traffic: materialize(TRAFFIC, errors, 'traffic'),
    setup: materialize(SETUP, errors, 'setup'),
    rng: {
      algorithm: 'mulberry32',
      source: M.mulberry32.toString(),
      traffic: 'mulberry32(stage.id * 1000 + 7)  (main.js:360)',
      world: 'mulberry32(stage.id * 7919 + 13)  (world.js:132)',
      vehicleVariant: 'seed = floor(rng * 1e6); variant = canon[seed % variants]  (traffic.js:88, vehicles.js buildVehicle)',
      stagegen: 'build-time only: rngFor(id) LCG a = (id*2654435761)>>>0; a = (a*1664525 + 1013904223)>>>0; a/2^32 (tools/content/stagegen.js)',
      mathRandom: 'web Math.random (boss attack pick, taunts, fx) → native RandomNumberGenerator(--seed) (NATIVE_PORT 3-3)',
    },
  };
}

function exportLines(M) {
  const C = M.CFG;
  const tables = {};
  for (const k of ['THANKS_LINES', 'BUMP_LINES', 'CUTIN_LINES', 'YIELD_LINES', 'NOWAY_LINES', 'LETIN_LINES', 'FRONT_RAGE_LINES', 'CHEATER_LINES']) tables[k] = [...C[k]];
  const inline = [];
  for (const file of ['main.js', 'boss.js', 'behaviors/index.js', 'rewards.js']) {
    const src = gameSrc(file);
    const { literals } = scanStrings(src);
    const templates = literals.filter((l) => l.kind === 'template');
    const nested = (l) => templates.some((t) => t !== l && t.start < l.start && l.end <= t.end);
    const hits = literals.filter((l) => hasHangul(l.text) && !nested(l));
    const groups = [];
    const byArray = new Map();
    for (const l of hits) {
      if (l.arrayStart != null) {
        let g = byArray.get(l.arrayStart);
        if (!g) { g = { line: l.line, call: l.callee, prop: l.prop, template: false, texts: [], start: l.start }; byArray.set(l.arrayStart, g); groups.push(g); }
        g.texts.push(l.text); g.template ||= l.kind === 'template';
      } else groups.push({ line: l.line, call: l.callee, prop: l.prop, template: l.kind === 'template', texts: [l.text], start: l.start });
    }
    const perLine = new Map();
    for (const g of groups) perLine.set(g.line, (perLine.get(g.line) || 0) + 1);
    const seen = new Map();
    for (const g of groups) {
      const n = (seen.get(g.line) || 0) + 1; seen.set(g.line, n);
      inline.push({ id: `${file}:${g.line}${perLine.get(g.line) > 1 ? `#${n}` : ''}`, file: `game/js/${file}`, line: g.line, call: g.call, prop: g.prop, template: g.template, texts: g.texts });
    }
  }
  return {
    schema_version: 1,
    source: `game/js/config.js *_LINES + Hangul string literals of main.js/boss.js/behaviors/index.js/rewards.js @ ${WEB_FROZEN_SHA}`,
    _doc: 'tables: named line pools (config.js). inline: every Korean literal of the sim/game files, grouped by array literal; id = file:line[#n] (provisional keys — rename when the call site is ported). template=true texts keep ${expr} placeholders verbatim. Stage taunts live in stages.json, mini lines in mini_types.json, UI chrome in ui.js (bake-ui).',
    tables, inline,
  };
}

function exportCards() {
  const src = gameSrc('ui.js');
  const ev = (name) => evalLiteral(extractConst(src, name));
  return {
    schema_version: 1,
    source: `game/js/ui.js (module-private tables, evaluated from source) @ ${WEB_FROZEN_SHA}`,
    _doc: 'stage.card (고지서|형사|표창|계도) → caseOf → case kind → disposition card texts. Stage kind badge from title prefix [최종보스]/[보스]/[엘리트]/[보너스] (kindOf) or flags.',
    caseOf: ev('CASE_OF'), cases: ev('CASE'), caseChip: ev('CASE_CHIP'), kindOf: ev('KIND_OF'), kindLabel: ev('KIND_LABEL'),
    kindTitleRegex: String(/^\s*\[(최종보스|보스|엘리트|보너스)\]\s*/),
  };
}

function exportApproach(M) {
  const src = gameSrc('ui.js');
  const sandbox = { RI: { tile: () => '', cone: () => '', carTop: () => '', horn: '', badge: () => '' }, so: () => '', hornBase: () => '', INK: '' };
  const labels = (name) => Object.fromEntries(Object.entries(evalLiteral(extractConst(src, name), sandbox)).map(([k, v]) => [k, { label: v.label, short: v.short, tone: v.tone }]));
  return {
    schema_version: 1,
    source: `TUNE.approach (config.js) + APPROACH_BY_ID (stagegen.js) + SH_MODES/HONK_MODES labels (ui.js) @ ${WEB_FROZEN_SHA}`,
    _doc: 'runtime: A = {...default, ...stage.approach}. byId is a stagegen input (already resolved into stages.json; edit here + build.mjs --regen-stages).',
    default: { ...M.CFG.TUNE.approach },
    byId: M.SG.APPROACH_BY_ID,
    labels: { shoulder: labels('SH_MODES'), honk: labels('HONK_MODES') },
  };
}

function exportMeta(files) {
  return {
    schema_version: 1,
    web_frozen_sha: WEB_FROZEN_SHA,
    web_frozen_tag: 'web-frozen (local tag; reference the SHA)',
    exporter: 'tools/export-content.mjs',
    inputs: Object.fromEntries(files.map((f) => [`game/js/${f}`, sha256(readFileSync(resolve(GAME, f)))])),
  };
}

// ───────────────────────────── main
async function main() {
  const check = flag('check');
  // 0) the web must be exactly web-frozen
  try { execFileSync('git', ['-C', ROOT, 'cat-file', '-e', `${WEB_FROZEN_SHA}^{commit}`]); } catch { throw new Error(`commit ${WEB_FROZEN_SHA} (web-frozen) not found`); }
  const dirty = spawnSync('git', ['-C', ROOT, 'diff', '--quiet', WEB_FROZEN_SHA, '--', 'game/']).status !== 0;
  const untracked = execFileSync('git', ['-C', ROOT, 'ls-files', '--others', '--exclude-standard', 'game/'], { encoding: 'utf8' }).trim();
  if ((dirty || untracked) && !flag('allow-dirty')) throw new Error(`game/ differs from web-frozen ${WEB_FROZEN_SHA} (use --allow-dirty to export anyway)`);

  const M = await loadModules();
  const errors = [];
  const outSrc = {}, outGolden = {};

  // 1) content → native/data/src
  const VK = vehicleKindsTable(M.VEH, M.CFG.PLAYER_COLOR);
  outSrc['config.json'] = exportConfig(M, errors);
  outSrc['shop.json'] = { schema_version: 1, source: `config.js SHOP/SHOP_DEFAULT @ ${WEB_FROZEN_SHA}`, items: M.CFG.SHOP.map((x) => ({ ...x })), defaults: { ...M.CFG.SHOP_DEFAULT } };
  outSrc['mini_types.json'] = {
    schema_version: 1, source: `config.js MINI_TYPES @ ${WEB_FROZEN_SHA}`,
    _doc: 'ARRAY ORDER IS RNG ORDER: spawnJam picks types[floor(rng*len)] over Object.keys(MINI_TYPES) (traffic.js:210/217)',
    types: Object.entries(M.CFG.MINI_TYPES).map(([id, t]) => ({ id, ...t })),
  };
  outSrc['lines.json'] = exportLines(M);
  outSrc['cards.json'] = exportCards();
  outSrc['sky.json'] = {
    schema_version: 1, source: `config.js SKY + stagegen STAGE_SKY @ ${WEB_FROZEN_SHA}`,
    _doc: 'presets: colors are 0xRRGGBB ints (sRGB). stageSky: per-stage override applied by stagegen (stage id → preset). Godot light conversion values are added in M1a (NATIVE_PORT 2).',
    presets: M.CFG.SKY, stageSky: { 5: 'rain', 6: 'night' },
  };
  outSrc['approach.json'] = exportApproach(M);
  outSrc['jamshape.json'] = { schema_version: 1, source: `stagegen.js JAMSHAPE_BY_ID @ ${WEB_FROZEN_SHA}`, _doc: 'stagegen input (resolved into stages.json). lanes[0..3]: packed|train|flow|spaced|pass', byId: M.SG.JAMSHAPE_BY_ID };
  outSrc['sig.json'] = { schema_version: 1, source: `stagegen.js SIG_BY_ID @ ${WEB_FROZEN_SHA}`, _doc: 'stagegen input (resolved into stages.json): stage id → signature behaviour module', byId: M.SG.SIG_BY_ID };
  outSrc['villain_catalog.json'] = M.CATALOG;
  const handmade = normalizeStages(M.CFG.STAGES.map((s) => ({ ...s })));
  outSrc['handmade_stages.json'] = { schema_version: STAGE_SCHEMA_VERSION, source: `config.js STAGES (5 handmade, merged by stagegen via catalog handmade_id) @ ${WEB_FROZEN_SHA}`, _doc: 'stagegen input; same normalized form as stages.json', stages: handmade };
  const stages = normalizeStages(M.STAGES);
  outSrc['stages.json'] = {
    schema_version: STAGE_SCHEMA_VERSION,
    source: `game/js/stagegen.js buildStages(villain_catalog, handmade) @ ${WEB_FROZEN_SHA}`,
    _doc: 'SOURCE OF TRUTH for the 100 stages (edit here, or edit catalog/tables and run tools/content/build.mjs --regen-stages). frontRow = array[4] lane→kind|null; attacks = [[kind, weight]] in pick order; null = absent in JS; road = RoadGraph segments (N6).',
    stages,
  };
  outSrc['haptics.json'] = HAPTICS;
  outSrc['vehicle_kinds.json'] = VK;

  // verify haptics web refs ('file.js:line needle')
  for (const [ev, e] of Object.entries(HAPTICS.events)) for (const ref of e.web) {
    const m = /^([\w/]+\.js):(\d+) (.+)$/.exec(ref);
    if (!m) continue;
    if (!(gameSrc(m[1]).split('\n')[+m[2] - 1] || '').includes(m[3])) errors.push(`haptics.${ev}: ${ref} not found`);
  }
  const sv = validateStages(stages, { vehicleKinds: new Set(Object.keys(VK.kinds)), skyPresets: new Set(Object.keys(M.CFG.SKY)) });
  errors.push(...sv);

  // 2) the tools/content/stagegen.js copy, fed only from the JSON we are about to write, must reproduce the web's 100 stages
  const texts = Object.fromEntries(Object.entries(outSrc).map(([k, v]) => [k, stableStringify(v)]));
  const fromJson = (k) => JSON.parse(texts[k]);
  const CSG = await import(pathToFileURL(resolve(ROOT, 'tools/content/stagegen.js')).href);
  CSG.configureTables({ approach: fromJson('approach.json').byId, jamShape: fromJson('jamshape.json').byId, sig: fromJson('sig.json').byId, stageSky: fromJson('sky.json').stageSky });
  const regen = normalizeStages(CSG.buildStages(fromJson('villain_catalog.json'), fromJson('handmade_stages.json').stages.map(denormalizeHandmade)));
  const d = deepEqual(regen, stages);
  if (d.length || stableStringify(regen) !== stableStringify(stages)) errors.push(`tools/content/stagegen.js copy (fed from JSON) != web stagegen:\n  ${d.join('\n  ')}`);
  else log('ok: tools/content/stagegen.js + data/src JSON reproduce the web 100 stages exactly');
  outSrc['export_meta.json'] = exportMeta(['config.js', 'stagegen.js', 'traffic.js', 'shoulder.js', 'vehicles.js', 'boss.js', 'player.js', 'main.js', 'world.js', 'ui.js', 'rewards.js', 'behaviors/index.js', 'data/villain_catalog.js', 'data/villain_catalog.json']);
  texts['export_meta.json'] = stableStringify(outSrc['export_meta.json']);
  if (errors.length) throw new Error(`export errors:\n  ${errors.join('\n  ')}`);

  // 3) goldens: raw RNG stream, then spawn + tagged trace per stage (fresh process each)
  const seed = 1 * 1000 + 7;
  const r = M.mulberry32(seed), u32 = [], f64 = [];
  for (let i = 0; i < 1000; i++) { const v = r(); u32.push(Math.round(v * 4294967296)); f64.push(f17(v)); }
  outGolden['rng_stage1.json'] = stableStringify(goldenHeader({
    kind: 'rng', stage: 1, seed, seed_formula: 'stage.id * 1000 + 7 (main.js:360)', algorithm: 'mulberry32', source: M.mulberry32.toString(),
    count: 1000, u32, f64, note: 'f64[i] = u32[i] / 2^32 exactly (17 significant digits). Draw 0 is the first rng() call of spawnJam.',
  }, 'first 1000 outputs of the stage-1 traffic RNG'), { inlineScalarArrays: 0 });
  for (const id of GOLDEN_STAGES) Object.assign(outGolden, runWorker(['spawn', String(id)]));
  const s1 = JSON.parse(outGolden['spawn_stage1.json']);
  const ref = { cars: 126, firstCar: [1, 'bus', 200.4453], breakdown: [109.681, 7], cone: 147.518, minis: [131.90, 66.63], next: 0.3714370721 };
  const near = (a, b, dp) => Math.abs(a - b) < 0.5 * 10 ** -dp;
  const refOk = s1.cars.length === ref.cars && s1.cars[0].lane === ref.firstCar[0] && s1.cars[0].kind === ref.firstCar[1] && near(s1.cars[0].s, ref.firstCar[2], 4)
    && near(s1.obstacles.find((o) => o.kind === 'breakdown').s, ref.breakdown[0], 3) && s1.obstacles.find((o) => o.kind === 'breakdown').len === ref.breakdown[1]
    && near(s1.obstacles.find((o) => o.kind === 'cones').s, ref.cone, 3)
    && JSON.stringify(s1.cars.filter((c) => c.mini).map((c) => +c.s.toFixed(2))) === JSON.stringify(ref.minis) && near(s1.rng.next.f, ref.next, 10);
  if (!refOk) throw new Error('spawn_stage1 does not match the NATIVE_PORT 3-3 reference values');
  log(`ok: spawn_stage1 matches NATIVE_PORT 3-3 reference (126 cars, bus 200.4453, breakdown 109.681/len 7, cone 147.518, minis 131.90/66.63, next 0.3714370721); rng draws ${s1.rng.draws}`);

  // 4) web oracle: live page spawn must equal the Node spawn; then record the per-tick golden and prove it replays
  if (!flag('no-web')) {
    const { webSpawn, webTicks, MATH_RANDOM_SEED } = await import('./content/lib/web-oracle.mjs');
    const base = opt('web-url', 'http://localhost:8090');
    const ws = await webSpawn(base, 1, { log });
    const dd = [];
    for (const key of Object.keys(ws.view)) {
      const nodeSide = key === 'traffic' || key === 'player' ? pick(s1[key], Object.keys(ws.view[key])) : s1[key].map((x, i) => pick(x, Object.keys(ws.view[key][i] || {})));
      deepEqual(ws.view[key], nodeSide, `web.${key}`, dd);
    }
    if (Math.round(ws.next * 4294967296) !== s1.rng.next.u32) dd.push(`web next rng ${ws.next} != node ${s1.rng.next.f}`);
    if (ws.errors.length) log('web page errors:', ws.errors.join(' | '));
    if (dd.length) throw new Error(`web spawn != node spawn:\n  ${dd.join('\n  ')}`);
    log(`ok: live web spawn (${ws.url}, before frame 1) == Node spawn_stage1 on all ${Object.keys(ws.view).length} groups, next draw identical`);

    const nTicks = +opt('ticks', 600);
    const query = opt('web-query', 'skip=jam');
    const wt = await webTicks(base, 1, nTicks, { query, log });
    if (wt.outside.length) throw new Error(`traffic rng was drawn outside Traffic.update ${wt.outside.length}x (replay would need those calls)`);
    const ticks = wt.ticks.map((t) => ({
      i: t.i, in: t.in,
      out: { s: t.out.s, v: t.out.v, lane: t.out.lane, x: t.out.x, opp_s: t.out.opp_s, obstacles: t.out.obstacles,
        rng: t.out.rngRaw.map(([stack, u]) => { const fr = parseChromeStack(stack); return [tagOf(fr[0], fr[1] || null), u]; }) },
    }));
    const dts = [...new Set(ticks.map((t) => t.in.dt))];
    const golden = goldenHeader({
      kind: 'traffic_ticks', stage: 1, url: wt.url.replace(base, ''), ticks_recorded: ticks.length,
      dt_model: 'WEB USES VARIABLE dt: main.js frame(now) → step(min(0.05, (now-last)/1000)) per requestAnimationFrame (or fixed 1/30 x N with ?ff=N). This recording drove rAF from virtual time at 120 Hz (frame step 1000/120 ms), so dt ≈ 1/120 but NOT bit-constant: use in.dt of each tick (exact).',
      dt_distinct: dts, phases: [...new Set(ticks.map((t) => t.in.phase))],
      math_random_seed: MATH_RANDOM_SEED, spawn_rng_draws: s1.rng.draws, car_ids: wt.carIds,
      replay: 'For each tick: set player/villains/extras fields from in.*, call Traffic.update(in.dt, {time: in.time, phase, allowEvents, focusS, player, villains, extras}); then cars (in car_ids order) must have exactly out.s / out.v / out.lane, x = out.x[id] ?? laneX(lane), opp[k].s = out.opp_s[k], obstacle count = out.obstacles, and the update must have drawn exactly out.rng ([tag, u32] in order). Player/villain objects must keep identity across ticks. The Node replay of this file passes (tools/export-content.mjs).',
      fields: { 'in.player': 's x w len lane v mode', 'in.villains': 's baseS x w len v vNominal alive', 'in.extras': 'boss.sigBodies (empty for 1-1)', 'in.sinLf': 'Math.sin(in.time*0.42 + lane*1.9) for lane 0..4 as computed by the web (traffic.js:406)' },
      math: 'Only one transcendental feeds the sim state: the packed-lane factor sin(t*0.42 + lane*1.9) (traffic.js:406). libm sin is NOT bit-identical across JS engines/libms: in a sample of 13175 distinct sin args from this run (ticks 500-586), Chromium 141 Math.sin and Node 22 Math.sin differed in the last ulp on 96, while glibc 2.39 sin() matched Chromium on 13174 (so C++ std::sin is close but not guaranteed; iOS/Android libms are untested). A bit-exact replay must use in.sinLf for those calls (the Node replay does). Math.pow(x, 2) in the IDM equals x*x; sqrt is exact; atan2 only feeds the visual yaw.',
      ticks,
    }, `per-tick Traffic.update inputs/outputs of the live web game, stage 1 (${query || 'normal start'}), first ${ticks.length} ticks`);
    const text = stableStringify(golden, { inlineScalarArrays: Infinity });
    const rp = runWorker(['replay'], text);
    if (!rp.ok) throw new Error(`tick golden does not replay in Node: ${rp.firstDiff}`);
    log(`ok: ${ticks.length} web ticks recorded (phases ${golden.phases.join(',')}; dt values ${dts.length} distinct) and replayed bit-exactly in Node`);
    outGolden['traffic_ticks_stage1.json'] = text;
  } else log('skip: --no-web (web spawn cross-check and tick golden not produced)');

  // 5) write or check
  const results = [];
  const emit = (dir, name, text) => {
    const p = resolve(dir, name);
    const cur = existsSync(p) ? readFileSync(p, 'utf8') : null;
    const same = cur === text;
    if (check) { results.push(`${same ? 'same' : 'DIFF'} ${relative(ROOT, p)}`); return same; }
    if (!same) { mkdirSync(dir, { recursive: true }); writeFileSync(p, text); }
    results.push(`${same ? 'unchanged' : 'wrote'} ${relative(ROOT, p)} (${(text.length / 1024).toFixed(1)} KB)`);
    return true;
  };
  // native/data/src is the source of truth after M1-0: never clobber hand edits silently
  if (!check && !flag('force')) {
    const edited = Object.entries(texts).filter(([k, t]) => { const p = resolve(SRC_DIR, k); return existsSync(p) && readFileSync(p, 'utf8') !== t; }).map(([k]) => k);
    if (edited.length) throw new Error(`native/data/src files differ from the web export (hand-edited since M1-0?): ${edited.join(', ')}\n  refusing to overwrite; use --force to reset them to the web-frozen values, or --check to just compare`);
  }
  let ok = true;
  for (const [k, t] of Object.entries(texts)) ok = emit(SRC_DIR, k, t) && ok;
  for (const [k, t] of Object.entries(outGolden)) ok = emit(GOLDEN_DIR, k, t) && ok;
  console.log(results.join('\n'));
  if (!ok) { console.error('export --check: outputs differ from disk'); process.exit(1); }
}

function pick(o, keys) { const r = {}; for (const k of keys) r[k] = o?.[k]; return r; }

main().catch((e) => { console.error(e.stack || String(e)); process.exit(1); });
