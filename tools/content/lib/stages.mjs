// Stage normalization shared by tools/export-content.mjs and tools/content/build.mjs.
//
// JS stage objects (game/js/stagegen.js output) → JSON form for the native DB (NATIVE_PORT 3-6):
//   - frontRow {lane: kind}         → array[4] of kind|null (index = lane; JSON object keys would be strings)
//   - attacks {kind: weight}        → array of [kind, weight] in JS insertion order (boss.js picks by iterating
//                                     the table with a random number, so ORDER IS BEHAVIOUR; sorted-key JSON
//                                     would silently change it). Same for phases[].attacks.
//   - undefined fields              → null (zigCenter etc.). The JS reads these with ?? / truthiness, which
//                                     treat null and undefined alike. Every stage gets the same key set.
//   - road                          → [{type:'straight'}] (N6 RoadGraph default; identical behaviour on straights)
// normalizeStage is idempotent (normalizing an already-normalized stage changes nothing).

export const STAGE_SCHEMA_VERSION = 1;
export const LANE_KINDS = ['packed', 'train', 'flow', 'spaced', 'pass'];
export const SHOULDER_MODES = ['open', 'crowded', 'blocked', 'closed', 'dark', 'watched', 'merge', 'debris', 'occupied', 'none'];
export const ROAD_SEGMENT_TYPES = ['straight', 'curve', 'merge_ramp', 'lane_drop', 'tunnel', 'toll_plaza', 'jc_split', 'bridge'];

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function cloneUndefToNull(v) {
  if (Array.isArray(v)) return v.map(cloneUndefToNull);
  if (isPlainObject(v)) {
    const o = {};
    for (const k of Object.keys(v)) o[k] = v[k] === undefined ? null : cloneUndefToNull(v[k]);
    return o;
  }
  return v === undefined ? null : v;
}

export function attacksToPairs(a) {
  if (a == null) return a ?? null;
  if (Array.isArray(a)) return a.map(([k, w]) => [k, w]);
  return Object.keys(a).map((k) => [k, a[k]]);
}
export function pairsToAttacks(p) {
  if (p == null) return p ?? undefined;
  if (!Array.isArray(p)) return { ...p };
  const o = {};
  for (const [k, w] of p) o[k] = w;
  return o;
}
export function frontRowToArray(fr) {
  if (fr == null) return null;
  if (Array.isArray(fr)) return fr.length === 4 ? fr.map((x) => x ?? null) : [0, 1, 2, 3].map((l) => fr[l] ?? null);
  for (const k of Object.keys(fr)) if (!['0', '1', '2', '3'].includes(k)) throw new Error(`frontRow: bad lane key ${k}`);
  return [0, 1, 2, 3].map((l) => fr[l] ?? null);
}
export function frontRowToObject(arr) {
  if (arr == null) return undefined;
  if (!Array.isArray(arr)) return { ...arr };
  const o = {};
  arr.forEach((k, l) => { if (k != null) o[l] = k; });
  return o;
}

export function normalizeStage(s) {
  const o = cloneUndefToNull(s);
  o.frontRow = frontRowToArray(s.frontRow);
  o.attacks = attacksToPairs(s.attacks);
  if (Array.isArray(o.phases)) o.phases = o.phases.map((ph, i) => ({ ...ph, attacks: attacksToPairs(s.phases[i].attacks) }));
  if (!Array.isArray(o.road) || !o.road.length) o.road = [{ type: 'straight' }];
  if (Array.isArray(o.villains)) o.villains = o.villains.map((v) => cloneUndefToNull(v));
  return o;
}

/** Fill every stage (and every villain) with the union key set, missing → null. Deterministic. */
export function uniformKeys(stages) {
  const sk = new Set(), vk = new Set();
  for (const s of stages) { for (const k of Object.keys(s)) sk.add(k); for (const v of s.villains || []) for (const k of Object.keys(v)) vk.add(k); }
  return stages.map((s) => {
    const o = { ...s };
    for (const k of sk) if (!(k in o)) o[k] = null;
    o.villains = (s.villains || []).map((v) => { const w = { ...v }; for (const k of vk) if (!(k in w)) w[k] = null; return w; });
    return o;
  });
}

export function normalizeStages(stages) {
  return uniformKeys(stages.map(normalizeStage)).sort((a, b) => a.id - b.id);
}

