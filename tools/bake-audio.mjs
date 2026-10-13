// Offline SFX bake for the native port (NATIVE_PORT 3-8 오디오, M1a: 경적 SFX 1개).
//
// 가설: running the web's own `hornTone` recipe (source text extracted from the frozen game/js/audio.js, not a
//       re-implementation) inside Chromium's OfflineAudioContext gives the exact web horn, and tapping the SFX bus
//       BEFORE the DynamicsCompressor/clipper avoids double compression with Godot's Master bus (NATIVE_PORT 3-8 탭 위치).
//
//   node tools/bake-audio.mjs [--out=native/audio] [--rate=48000] [--check]
//
// Writes <out>/horn.wav (+ hornShort.wav) as 16-bit PCM mono, and <out>/sfx_bake.json with the recipe, peak and rms.
// Level = per-SFX gain (SFX.horn.g) × SFX bus gain (0.9), i.e. exactly what reaches the web compressor input.
// Math.random (detune jitter) is a seeded mulberry32; Chromium's render still wobbles by ≤ 1 LSB, --check allows 2.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const arg = (k, d) => { const a = process.argv.find((x) => x.startsWith(`--${k}=`)); return a ? a.slice(k.length + 3) : d; };
const OUT = path.resolve(ROOT, arg('out', 'native/audio'));
const RATE = +arg('rate', 48000);
const CHECK = process.argv.includes('--check');

const src = fs.readFileSync(path.join(ROOT, 'game/js/audio.js'), 'utf8');
const grab = (re, what) => { const m = src.match(re); if (!m) throw new Error(`bake-audio: ${what} not found in audio.js`); return m[0]; };
// function bodies are taken verbatim; the brace matcher stops at the first column-0 closing brace
const fnSrc = (name) => grab(new RegExp(`^function ${name}\\b[\\s\\S]*?^}`, 'm'), name);
const lineSrc = (re, what) => grab(re, what);
const recipe = {
  hornTone: fnSrc('hornTone'),
  G: lineSrc(/^function G\b.*$/m, 'G'),
  F: fnSrc('F'),
  rand: lineSrc(/^const rand = .*$/m, 'rand'),
  sfx: {
    horn: lineSrc(/^\s*horn:\s*\{.*$/m, 'SFX.horn'),
    hornShort: lineSrc(/^\s*hornShort:\s*\{.*$/m, 'SFX.hornShort'),
  },
  sfxBusGain: +grab(/n\.sfx = G\(([\d.]+), n\.comp\)/, 'sfx bus gain').match(/G\(([\d.]+)/)[1],
};

function loadPlaywright() {
  for (const p of ['playwright', '/opt/node22/lib/node_modules/playwright']) { try { return require(p); } catch { /* next */ } }
  throw new Error('playwright not found');
}

const pw = loadPlaywright();
const browser = await pw.chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage();
const results = await page.evaluate(async ({ recipe, rate }) => {
  const out = {};
  for (const [name, line] of Object.entries(recipe.sfx)) {
    // SFX table line: `horn: { g: 0.36, dur: 0.5, ..., fn: (t, p, d) => hornTone(...) },`
    const body = line.trim().replace(/^\w+:\s*/, '').replace(/,\s*$/, '');
    let a = 0x5eed1007 | 0;
    const seeded = () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
    const make = new Function('Math', `let C = null;\n${recipe.G}\n${recipe.F}\n${recipe.rand}\n${recipe.hornTone}\n` +
      `const m = (${body});\nreturn { m, bind: (ctx) => { C = ctx; }, G: (v, d) => G(v, d) };`);
    const MathSeeded = Object.create(Math); MathSeeded.random = seeded;
    const env = make(MathSeeded);
    const len = Math.ceil((env.m.dur + 0.25) * rate);
    const ctx = new OfflineAudioContext(1, len, rate);
    env.bind(ctx);
    const bus = env.G(recipe.sfxBusGain, ctx.destination);      // SFX bus, tapped before the compressor
    env.m.fn(0.005, 1, env.G(env.m.g, bus));                      // play(): G(vol * m.g, sfx bus), pitch 1, pan 0
    const buf = await ctx.startRendering();
    out[name] = { data: Array.from(buf.getChannelData(0)), dur: env.m.dur, g: env.m.g };
  }
  return out;
}, { recipe, rate: RATE });
await browser.close();

function wav16(samples, rate) {
  const n = samples.length, b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVE', 8); b.write('fmt ', 12);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24);
  b.writeUInt32LE(rate * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(samples[i] * 32767))), 44 + i * 2);
  return b;
}

fs.mkdirSync(OUT, { recursive: true });
const meta = { generator: 'tools/bake-audio.mjs', source: 'game/js/audio.js (web-frozen 753549a) hornTone, tapped pre-compressor', rate: RATE, sfx: {} };
let stale = 0;
for (const [name, r] of Object.entries(results)) {
  // trim trailing silence (keep 10 ms tail)
  let end = r.data.length; while (end > 1 && Math.abs(r.data[end - 1]) < 1e-4) end--;
  const s = r.data.slice(0, Math.min(r.data.length, end + Math.round(0.01 * RATE)));
  let peak = 0, sq = 0; for (const v of s) { peak = Math.max(peak, Math.abs(v)); sq += v * v; }
  const bytes = wav16(s, RATE);
  const file = path.join(OUT, `${name}.wav`);
  const sha = crypto.createHash('sha256').update(bytes).digest('hex').slice(0, 16);
  meta.sfx[name] = { file: `${name}.wav`, samples: s.length, seconds: +(s.length / RATE).toFixed(4), peak: +peak.toFixed(4),
    rms: +Math.sqrt(sq / s.length).toFixed(4), sha256_16: sha, g: r.g };
  if (CHECK) {
    // Chromium's audio render is not bit-stable run to run (measured: ≤ 1 LSB on ~0.15 % of samples), so compare
    // with a 2-LSB tolerance instead of bytes.
    let same = fs.existsSync(file), maxd = 0;
    if (same) {
      const old = fs.readFileSync(file);
      same = old.length === bytes.length;
      for (let i = 44; same && i < bytes.length; i += 2) maxd = Math.max(maxd, Math.abs(old.readInt16LE(i) - bytes.readInt16LE(i)));
      same = same && maxd <= 2;
    }
    if (!same) stale++;
    console.log(`${same ? 'same ' : 'STALE'} ${name}.wav (max |Δ| ${maxd} LSB)`);
  } else {
    fs.writeFileSync(file, bytes);
    console.log(`wrote ${path.relative(ROOT, file)} ${meta.sfx[name].seconds}s peak=${meta.sfx[name].peak} rms=${meta.sfx[name].rms} sha=${sha}`);
  }
}
if (!CHECK) fs.writeFileSync(path.join(OUT, 'sfx_bake.json'), JSON.stringify(meta, null, 1) + '\n');
process.exit(stale ? 1 : 0);
