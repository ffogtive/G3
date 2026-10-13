// Vehicle kinds table for the sim (NATIVE_PORT 3-2 "차 치수를 메시가 아니라 vehicle_kinds.json에서 읽는다").
//
// The web reads car length/width from the built mesh (vehicles.js info.L / info.W), so a spawn can only be reproduced
// with the real per-variant dimensions. KINDS is module-private in vehicles.js, so its literal is evaluated from the
// frozen source (build functions replaced by names) and the dimensions are measured by building each variant with
// the real, unmodified vehicles.js. Wheels/pivots/meshes are the bake pipeline's job (3-7), not this table.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { extractConst, evalLiteral } from './js-source.mjs';

const VEHICLES_JS = fileURLToPath(new URL('../../../game/js/vehicles.js', import.meta.url));

export function kindsDefs(PLAYER_COLOR) {
  const src = readFileSync(VEHICLES_JS, 'utf8');
  const text = extractConst(src, 'KINDS').replace(/build:\s*(\w+)/g, 'build: "$1"');
  // MOTO is only read inside variantColor/livery closures; a proxy keeps those callable without the real table.
  const MOTO = new Proxy([], { get: (t, k) => (k === 'length' ? 4 : { col: null }) });
  return evalLiteral(text, { PLAYER_COLOR, MOTO });
}

/**
 * @param {object} VEH  the (real) vehicles.js module namespace
 * @param {number} PLAYER_COLOR
 */
export function vehicleKindsTable(VEH, PLAYER_COLOR) {
  const defs = kindsDefs(PLAYER_COLOR);
  const names = Object.keys(defs);
  const exported = [...VEH.VEHICLE_KINDS];
  if (JSON.stringify(names) !== JSON.stringify(exported)) throw new Error(`vehicle-kinds: KINDS keys ${names} != VEHICLE_KINDS ${exported}`);
  const kinds = {};
  for (const name of names) {
    const d = defs[name];
    const nv = d.variants || 1;
    const canon = Array.from({ length: nv }, (_, raw) => (d.canon ? d.canon(raw) : raw));
    const variants = [...new Set(canon)].sort((a, b) => a - b);
    if (variants.some((v, i) => v !== i)) throw new Error(`vehicle-kinds: ${name} canonical variants not 0..n-1: ${variants}`);
    const dims = { simple: [], detailed: [] };
    for (const [mode, detailed] of [['simple', false], ['detailed', true]]) {
      for (const v of variants) {
        const raw = canon.indexOf(v);
        const ud = VEH.buildVehicle(name, { variant: raw, detailed }).userData;
        dims[mode][v] = { L: ud.length, W: ud.width, H: ud.height };
      }
    }
    // sanity: building through the seed path gives the same dims as the variant path
    for (let raw = 0; raw < nv; raw++) {
      const a = VEH.buildVehicle(name, { seed: raw }).userData, b = dims[d.detailed ? 'detailed' : 'simple'][canon[raw]];
      if (a.length !== b.L || a.width !== b.W) throw new Error(`vehicle-kinds: ${name} raw ${raw} seed-path dims differ`);
    }
    let livery = null;
    if (d.livery) { try { livery = canon.map((v) => d.livery(v) >>> 0); } catch { livery = null; } }
    kinds[name] = {
      variants: nv,
      canon,                               // canon[seed % variants] = geometry variant
      colorVariant: !!d.colorVariant,      // seed/variant not given → variant = color % variants
      detailedDefault: !!d.detailed,
      defaultColor: d.color != null ? d.color >>> 0 : null,
      livery,                              // per raw index (color override), or null
      hasVariantColor: !!d.variantColor,
      dims,                                // dims[simple|detailed][variant] = {L, W, H} (m, array index = variant); sim uses L/W
    };
  }
  return {
    schema_version: 1,
    doc: 'variant = canon[floor(|seed|) % variants] (NPC cars: seed = floor(rng*1e6)); if seed and variant are both absent: colorVariant ? color % variants : canon[0]. len = dims[detailed?"detailed":"simple"][variant].L, w = .W. detailed defaults to detailedDefault (villains are built with detailed:true, NPC/obstacle cars with the default).',
    source: 'game/js/vehicles.js KINDS + real buildVehicle() (web-frozen 753549a)',
    kinds,
  };
}

/** Variant a buildVehicle(kind, opts) call resolves to (mirror of vehicles.js buildVehicle). */
export function resolveVariant(table, kind, opts = {}) {
  const k = table.kinds[kind] || table.kinds.sedan;
  const nv = k.variants;
  const raw = opts.variant !== undefined ? Math.floor(Math.abs(opts.variant)) % nv : Math.floor(Math.abs(opts.seed ?? 0)) % nv;
  if (k.colorVariant && opts.seed === undefined && opts.variant === undefined) {
    const color = (opts.color ?? k.defaultColor) >>> 0;
    return color % nv;
  }
  return k.canon[raw];
}
