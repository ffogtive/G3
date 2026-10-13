#!/usr/bin/env node
// tools/content/build.mjs — native/data/src/*.json (사람이 고치는 원천) → native/data/*.json (생성물, 손 편집 금지, 커밋함).
//
// 가설: ✅ 런타임 데이터는 원천 JSON을 검증·정규화(키 정렬, `_` 메타 키 제거)만 해서 만들면 결정적이고(두 번 돌려 바이트 동일),
//       판 데이터의 진실은 src/stages.json 하나다. 카탈로그·판별 표를 고친 뒤 판을 다시 뽑을 때만 stagegen을 돈다(--regen-stages).
//
//   node tools/content/build.mjs                 # validate + write native/data/*.json and native/data/manifest.json
//   node tools/content/build.mjs --check         # exit 1 if native/data/*.json is not what the sources produce
//   node tools/content/build.mjs --regen-stages  # re-derive src/stages.json from villain_catalog + handmade_stages +
//                                                #   approach/jamshape/sig/sky tables with tools/content/stagegen.js
//   --strict  : also fail when src/stages.json drifts from what stagegen would produce (default: report only)
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { stableStringify, deepEqual } from './lib/stable-json.mjs';
import { normalizeStages, denormalizeHandmade, validateStages, SHOULDER_MODES, STAGE_SCHEMA_VERSION } from './lib/stages.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const SRC = resolve(ROOT, 'native/data/src');
const OUT = resolve(ROOT, 'native/data');
const argv = process.argv.slice(2);
const flag = (k) => argv.includes(`--${k}`);

const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const srcText = {};
function readSrc(name) {
  const p = resolve(SRC, name);
  if (!existsSync(p)) throw new Error(`missing source ${relative(ROOT, p)} (run tools/export-content.mjs once)`);
  srcText[name] = readFileSync(p, 'utf8');
  try { return JSON.parse(srcText[name]); } catch (e) { throw new Error(`${name}: invalid JSON: ${e.message}`); }
}

/** Remove documentation/meta keys (`_doc`, `_src`, ...) recursively; runtime files carry data only. */
function stripMeta(v) {
  if (Array.isArray(v)) return v.map(stripMeta);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v)) if (!k.startsWith('_')) o[k] = stripMeta(v[k]);
    return o;
  }
  return v;
}
function walkNumbers(v, path, errs) {
  if (typeof v === 'number' && !Number.isFinite(v)) errs.push(`${path}: non-finite number`);
  else if (Array.isArray(v)) v.forEach((x, i) => walkNumbers(x, `${path}[${i}]`, errs));
  else if (v && typeof v === 'object') for (const k of Object.keys(v)) walkNumbers(v[k], `${path}.${k}`, errs);
}

async function stagegenStages(src) {
  const SG = await import(pathToFileURL(resolve(ROOT, 'tools/content/stagegen.js')).href);
  SG.configureTables({ approach: src.approach.byId, jamShape: src.jamshape.byId, sig: src.sig.byId, stageSky: src.sky.stageSky });
  return normalizeStages(SG.buildStages(src.villain_catalog, src.handmade_stages.stages.map(denormalizeHandmade)));
}

