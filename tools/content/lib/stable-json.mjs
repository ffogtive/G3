// Deterministic JSON writer shared by tools/export-content.mjs and tools/content/build.mjs.
//
// - Object keys are sorted (code-point order) at every depth, so output never depends on insertion order.
//   Anything whose ORDER MATTERS (RNG pick order, weighted pick order) must therefore be an array in the data.
// - Arrays keep their order.
// - Numbers use JS shortest round-trip formatting (exact for every double), except `Raw` values, which are
//   written verbatim (used for 17-significant-digit float goldens).
// - NaN / Infinity / undefined / functions are rejected (they have no JSON form and would silently vanish).
// - Compact mode puts short arrays of scalars on one line to keep goldens diffable but small.

export class Raw {
  constructor(text) {
    if (!/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(text)) throw new Error(`Raw: not a JSON number: ${text}`);
    this.text = text;
  }
}

/** 17 significant digits, e.g. 0.37143707205541432 (round-trips exactly, and is what the golden contract asks for). */
export const f17 = (x) => {
  if (!Number.isFinite(x)) throw new Error(`f17: non-finite ${x}`);
  if (x === 0) return new Raw(Object.is(x, -0) ? '-0.0' : '0.0');
  return new Raw(normalizeExp(x.toPrecision(17)));
};
function normalizeExp(s) {
  // toPrecision may emit '1.2345678901234567e-7' — valid JSON. Keep as is, but strip a '+' in exponent for tidiness.
  return s.replace('e+', 'e');
}

function scalar(v, path) {
  if (v === null) return 'null';
  if (v instanceof Raw) return v.text;
  switch (typeof v) {
    case 'number':
      if (!Number.isFinite(v)) throw new Error(`stable-json: non-finite number at ${path}`);
      return Object.is(v, -0) ? '0' : JSON.stringify(v);
    case 'string': return JSON.stringify(v);
    case 'boolean': return v ? 'true' : 'false';
    default: return undefined;
  }
}

/**
 * @param {unknown} value
 * @param {{ indent?: number, inlineScalarArrays?: number }} [opts]
 *   inlineScalarArrays: arrays of <= N scalars are printed on one line (0 = never). Default 24.
 */
export function stableStringify(value, opts = {}) {
  const indent = opts.indent ?? 2;
  const inlineN = opts.inlineScalarArrays ?? 24;
  const pad = (d) => ' '.repeat(indent * d);
  const walk = (v, d, path) => {
    const s = scalar(v, path);
    if (s !== undefined) return s;
    if (v === undefined || typeof v === 'function' || typeof v === 'symbol' || typeof v === 'bigint') {
      throw new Error(`stable-json: unsupported value (${typeof v}) at ${path}`);
    }
    if (Array.isArray(v)) {
      if (!v.length) return '[]';
      const parts = v.map((x, i) => walk(x, d + 1, `${path}[${i}]`));
      const allScalar = v.every((x) => scalar(x, path) !== undefined);
      if (allScalar && v.length <= inlineN) return `[${parts.join(', ')}]`;
      return `[\n${parts.map((p) => pad(d + 1) + p).join(',\n')}\n${pad(d)}]`;
    }
    if (typeof v === 'object') {
      const keys = Object.keys(v).sort();
      if (!keys.length) return '{}';
      const parts = keys.map((k) => {
        if (v[k] === undefined) throw new Error(`stable-json: undefined at ${path}.${k} (normalize to null first)`);
        return `${pad(d + 1)}${JSON.stringify(k)}: ${walk(v[k], d + 1, `${path}.${k}`)}`;
      });
      return `{\n${parts.join(',\n')}\n${pad(d)}}`;
    }
    throw new Error(`stable-json: unsupported at ${path}`);
  };
  return walk(value, 0, '$') + '\n';
}

/** Recursively turn `undefined` object fields into `null` (JS `??` / truthiness treat both the same). Arrays must not hold undefined. */
export function undefToNull(v, path = '$') {
  if (Array.isArray(v)) return v.map((x, i) => {
    if (x === undefined) throw new Error(`undefToNull: undefined array element at ${path}[${i}]`);
    return undefToNull(x, `${path}[${i}]`);
  });
  if (v && typeof v === 'object' && !(v instanceof Raw)) {
    const o = {};
    for (const k of Object.keys(v)) o[k] = v[k] === undefined ? null : undefToNull(v[k], `${path}.${k}`);
    return o;
  }
  return v;
}

/** Order-insensitive deep equality for plain JSON data (object key order ignored, array order respected). */
export function deepEqual(a, b, path = '$', diffs = [], max = 20) {
  if (diffs.length >= max) return diffs;
  if (a === b || (Number.isNaN(a) && Number.isNaN(b))) return diffs;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') {
    diffs.push(`${path}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
    return diffs;
  }
  if (Array.isArray(a) !== Array.isArray(b)) { diffs.push(`${path}: array/object mismatch`); return diffs; }
  if (Array.isArray(a)) {
    if (a.length !== b.length) diffs.push(`${path}: length ${a.length} != ${b.length}`);
    for (let i = 0; i < Math.min(a.length, b.length); i++) deepEqual(a[i], b[i], `${path}[${i}]`, diffs, max);
    return diffs;
  }
  const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
  for (const k of new Set([...ka, ...kb])) {
    if (!(k in a)) diffs.push(`${path}.${k}: missing on left`);
    else if (!(k in b)) diffs.push(`${path}.${k}: missing on right`);
    else deepEqual(a[k], b[k], `${path}.${k}`, diffs, max);
    if (diffs.length >= max) break;
  }
  return diffs;
}
