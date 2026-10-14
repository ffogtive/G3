// RNG call-site tagging for the golden traces (NATIVE_PORT 3-3: "계약의 원천은 골든 트레이스다").
//
// Each traffic rng() call is identified by the JS call site that made it (file:line:col from the V8 stack) and,
// for draws made inside shared helpers (pickWeighted, _makeCar, gapOf, buildShoulderObstacle), by the helper's
// caller too. LINE_TAGS names every `rng()` occurrence on a line, left to right; the reported column must match
// one occurrence exactly or tagging fails (so a stale map can never mislabel a draw).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const GAME_JS = fileURLToPath(new URL('../../../game/js/', import.meta.url));

/** 'file.js:line' → names of the rng() occurrences on that line, in column order. */
export const LINE_TAGS = {
  'traffic.js:42': ['pickWeighted'],
  'traffic.js:85': ['car.mono'],
  'traffic.js:87': ['car.color'],
  'traffic.js:88': ['car.seed'],
  'traffic.js:95': ['car.personal'],
  'traffic.js:96': ['car.phase'],
  'traffic.js:142': ['wall.offset'],
  'traffic.js:157': ['gap.spaced', 'gap.pass', 'gap.train', 'gap.flow', 'gap.packed'],
  'traffic.js:158': ['lead.spaced', 'lead'],
  'traffic.js:189': ['shoulder.shuffle'],
  'traffic.js:194': ['shoulder.jitter'],
  'traffic.js:197': ['cheater.v'],
  'traffic.js:217': ['mini.type'],
  'traffic.js:218': ['mini.cool'],
  'traffic.js:228': ['opp.lane'],
  'traffic.js:230': ['opp.mono'],
  'traffic.js:231': ['opp.color'],
  'traffic.js:235': ['opp.s', 'opp.v'],
  // runtime (Traffic.update and helpers)
  'traffic.js:316': ['release.vFree.slow', 'release.vFree'],
  'traffic.js:337': ['brake.roll'],
  'traffic.js:339': ['brake.pick', 'brake.hold'],
  'traffic.js:346': ['cheaterEvent.next'],
  'traffic.js:371': ['mini.throwCool'],
  'traffic.js:383': ['release.nextLc'],
  'traffic.js:475': ['opp.respawn'],
  'traffic.js:482': ['postRelease.next'],
  'traffic.js:626': ['cheaterEvent.pick'],
  'traffic.js:629': ['cheaterEvent.v'],
  'traffic.js:680': ['honk.fatigue'],
  // shoulder obstacles (buildShoulderObstacle)
  'shoulder.js:50': ['breakdown.kind', 'breakdown.color'],
  'shoulder.js:53': ['breakdown.rotY'],
  'shoulder.js:70': ['debris.count'],
  'shoulder.js:73': ['debris.box.x', 'debris.box.z'],
  'shoulder.js:74': ['debris.box.rotY'],
  'shoulder.js:79': ['debris.tire.x'],
};

/** Lines whose draws happen inside a shared helper → the tag is prefixed with the helper's caller context. */
const HELPER_LINES = new Set(['traffic.js:42', 'traffic.js:85', 'traffic.js:87', 'traffic.js:88', 'traffic.js:95', 'traffic.js:96', 'traffic.js:157',
  'shoulder.js:50', 'shoulder.js:53', 'shoulder.js:70', 'shoulder.js:73', 'shoulder.js:74', 'shoulder.js:79']);
/** 'file.js:line' of a helper call → context name. */
export const CALLER_TAGS = {
  'traffic.js:143': 'wall',       // _makeCar for the front-row wall
  'traffic.js:160': 'lane',       // pickWeighted(NPC_KINDS) for jam lanes
  'traffic.js:161': 'lane',       // _makeCar for jam lanes
  'traffic.js:169': 'lane',       // gapOf()
  'traffic.js:196': 'cheater',    // pickWeighted(cheater kinds) + _makeCar
  'traffic.js:200': 'obstacle',   // buildShoulderObstacle
  'traffic.js:229': 'opp',        // pickWeighted(NPC_KINDS) for the opposite carriageway
};