/** JSON form → the JS shape stagegen.buildStages expects for handmade stages (inverse of normalizeStage). */
export function denormalizeHandmade(s) {
  const o = {};
  for (const k of Object.keys(s)) if (s[k] !== null) o[k] = s[k];
  if (s.frontRow != null) o.frontRow = frontRowToObject(s.frontRow);
  if (s.attacks != null) o.attacks = pairsToAttacks(s.attacks);
  if (Array.isArray(s.phases)) o.phases = s.phases.map((ph) => ({ ...ph, attacks: pairsToAttacks(ph.attacks) }));
  if (Array.isArray(s.villains)) o.villains = s.villains.map((v) => { const w = {}; for (const k of Object.keys(v)) if (v[k] !== null) w[k] = v[k]; return w; });
  delete o.road;
  return o;
}

/** Light structural validation; returns a list of error strings (empty = ok). `ctx` gives cross-file key sets. */
export function validateStages(stages, ctx = {}) {
  const errs = [];
  const E = (id, msg) => errs.push(`stage ${id}: ${msg}`);
  const ids = new Set();
  let prev = -Infinity;
  for (const s of stages) {
    const id = s.id;
    if (!Number.isInteger(id) || id < 1) E(id, 'id must be a positive integer');
    if (ids.has(id)) E(id, 'duplicate id'); ids.add(id);
    if (id <= prev) E(id, 'stages must be sorted by id'); prev = id;
    for (const k of ['title', 'highway', 'direction', 'sky', 'throwItem', 'vms']) if (typeof s[k] !== 'string') E(id, `${k} must be a string`);
    for (const k of ['jamLength', 'displayKm', 'density', 'jamSpeed', 'fine', 'payout', 'difficulty', 'chapter']) if (typeof s[k] !== 'number' || !Number.isFinite(s[k])) E(id, `${k} must be a finite number`);
    if (!Array.isArray(s.villains) || !s.villains.length) E(id, 'villains must be a non-empty array');
    for (const v of s.villains || []) {
      if (typeof v.kind !== 'string') E(id, 'villain.kind must be a string');
      if (typeof v.lane !== 'number' || v.lane < 0 || v.lane > 3) E(id, `villain.lane out of range: ${v.lane}`);
      if (!(v.hp > 0)) E(id, 'villain.hp must be > 0');
      if (ctx.vehicleKinds && !ctx.vehicleKinds.has(v.kind)) E(id, `villain.kind ${v.kind} not in vehicle_kinds`);
    }
    if (!Array.isArray(s.frontRow) || s.frontRow.length !== 4) E(id, 'frontRow must be array[4]');
    for (const fk of s.frontRow || []) if (fk !== null && (typeof fk !== 'string' || (ctx.vehicleKinds && !ctx.vehicleKinds.has(fk)))) E(id, `frontRow kind ${fk} invalid`);
    const pairsOk = (p) => Array.isArray(p) && p.every((x) => Array.isArray(x) && x.length === 2 && typeof x[0] === 'string' && typeof x[1] === 'number');
    if (!pairsOk(s.attacks)) E(id, 'attacks must be [[kind, weight], ...]');
    if (s.phases !== null && !(Array.isArray(s.phases) && s.phases.every((ph) => pairsOk(ph.attacks) && typeof ph.hp === 'number'))) E(id, 'phases must be null or [{hp, attacks:[[k,w]]...}]');
    if (!Array.isArray(s.shoulder) || !s.shoulder.every((x) => Array.isArray(x) && typeof x[0] === 'string' && Number.isInteger(x[1]))) E(id, 'shoulder must be [[kind, count], ...]');
    if (!Array.isArray(s.attackInterval) || s.attackInterval.length !== 2) E(id, 'attackInterval must be [min, max]');
    if (!Array.isArray(s.road) || !s.road.length || !s.road.every((r) => r && ROAD_SEGMENT_TYPES.includes(r.type))) E(id, 'road must be a non-empty array of {type}');
    if (ctx.skyPresets && !ctx.skyPresets.has(s.sky)) E(id, `sky ${s.sky} not in sky.json presets`);
    if (s.approach !== null && (typeof s.approach !== 'object' || (s.approach.shoulder && !SHOULDER_MODES.includes(s.approach.shoulder)))) E(id, 'approach invalid');
    if (s.jamShape !== null && !(s.jamShape && Array.isArray(s.jamShape.lanes) && s.jamShape.lanes.every((k) => LANE_KINDS.includes(k)))) E(id, 'jamShape.lanes invalid');
    if (s.sig !== null && typeof s.sig !== 'string') E(id, 'sig must be string|null');
    if (s.zigCenter !== null && typeof s.zigCenter !== 'number') E(id, 'zigCenter must be number|null');
  }
  return errs;
}