async function main() {
  const names = ['config', 'shop', 'mini_types', 'lines', 'cards', 'sky', 'approach', 'jamshape', 'sig', 'villain_catalog', 'handmade_stages', 'stages', 'haptics', 'vehicle_kinds'];
  const src = Object.fromEntries(names.map((n) => [n, readSrc(`${n}.json`)]));
  const errs = [];

  if (flag('regen-stages')) {
    const stages = await stagegenStages(src);
    const doc = { ...src.stages, schema_version: STAGE_SCHEMA_VERSION, stages };
    const text = stableStringify(doc);
    if (text !== srcText['stages.json']) { writeFileSync(resolve(SRC, 'stages.json'), text); console.log('regen: wrote native/data/src/stages.json from stagegen'); }
    else console.log('regen: native/data/src/stages.json already matches stagegen');
    src.stages = JSON.parse(text);
  }

  // ── validation
  for (const n of names) walkNumbers(src[n], n, errs);
  const kinds = new Set(Object.keys(src.vehicle_kinds.kinds || {}));
  const skyPresets = new Set(Object.keys(src.sky.presets || {}));
  for (const [k, v] of Object.entries(src.vehicle_kinds.kinds)) {
    const nVar = new Set(v.canon).size;
    for (const m of ['simple', 'detailed']) if (!Array.isArray(v.dims?.[m]) || v.dims[m].length !== nVar || v.dims[m].some((d) => !(d.L > 0 && d.W > 0))) errs.push(`vehicle_kinds.${k}.dims.${m} invalid`);
    if (v.canon.length !== v.variants) errs.push(`vehicle_kinds.${k}: canon length != variants`);
  }
  for (const [k] of src.config.npc.kinds) if (!kinds.has(k)) errs.push(`config.npc.kinds: ${k} not in vehicle_kinds`);
  for (const lk of ['train', 'flow', 'spaced', 'pass', 'packed']) for (const p of ['T', 's0', 'aMax']) if (typeof src.config.traffic?.idm?.lanes?.[lk]?.[p] !== 'number') errs.push(`config.traffic.idm.lanes.${lk}.${p} missing`);
  const shopIds = new Set();
  for (const it of src.shop.items) { if (shopIds.has(it.id)) errs.push(`shop: duplicate id ${it.id}`); shopIds.add(it.id); }
  for (const [cat, id] of Object.entries(src.shop.defaults)) { const it = src.shop.items.find((x) => x.id === id); if (!it || it.cat !== cat) errs.push(`shop.defaults.${cat}: ${id} is not a ${cat} item`); }
  const miniIds = src.mini_types.types.map((t) => t.id);
  if (new Set(miniIds).size !== miniIds.length || !miniIds.length) errs.push('mini_types: ids must be unique and non-empty');
  for (const t of src.mini_types.types) if (!t.name || !Array.isArray(t.lines) || !Array.isArray(t.sorry)) errs.push(`mini_types.${t.id}: needs name/lines/sorry`);
  for (const [k, arr] of Object.entries(src.lines.tables)) if (!Array.isArray(arr) || !arr.length || arr.some((x) => typeof x !== 'string')) errs.push(`lines.tables.${k} must be a non-empty string array`);
  const lineIds = src.lines.inline.map((e) => e.id);
  if (new Set(lineIds).size !== lineIds.length) errs.push('lines.inline: duplicate ids');
  for (const ck of Object.values(src.cards.caseOf)) if (!src.cards.cases[ck]) errs.push(`cards: case ${ck} missing`);
  for (const [id, p] of Object.entries(src.sky.stageSky)) if (!skyPresets.has(p)) errs.push(`sky.stageSky.${id}: unknown preset ${p}`);
  for (const m of SHOULDER_MODES) if (!src.approach.labels.shoulder[m]) errs.push(`approach.labels.shoulder.${m} missing`);
  if (!SHOULDER_MODES.includes(src.approach.default.shoulder)) errs.push('approach.default.shoulder invalid');
  for (const [ev, e] of Object.entries(src.haptics.events)) if (!Array.isArray(e.ios) || !e.ios.length || !Array.isArray(e.android) || !e.android.length) errs.push(`haptics.events.${ev}: needs ios and android patterns`);
  const stages = src.stages.stages;
  errs.push(...validateStages(stages, { vehicleKinds: kinds, skyPresets }));
  const sigModules = new Set(Object.values(src.sig.byId));
  for (const s of stages) {
    if (s.sig !== null && !sigModules.has(s.sig)) errs.push(`stage ${s.id}: sig ${s.sig} not in sig.json`);
    if (s.approach?.honk && !src.approach.labels.honk[s.approach.honk]) errs.push(`stage ${s.id}: approach.honk ${s.approach.honk} has no label`);
    for (const fk of s.frontRow) if (fk && !kinds.has(fk)) errs.push(`stage ${s.id}: frontRow kind ${fk} unknown`);
  }
  const chapters = src.villain_catalog.chapters || [];
  for (const s of stages) if (!chapters.some((c) => c.no === s.chapter)) { errs.push(`stage ${s.id}: chapter ${s.chapter} not in catalog chapters`); break; }
  if (errs.length) { console.error(`build: ${errs.length} validation error(s):\n  ${errs.join('\n  ')}`); process.exit(1); }

  // ── drift: does src/stages.json still equal what stagegen derives from the catalog + tables?
  const derived = await stagegenStages(src);
  const drift = derived.filter((d, i) => deepEqual(d, stages[i] ?? null).length).map((d) => d.id);
  if (derived.length !== stages.length) drift.push('count');
  const driftMsg = drift.length ? `stagegen drift: ${drift.length} stage(s) differ from src/stages.json (ids ${drift.slice(0, 12).join(',')}${drift.length > 12 ? '…' : ''}) — intended hand edits, or run --regen-stages` : 'stagegen drift: 0 (src/stages.json == stagegen(catalog, tables))';
  console.log(driftMsg);
  if (drift.length && flag('strict')) process.exit(1);

  // ── outputs (runtime data only: `_` meta keys stripped; build inputs not copied)
  const gen = (from, body) => ({ generated: `tools/content/build.mjs from native/data/src/${from} — do not edit`, ...stripMeta(body) });
  const outputs = {
    'config.json': gen('config.json', src.config),
    'stages.json': gen('stages.json', { schema_version: src.stages.schema_version, stages }),
    'chapters.json': gen('villain_catalog.json', { schema_version: 1, chapters }),
    'shop.json': gen('shop.json', src.shop),
    'mini_types.json': gen('mini_types.json', src.mini_types),
    'lines.json': gen('lines.json', src.lines),
    'cards.json': gen('cards.json', src.cards),
    'sky.json': gen('sky.json', src.sky),
    'approach.json': gen('approach.json', { schema_version: src.approach.schema_version, default: src.approach.default, labels: src.approach.labels }),
    'haptics.json': gen('haptics.json', src.haptics),
    'vehicle_kinds.json': gen('vehicle_kinds.json', src.vehicle_kinds),
  };
  const texts = Object.fromEntries(Object.entries(outputs).map(([k, v]) => [k, stableStringify(v)]));
  texts['manifest.json'] = stableStringify({
    generated: 'tools/content/build.mjs — do not edit',
    schema_version: 1,
    outputs: Object.fromEntries(Object.entries(texts).map(([k, t]) => [k, sha256(t)])),
    sources: Object.fromEntries(Object.entries(srcText).map(([k, t]) => [`src/${k}`, sha256(t)])),
  });

  const check = flag('check');
  let stale = 0;
  for (const [k, t] of Object.entries(texts)) {
    const p = resolve(OUT, k);
    const cur = existsSync(p) ? readFileSync(p, 'utf8') : null;
    if (cur === t) { console.log(`${check ? 'ok   ' : 'same '} native/data/${k}`); continue; }
    if (check) { stale++; console.log(`STALE native/data/${k}`); continue; }
    mkdirSync(OUT, { recursive: true });
    writeFileSync(p, t);
    console.log(`wrote native/data/${k} (${(t.length / 1024).toFixed(1)} KB)`);
  }
  if (stale) { console.error(`build --check: ${stale} generated file(s) are stale — run node tools/content/build.mjs`); process.exit(1); }
}

main().catch((e) => { console.error(e.stack || String(e)); process.exit(1); });