const srcLines = new Map();
function lineText(file, line) {
  if (!srcLines.has(file)) srcLines.set(file, readFileSync(GAME_JS + file, 'utf8').split('\n'));
  return srcLines.get(file)[line - 1] ?? '';
}
/** 1-based columns of each `rng(` call on a line (both `rng()` and `this.rng()`; column = the `r`). */
function rngColumns(file, line) {
  const t = lineText(file, line), cols = [];
  const re = /\brng\(\)/g;
  let m;
  while ((m = re.exec(t))) cols.push(m.index + 1);
  return cols;
}

/** Normalize a stack location to 'file.js' (game/js relative) or null if it is not a game/js file. */
export function gameFile(fileOrUrl) {
  if (!fileOrUrl) return null;
  const m = /\/game\/js\/([^?#:]+)/.exec(fileOrUrl);
  return m ? m[1] : null;
}

/**
 * @param {{file:string,line:number,col:number}} site   frame that called rng()
 * @param {{file:string,line:number,col:number}|null} caller  next game/js frame (for helper draws)
 * @returns {string} tag, e.g. 'lane/car.seed', 'shoulder.jitter'
 */
export function tagOf(site, caller) {
  const key = `${site.file}:${site.line}`;
  const names = LINE_TAGS[key];
  if (!names) throw new Error(`rng-trace: unmapped rng() site ${key}:${site.col}`);
  const cols = rngColumns(site.file, site.line);
  if (cols.length !== names.length) throw new Error(`rng-trace: ${key} has ${cols.length} rng() calls but ${names.length} tags`);
  const idx = cols.indexOf(site.col);
  if (idx < 0) throw new Error(`rng-trace: ${key}: column ${site.col} is not an rng() call (cols ${cols.join(',')})`);
  const name = names[idx];
  if (!HELPER_LINES.has(key)) return name;
  const ck = caller ? `${caller.file}:${caller.line}` : null;
  const ctx = ck && CALLER_TAGS[ck];
  if (!ctx) throw new Error(`rng-trace: helper draw ${key} from unmapped caller ${ck}`);
  return `${ctx}/${name}`;
}

/** Node: wraps a mulberry32 stream; every call records { u32, site, caller } from structured V8 call sites. */
export function tracingRng(base, log) {
  const fn = function rng() {
    const prep = Error.prepareStackTrace, lim = Error.stackTraceLimit;
    Error.prepareStackTrace = (_e, cs) => cs;
    Error.stackTraceLimit = 12;
    const cs = new Error().stack;
    Error.prepareStackTrace = prep;
    Error.stackTraceLimit = lim;
    const frames = [];
    for (const c of cs.slice(1)) {
      const f = gameFile(c.getFileName());
      if (f) frames.push({ file: f, line: c.getLineNumber(), col: c.getColumnNumber() });
      if (frames.length === 2) break;
    }
    const v = base();
    log.push({ u32: Math.round(v * 4294967296), site: frames[0] || null, caller: frames[1] || null });
    return v;
  };
  return fn;
}

/** Browser stack string → [{file,line,col}] of game/js frames (Chrome format "at fn (url:line:col)"). */
export function parseChromeStack(stack) {
  const out = [];
  for (const ln of String(stack).split('\n').slice(1)) {
    const m = /\(?((?:https?|file):\/\/[^\s)]+):(\d+):(\d+)\)?\s*$/.exec(ln);
    if (!m) continue;
    const f = gameFile(m[1]);
    if (f) out.push({ file: f, line: +m[2], col: +m[3] });
  }
  return out;
}

export const siteStr = (s) => (s ? `${s.file}:${s.line}:${s.col}` : null);
