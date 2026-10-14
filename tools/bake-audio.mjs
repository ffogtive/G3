// Offline audio bake for the native port (NATIVE_PORT 3-8 오디오, M1c "오디오 bake 전체").
//
// 가설: the frozen web module game/js/audio.js itself (imported unmodified into headless Chromium and bound to an
//       OfflineAudioContext via audio.init({context})) renders every SFX, the 4 songs, both ambiences and the engine,
//       so the native app sounds like the web. Tapping BEFORE the DynamicsCompressor/clipper (compressor patched to a
//       unity pass-through, noLimiter on) keeps Godot's Master Compressor+Limiter the only dynamics stage.
//
//   node tools/bake-audio.mjs [--out=native/audio] [--rate=44100] [--only=horn,jam,...] [--check]
//
// Outputs (all in --out, names = what native/autoload/audio.gd plays):
//   <sfx>.wav            every name in audio.js SFX{} + "cheer" (cheerHorns 대~한민국 합주), 16-bit PCM, mono unless L≠R
//   sk_*.wav fin_*.wav   native-only skill / finisher SFX (SKILL_SFX + SKILL_SRC below, docs/SKILLS.md 2-6)
//   mus_<song>.ogg       menu/jam/boss/release, seamless loops (release keeps its 2-bar intro → loop_offset)
//   amb_<kind>.ogg       jam (idle hum + distant honks, stereo) / free (wind), seamless loops
//   eng_lo.wav eng_hi.wav  engine tone at f_ref (throttle 0.4 / 1.0), exact-period loops; eng_road.wav road noise loop
//   audio_bake.json      manifest: files, loop points, seams, levels, the web voice-limit table and engine model
//   *.import             Godot import params (loop on for mus_/amb_/eng_; one-shots QOA, no loop)
// Levels include the web bus gains (sfx 0.9, amb 0.6, music 0.8 × song gain), i.e. exactly the compressor input.
// Math.random is a seeded mulberry32 per render; Chromium's render still wobbles by ≤ 1 LSB, so --check compares
// WAVs with a 2-LSB tolerance and OGGs by pre-encode rms/peak (±1 %).
// Loops: music/ambience are cut from a later iteration and the last F ms are cross-faded into the material that
// precedes the loop start in the render, so sample N-1 flows into sample 0 (seam is measured and must be ≤ the
// signal's own p99.9 second difference ×3). Ambience boundaries are chosen where no distant honk sounds (found by
// diffing against a render with the horn oscillators muted). Engine/road are exactly periodic (all partials are
// whole cycles in 3.2 s / the 2 s noise buffer), so they need no crossfade.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const arg = (k, d) => { const a = process.argv.find((x) => x.startsWith(`--${k}=`)); return a ? a.slice(k.length + 3) : d; };
const OUT = path.resolve(ROOT, arg('out', 'native/audio'));
const RATE = +arg('rate', 44100);
const CHECK = process.argv.includes('--check');
const ONLY = arg('only', '') ? new Set(arg('only', '').split(',')) : null;
const want = (n) => !ONLY || ONLY.has(n);

// ───────────────────────────── single truth = audio.js / main.js source text
const src = fs.readFileSync(path.join(ROOT, 'game/js/audio.js'), 'utf8');
const mainSrc = fs.readFileSync(path.join(ROOT, 'game/js/main.js'), 'utf8');
const need = (s, re, what) => { const m = s.match(re); if (!m) throw new Error(`bake-audio: ${what} not found`); return m; };
const makeupDb = +need(src, /COMP_MAKEUP_COMP = Math\.pow\(10, (-?[\d.]+) \/ 20\)/, 'COMP_MAKEUP_COMP')[1];
const RELEASE_BPM = +need(src, /const RELEASE_BPM = (\d+)/, 'RELEASE_BPM')[1];
const sfxBlock = need(src, /^const SFX = \{([\s\S]*?)^\};/m, 'SFX table')[1];
const SFXT = {};
for (const line of sfxBlock.split('\n')) {
  const m = /^\s+(\w+):\s*\{\s*g:\s*([\d.]+),\s*dur:\s*([\d.]+),\s*max:\s*(\d+),\s*gap:\s*([\d.]+)(?:,\s*stagger:\s*([\d.]+))?(?:,\s*pri:\s*(\d))?/.exec(line);
  if (m) SFXT[m[1]] = { g: +m[2], dur: +m[3], max: +m[4], gap: +m[5], stagger: m[6] ? +m[6] : 0, pri: m[7] != null ? +m[7] : 1 };
}
if (Object.keys(SFXT).length < 25) throw new Error('bake-audio: SFX table parse failed');
const SONGS = {};
for (const kind of ['menu', 'jam', 'boss', 'release']) {
  const m = need(src, new RegExp(`\\n  ${kind}\\(\\) \\{\\n\\s+const b = new SB\\((\\w+), (\\d+)(?:, \\{([^}]*)\\})?\\);`), `song ${kind}`);
  const o = m[3] || '';
  const num = (k, d) => { const r = new RegExp(`${k}:\\s*([\\d.]+)`).exec(o); return r ? +r[1] : d; };
  const bpm = /^\d+$/.test(m[1]) ? +m[1] : RELEASE_BPM;
  SONGS[kind] = { bpm, bars: +m[2], loopBar: num('loopBar', 0), gain: num('gain', 0.5), swing: num('swing', 0) };
}
const ENG = {
  gears: need(src, /const GEARS = \[([^\]]+)\]/, 'GEARS')[1].split(',').map(Number),
  rpm: need(src, /const rpm = gi === 0 \? ([\d.]+) \+ ([\d.]+) \* fr : ([\d.]+) \+ ([\d.]+) \* fr;/, 'rpm').slice(1, 5).map(Number),
  f: need(src, /const f = ([\d.]+) \+ ([\d.]+) \* rpm;/, 'engine f').slice(1, 3).map(Number),
  lvl: need(src, /const lvl = ([\d.]+) \+ ([\d.]+) \* th \+ ([\d.]+) \* rpm;/, 'engine lvl').slice(1, 4).map(Number),
  road: need(src, /e\.road\.gain\.setTargetAtTime\(([\d.]+) \* Math\.pow\(v \/ (\d+), ([\d.]+)\)/, 'road').slice(1, 4).map(Number),
  vmax: +need(src, /clamp\(num\(speedMs, 0\), 0, (\d+)\)/, 'engine vmax')[1],
  throttle: need(mainSrc, /audio\.setEngine\([^?]*\? ([\d.]+) : ([\d.]+)\)/, 'main.js setEngine throttle').slice(1, 3).map(Number), // [jam push, else]
  f_ref: 60, loop_s: 3.2,   // 60 Hz saw pair (+9 ct) + 30 Hz sub/AM → whole cycles in 3.2 s (o2: 193.0007)
};
const engState = (v, th) => { // audio.js setEngine() model, used to pick the bake speed for f_ref
  const G = ENG.gears; let gi = 0; while (gi < G.length - 2 && v >= G[gi + 1]) gi++;
  const fr = Math.min(1, Math.max(0, (v - G[gi]) / (G[gi + 1] - G[gi])));
  const rpm = gi === 0 ? ENG.rpm[0] + ENG.rpm[1] * fr : ENG.rpm[2] + ENG.rpm[3] * fr;
  return { rpm, f: ENG.f[0] + ENG.f[1] * rpm, lvl: ENG.lvl[0] + ENG.lvl[1] * th + ENG.lvl[2] * rpm };
};
const rpmRef = (ENG.f_ref - ENG.f[0]) / ENG.f[1];
const vRef = ((rpmRef - ENG.rpm[0]) / ENG.rpm[1]) * (ENG.gears[1] - ENG.gears[0]) + ENG.gears[0]; // gear 0

// ───────────────────────────── native-only skill SFX (docs/SKILLS.md 2-6)
// audio.js is frozen and exports no synth helpers, so the skill / finisher recipes live here as their own browser module
// (served as /skill_sfx.js) and render in the same OfflineAudioContext, pre-compressor, through the web sfx bus gain 0.9.
// Voice-limit rows use the audio.js SFX{} fields; `seconds` is the render length (the tail is trimmed afterwards).
const SKILL_SFX = {
  sk_charge:  { g: 1, dur: 0.45, max: 1, gap: 0.2,  stagger: 0, pri: 2, seconds: 0.8 },  // t5 telegraph: rising whine 0.35 s
  sk_carpet:  { g: 1, dur: 0.5,  max: 2, gap: 0.15, stagger: 0, pri: 1, seconds: 0.9 },  // t3: metal tack rain 0.4 s
  sk_drone:   { g: 1, dur: 0.8,  max: 1, gap: 0.3,  stagger: 0, pri: 1, seconds: 1.2 },  // drone dive: doppler whine 0.7 s
  sk_land:    { g: 1, dur: 0.35, max: 2, gap: 0.12, stagger: 0, pri: 2, seconds: 0.8 },  // jump landing: sub thud
  sk_wave:    { g: 1, dur: 0.5,  max: 2, gap: 0.15, stagger: 0, pri: 2, seconds: 0.9 },  // t1 shockwave: low "bwom" + air
  sk_tier1:   { g: 1, dur: 0.3,  max: 1, gap: 0.2,  stagger: 0, pri: 1, seconds: 0.8 },  // ready chimes
  sk_tier3:   { g: 1, dur: 0.45, max: 1, gap: 0.2,  stagger: 0, pri: 1, seconds: 1.0 },
  sk_tierMax: { g: 1, dur: 0.9,  max: 1, gap: 0.3,  stagger: 0, pri: 2, seconds: 1.6 },
  fin_rocket: { g: 1, dur: 1.6,  max: 1, gap: 0.5,  stagger: 0, pri: 2, seconds: 2.2 },  // finisher stingers ≤ 2 s
  fin_balloon:{ g: 1, dur: 1.5,  max: 1, gap: 0.5,  stagger: 0, pri: 2, seconds: 2.0 },
  fin_heli:   { g: 1, dur: 1.9,  max: 1, gap: 0.5,  stagger: 0, pri: 2, seconds: 2.4 },
  fin_ufo:    { g: 1, dur: 1.9,  max: 1, gap: 0.5,  stagger: 0, pri: 2, seconds: 2.4 },
};
const SKILL_SRC = String.raw`
const T0 = 0.02;
function noise(c, sec) { const n = Math.ceil(sec * c.sampleRate), b = c.createBuffer(1, n, c.sampleRate), d = b.getChannelData(0);
  for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1; return b; }
function gainAt(c, out, v = 0) { const g = c.createGain(); g.gain.value = v; g.connect(out); return g; }
function env(p, t, a, peak, hold, rel, floor = 0.0001) { p.setValueAtTime(floor, t); p.linearRampToValueAtTime(peak, t + a);
  p.setValueAtTime(peak, t + a + hold); p.exponentialRampToValueAtTime(floor, t + a + hold + rel); }
function osc(c, type, f, out, t, dur) { const o = c.createOscillator(); o.type = type; o.frequency.setValueAtTime(f, t);
  o.connect(out); o.start(t); o.stop(t + dur + 0.05); return o; }
function nsrc(c, out, t, dur) { const s = c.createBufferSource(); s.buffer = noise(c, dur + 0.05); s.connect(out); s.start(t); s.stop(t + dur + 0.05); return s; }
function filt(c, type, f, q, out) { const b = c.createBiquadFilter(); b.type = type; b.frequency.value = f; b.Q.value = q; b.connect(out); return b; }
function ping(c, out, t, f, dur, v, type = 'sine') { const g = gainAt(c, out); env(g.gain, t, 0.002, v, 0, dur); osc(c, type, f, g, t, dur); }
function boom(c, out, t, f0, f1, dur, v) { const g = gainAt(c, out); env(g.gain, t, 0.004, v, 0.02, dur);
  const o = osc(c, 'sine', f0, g, t, dur); o.frequency.exponentialRampToValueAtTime(f1, t + dur); }
function hiss(c, out, t, dur, v, type, f0, f1, q = 0.8) { const b = filt(c, type, f0, q, gainAt(c, out, 1)); b.frequency.setValueAtTime(f0, t);
  b.frequency.exponentialRampToValueAtTime(f1, t + dur); const g = c.createGain(); g.gain.value = 0; g.connect(b); env(g.gain, t, dur * 0.25, v, 0, dur * 0.75);
  nsrc(c, g, t, dur); return b; }
export const skill = {
  sk_charge(c, out) { // saw pair 180 → 900 Hz through an opening low-pass, tremolo speeding up, noise riser on top
    const t = T0, d = 0.38, lp = filt(c, 'lowpass', 700, 4, gainAt(c, out, 1)); lp.frequency.setValueAtTime(700, t);
    lp.frequency.exponentialRampToValueAtTime(7000, t + d);
    const g = c.createGain(); g.gain.value = 0; g.connect(lp); g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.32, t + d); g.gain.linearRampToValueAtTime(0.0, t + d + 0.06);
    for (const det of [-9, 9]) { const o = osc(c, 'sawtooth', 180, g, t, d + 0.06); o.detune.value = det; o.frequency.exponentialRampToValueAtTime(900, t + d); }
    const trem = c.createGain(); trem.gain.value = 0; trem.connect(g.gain); const lfo = osc(c, 'sine', 10, trem, t, d);
    lfo.frequency.linearRampToValueAtTime(34, t + d); trem.gain.setValueAtTime(0.0, t); trem.gain.linearRampToValueAtTime(0.12, t + d);
    hiss(c, out, t, d + 0.04, 0.22, 'bandpass', 900, 7000, 1.4);
  },
  sk_carpet(c, out) { // 22 metal clicks over 0.42 s (band-passed noise ticks + two inharmonic pings), rubber thrum under it
    for (let i = 0; i < 22; i++) { const t = T0 + 0.42 * (i / 22) + Math.random() * 0.016, f = 2600 + Math.random() * 4200;
      const g = gainAt(c, filt(c, 'bandpass', f, 6, out)); env(g.gain, t, 0.001, 0.9, 0, 0.025); nsrc(c, g, t, 0.04);
      ping(c, out, t, 1700 + Math.random() * 900, 0.06, 0.07); ping(c, out, t + 0.002, 3100 + Math.random() * 1500, 0.045, 0.05); }
    const lp = filt(c, 'lowpass', 300, 1, out); const g = c.createGain(); g.gain.value = 0; g.connect(lp);
    env(g.gain, T0, 0.05, 0.5, 0.25, 0.15); nsrc(c, g, T0, 0.5);
  },
  sk_drone(c, out) { // rotor buzz (saw AM at 75 Hz) with a doppler sweep: approach up, pass, fall away
    const t = T0, d = 0.72, lp = filt(c, 'lowpass', 2600, 2, gainAt(c, out, 1)), g = c.createGain(); g.gain.value = 0; g.connect(lp);
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.28, t + d * 0.55); g.gain.exponentialRampToValueAtTime(0.0001, t + d);
    const am = c.createGain(); am.gain.value = 0.5; am.connect(g); const buzz = c.createGain(); buzz.gain.value = 0.5; buzz.connect(am.gain);
    osc(c, 'square', 75, buzz, t, d);
    for (const [k, det] of [[1, 0], [2.01, 6]]) { const o = osc(c, 'sawtooth', 620 * k, am, t, d); o.detune.value = det;
      o.frequency.linearRampToValueAtTime(980 * k, t + d * 0.5); o.frequency.linearRampToValueAtTime(560 * k, t + d); }
    hiss(c, out, t, d, 0.06, 'highpass', 3000, 5000);
  },
  sk_land(c, out) { // sub drop 95 → 34 Hz, a low noise thump and a gritty asphalt crunch
    boom(c, out, T0, 95, 34, 0.32, 0.95); boom(c, out, T0, 190, 60, 0.12, 0.35);
    const lp = filt(c, 'lowpass', 500, 0.7, out), g = c.createGain(); g.gain.value = 0; g.connect(lp); env(g.gain, T0, 0.002, 0.9, 0.01, 0.09); nsrc(c, g, T0, 0.15);
    const bp = filt(c, 'bandpass', 1500, 1.2, out), g2 = c.createGain(); g2.gain.value = 0; g2.connect(bp); env(g2.gain, T0 + 0.005, 0.002, 0.45, 0.02, 0.12); nsrc(c, g2, T0, 0.2);
  },
  sk_wave(c, out) { // horn shockwave: a falling "bwom" + air rush that sweeps down like the pressure front passing
    boom(c, out, T0, 140, 45, 0.42, 0.7);
    const g = gainAt(c, out); env(g.gain, T0, 0.01, 0.22, 0.05, 0.3); const o = osc(c, 'sawtooth', 220, filt(c, 'lowpass', 900, 1, g), T0, 0.4);
    o.frequency.exponentialRampToValueAtTime(70, T0 + 0.4);
    hiss(c, out, T0, 0.45, 0.35, 'bandpass', 5000, 400, 0.9);
  },
  sk_tier1(c, out) { ping(c, out, T0, 1318.5, 0.22, 0.32, 'triangle'); ping(c, out, T0 + 0.06, 1975.5, 0.3, 0.28, 'triangle'); },
  sk_tier3(c, out) { [1046.5, 1568, 2093].forEach((f, i) => { ping(c, out, T0 + i * 0.065, f, 0.28, 0.3, 'triangle'); ping(c, out, T0 + i * 0.065, f * 2.01, 0.12, 0.06); }); },
  sk_tierMax(c, out) { // C major arpeggio up to C7, a sparkle tail with vibrato and a soft sub under the first note
    [1046.5, 1318.5, 1568, 2093].forEach((f, i) => { ping(c, out, T0 + i * 0.055, f, 0.4, 0.28, 'triangle'); ping(c, out, T0 + i * 0.055, f * 1.5, 0.2, 0.05); });
    for (let i = 0; i < 9; i++) ping(c, out, T0 + 0.25 + i * 0.07, 3000 + Math.random() * 2500, 0.18, 0.06);
    boom(c, out, T0, 110, 55, 0.35, 0.4);
  },
  fin_rocket(c, out) { // ignition crack, roaring thrust (noise + 48 Hz saw) climbing away (pitch up, low-pass closing)
    const t = T0; boom(c, out, t, 120, 40, 0.3, 0.8);
    const lp = filt(c, 'lowpass', 3500, 0.8, gainAt(c, out, 1)); lp.frequency.setValueAtTime(3500, t + 0.05); lp.frequency.exponentialRampToValueAtTime(500, t + 1.5);
    const g = c.createGain(); g.gain.value = 0; g.connect(lp); env(g.gain, t, 0.05, 0.75, 0.35, 1.1); nsrc(c, g, t, 1.6);
    const g2 = gainAt(c, lp); env(g2.gain, t, 0.06, 0.3, 0.3, 1.0); const o = osc(c, 'sawtooth', 48, g2, t, 1.5); o.frequency.exponentialRampToValueAtTime(110, t + 1.4);
    hiss(c, out, t, 0.25, 0.4, 'highpass', 2000, 6000);
  },
  fin_balloon(c, out) { // six rubbery pops, then a slide whistle up as the bundle floats away
    for (let i = 0; i < 6; i++) { const t = T0 + i * 0.06, g = gainAt(c, out); env(g.gain, t, 0.002, 0.45, 0, 0.07);
      const o = osc(c, 'sine', 260 + i * 40, g, t, 0.08); o.frequency.exponentialRampToValueAtTime(900 + i * 60, t + 0.05);
      const bp = filt(c, 'bandpass', 2000, 2, out), g2 = c.createGain(); g2.gain.value = 0; g2.connect(bp); env(g2.gain, t, 0.001, 0.4, 0, 0.03); nsrc(c, g2, t, 0.05); }
    const t = T0 + 0.42, g = gainAt(c, out); env(g.gain, t, 0.08, 0.24, 0.7, 0.35);
    const o = osc(c, 'sine', 620, g, t, 1.15); o.frequency.exponentialRampToValueAtTime(1650, t + 1.05);
    const vib = c.createGain(); vib.gain.value = 18; vib.connect(o.frequency); osc(c, 'sine', 6.5, vib, t, 1.15);
  },
  fin_heli(c, out) { // rotor whup-whup (noise AM at 11 Hz) fading in, the hook clank at 0.6 s, then away
    const t = T0, lp = filt(c, 'lowpass', 700, 1.2, gainAt(c, out, 1)), g = c.createGain(); g.gain.value = 0; g.connect(lp);
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.5, t + 0.35); g.gain.setValueAtTime(0.5, t + 1.2); g.gain.exponentialRampToValueAtTime(0.0001, t + 1.95);
    const am = c.createGain(); am.gain.value = 0.55; am.connect(g); const lfoG = c.createGain(); lfoG.gain.value = 0.45; lfoG.connect(am.gain);
    const lfo = osc(c, 'sine', 11, lfoG, t, 1.95); lfo.frequency.linearRampToValueAtTime(13, t + 1.9); nsrc(c, am, t, 1.95);
    const tc = t + 0.6; [1250, 2310, 3470].forEach((f, i) => ping(c, out, tc, f, 0.18 - i * 0.03, 0.22 - i * 0.05));
    const bp = filt(c, 'bandpass', 3000, 1.5, out), g2 = c.createGain(); g2.gain.value = 0; g2.connect(bp); env(g2.gain, tc, 0.001, 0.6, 0, 0.04); nsrc(c, g2, tc, 0.06);
  },
  fin_ufo(c, out) { // wobbling sine with a rising sweep, ring shimmer, and the "bloop" vanish at 1.4 s
    const t = T0, g = gainAt(c, out); env(g.gain, t, 0.12, 0.26, 1.05, 0.2);
    const o = osc(c, 'sine', 520, g, t, 1.4); o.frequency.exponentialRampToValueAtTime(980, t + 1.35);
    const vib = c.createGain(); vib.gain.value = 120; vib.connect(o.frequency); const l = osc(c, 'sine', 7, vib, t, 1.4); l.frequency.linearRampToValueAtTime(14, t + 1.35);
    const g3 = gainAt(c, out); env(g3.gain, t + 0.1, 0.2, 0.07, 0.9, 0.2); const r = osc(c, 'triangle', 1560, g3, t + 0.1, 1.3);
    const rm = c.createGain(); rm.gain.value = 300; rm.connect(r.frequency); osc(c, 'sine', 31, rm, t + 0.1, 1.3);
    const tb = t + 1.4, g2 = gainAt(c, out); env(g2.gain, tb, 0.004, 0.4, 0.02, 0.22); const b = osc(c, 'sine', 1400, g2, tb, 0.26);
    b.frequency.exponentialRampToValueAtTime(180, tb + 0.24);
  },
};
`;

// ───────────────────────────── render jobs
const SEED = 0x5eed1007;
const fnv = (s) => { let h = 0x811c9dc5; for (const c of s) { h ^= c.charCodeAt(0); h = Math.imul(h, 0x01000193); } return h >>> 0; };
const jobs = [];
const VARIANTS = { tauntBlip: 3 }; // random syllables → a few seeded takes, played round-robin
for (const name of Object.keys(SFXT)) {
  const n = VARIANTS[name] || 1;
  for (let k = 0; k < n; k++) {
    const file = k ? `${name}_${k + 1}` : name;
    jobs.push({ kind: 'sfx', name, file, seconds: name === 'superHit' ? 3.6 : 3.0, seed: SEED ^ fnv(file) });
  }
}
jobs.push({ kind: 'cheer', name: 'cheer', file: 'cheer', seconds: 5.6, seed: SEED ^ fnv('cheer') });
for (const [kind, s] of Object.entries(SONGS)) {
  const sd = 60 / s.bpm / 4, P = (s.bars - s.loopBar) * 16 * sd, L0 = s.loopBar * 16 * sd;
  jobs.push({ kind: 'music', name: kind, file: `mus_${kind}`, seconds: 0.06 + L0 + 2 * P + 2.5, seed: SEED ^ fnv(kind), P, L0, s0: 0.06 });
}
const WIND_LFO = [0.11, 0.37, 0.21]; // audio.js startAmb('free') LFO rates
const windN = (() => { let best = [1e9, 0]; for (let n = 18; n <= 34; n += 0.001) {
  const e = Math.max(...WIND_LFO.map((f) => Math.abs(n * f - Math.round(n * f)))); if (e < best[0]) best = [e, n]; } return +best[1].toFixed(3); })();
jobs.push({ kind: 'amb', name: 'jam', file: 'amb_jam', seconds: 66, seed: SEED ^ fnv('amb_jam'), N: 2 / 0.07, F: 0.25 });
jobs.push({ kind: 'amb', name: 'free', file: 'amb_free', seconds: 5 + windN + 2, seed: SEED ^ fnv('amb_free'), N: windN, F: 0.4, A: 5 });
for (const [file, th] of [['eng_lo', ENG.throttle[1]], ['eng_hi', ENG.throttle[0]]]) {
  jobs.push({ kind: 'engine', name: file, file, seconds: 6, seed: SEED ^ fnv(file), v: vRef, th, mute: { buf: true } });
}
jobs.push({ kind: 'engine', name: 'road', file: 'eng_road', seconds: 6.5, seed: SEED ^ fnv('road'), v: ENG.road[1], th: ENG.throttle[1], mute: { osc: 'all' } });
for (const [name, t] of Object.entries(SKILL_SFX)) jobs.push({ kind: 'skill', name, file: name, seconds: t.seconds, seed: SEED ^ fnv(name) });
const todo = jobs.filter((j) => want(j.file) || want(j.name));

// ───────────────────────────── Chromium
function loadPlaywright() {
  for (const p of ['playwright', '/opt/node22/lib/node_modules/playwright']) { try { return require(p); } catch { /* next */ } }
  throw new Error('playwright not found');
}
const pw = loadPlaywright();
const browser = await pw.chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage();
await page.route('http://bake.invalid/**', (route) => {
  const p = new URL(route.request().url()).pathname;
  if (p === '/audio.js') return route.fulfill({ status: 200, contentType: 'text/javascript', body: src });
  if (p === '/skill_sfx.js') return route.fulfill({ status: 200, contentType: 'text/javascript', body: SKILL_SRC });
  return route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>bake</title>' });
});
await page.goto('http://bake.invalid/');
await page.evaluate(({ makeupDb }) => {
  const P = BaseAudioContext.prototype;
  // pre-compressor tap: the compressor becomes a gain that cancels master's makeup compensation → unity
  P.createDynamicsCompressor = function () {
    const g = this.createGain(); g.gain.value = 1 / Math.pow(10, makeupDb / 20);
    for (const k of ['threshold', 'knee', 'ratio', 'attack', 'release']) g[k] = { value: 0 };
    return g;
  };
  // layer isolation: window.__mute = { osc: 'all' | [types], buf: bool } makes those sources' connect() a no-op
  const wrap = (orig, test) => function () {
    const n = orig.call(this); const c = n.connect;
    n.connect = function (...a) { return test(this) ? a[0] : c.apply(this, a); };
    return n;
  };
  P.createOscillator = wrap(P.createOscillator, (o) => { const m = window.__mute || {}; return m.osc === 'all' || (Array.isArray(m.osc) && m.osc.includes(o.type)); });
  P.createBufferSource = wrap(P.createBufferSource, () => !!(window.__mute || {}).buf);
  let rev = 0;
  window.__bake = async (job, rate) => {
    let a = job.seed | 0; // mulberry32
    Math.random = () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
    window.__mute = job.mute || {};
    const { audio } = await import(`/audio.js?r=${++rev}`); // fresh module state per render
    const ctx = new OfflineAudioContext(2, Math.ceil(job.seconds * rate), rate);
    audio.init({ context: ctx, noLimiter: true });
    if (job.kind === 'skill') { // native-only recipe: same context, web sfx bus gain 0.9, no compressor
      const { skill } = await import(`/skill_sfx.js?r=${rev}`);
      const bus = ctx.createGain(); bus.gain.value = 0.9; bus.connect(ctx.destination); skill[job.name](ctx, bus);
    } else if (job.kind === 'sfx') audio.play(job.name);
    else if (job.kind === 'cheer') audio.cheerHorns();
    else if (job.kind === 'music') audio.startMusic(job.name);
    else if (job.kind === 'amb') audio.startAmbience(job.name);
    else if (job.kind === 'engine') audio.setEngine(job.v, job.th);
    const buf = await ctx.startRendering();
    const L = buf.getChannelData(0), R = buf.getChannelData(1);
    let d = 0; for (let i = 0; i < L.length; i++) d = Math.max(d, Math.abs(L[i] - R[i]));
    const b64 = (f) => { const u = new Uint8Array(f.buffer, f.byteOffset, f.byteLength); let s = '';
      for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
    return { ch: d < 1e-7 ? [b64(L)] : [b64(L), b64(R)] };
  };
}, { makeupDb });

const fromB64 = (s) => { const b = Buffer.from(s, 'base64'); return new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.length)); };
async function render(job) {
  const r = await page.evaluate(([j, rate]) => window.__bake(j, rate), [job, RATE]);
  return r.ch.map(fromB64);
}

// ───────────────────────────── DSP helpers
const S = (sec) => Math.round(sec * RATE);
function cutLoop(chs, { introFrom, introLen, A, N, F }) {
  return chs.map((x) => {
    const y = new Float32Array(introLen + N);
    const w = (j) => 0.5 - 0.5 * Math.cos((Math.PI * (j + 1)) / F);
    for (let i = 0; i < introLen; i++) y[i] = x[introFrom + i];
    for (let j = 0; introLen && j < F; j++) { const k = introLen - F + j; y[k] = x[introFrom + k] * (1 - w(j)) + x[A - F + j] * w(j); }
    for (let i = 0; i < N; i++) y[introLen + i] = x[A + i];
    for (let j = 0; j < F; j++) { const k = introLen + N - F + j; y[k] = x[A + N - F + j] * (1 - w(j)) + x[A - F + j] * w(j); }
    return y;
  });
}
function seamOf(chs, loopStart) { // wrap error of a 2nd-order predictor vs. the signal's own p99.9 2nd difference
  let worst = 0, ref = 0;
  for (const y of chs) {
    const n = y.length, d2 = [];
    for (let i = loopStart + 2; i < n; i += 7) d2.push(Math.abs(y[i] - 2 * y[i - 1] + y[i - 2]));
    d2.sort((a, b) => a - b);
    const p = d2[Math.floor(d2.length * 0.999)] || 0;
    const e = Math.abs(y[loopStart] - (2 * y[n - 1] - y[n - 2]));
    if (e / Math.max(p, 1e-4) > worst / Math.max(ref, 1e-4)) { worst = e; ref = p; }
  }
  return { err: +worst.toFixed(5), p999: +ref.toFixed(5), ok: worst <= Math.max(3 * ref, 1e-3) };
}
const stats = (chs) => { let pk = 0, sq = 0, n = 0; for (const y of chs) for (const v of y) { pk = Math.max(pk, Math.abs(v)); sq += v * v; n++; }
  return { peak: +pk.toFixed(4), rms: +Math.sqrt(sq / Math.max(1, n)).toFixed(5) }; };
function wav16(chs) {
  const C = chs.length, n = chs[0].length, b = Buffer.alloc(44 + n * 2 * C);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2 * C, 4); b.write('WAVE', 8); b.write('fmt ', 12);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(C, 22); b.writeUInt32LE(RATE, 24);
  b.writeUInt32LE(RATE * 2 * C, 28); b.writeUInt16LE(2 * C, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2 * C, 40);
  for (let i = 0; i < n; i++) for (let c = 0; c < C; c++) {
    b.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(chs[c][i] * 32767))), 44 + (i * C + c) * 2);
  }
  return b;
}
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'bake-audio-'));
function ogg(chs, file, q) {
  const C = chs.length, n = chs[0].length, raw = new Float32Array(n * C);
  for (let i = 0; i < n; i++) for (let c = 0; c < C; c++) raw[i * C + c] = chs[c][i];
  const tmp = path.join(TMP, 'in.f32');
  fs.writeFileSync(tmp, Buffer.from(raw.buffer));
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'f32le', '-ar', String(RATE), '-ac', String(C), '-i', tmp, '-c:a', 'libvorbis',
    '-q:a', String(q), '-map_metadata', '-1', '-fflags', '+bitexact', '-flags:a', '+bitexact', file]);
  const dec = execFileSync('ffmpeg', ['-v', 'error', '-i', file, '-f', 'f32le', '-ac', String(C), '-'], { maxBuffer: 1 << 30 });
  const d = new Float32Array(dec.buffer.slice(dec.byteOffset, dec.byteOffset + dec.length));
  return { frames: d.length / C, dec: Array.from({ length: C }, (_, c) => { const y = new Float32Array(d.length / C); for (let i = 0; i < y.length; i++) y[i] = d[i * C + c]; return y; }) };
}
// Pre-compressor levels span −27 dBFS (engine) to +10 dBFS (cheer; the web compressor tames it), so every file is
// stored peak-normalised to 0.9 and the runtime gets the web level back as gain_db (played as volume_db; Godot mixes
// in float before Master's compressor). Normalising also keeps quiet loops well above the 16-bit/QOA noise floor.
function headroom(chs) {
  const pk = stats(chs).peak; if (!(pk > 0)) return { chs, gain_db: 0 };
  const k = 0.9 / pk; return { chs: chs.map((y) => y.map((v) => v * k)), gain_db: +(-20 * Math.log10(k)).toFixed(3) };
}
function trimTail(chs) {
  let end = chs[0].length;
  while (end > 1 && chs.every((y) => Math.abs(y[end - 1]) < 1e-4)) end--;
  const n = Math.min(chs[0].length, end + S(0.01));
  return chs.map((y) => y.slice(0, n));
}
function importFile(file, loop, offset = 0) {
  const ext = path.extname(file);
  const body = ext === '.ogg'
    ? `[remap]\n\nimporter="oggvorbisstr"\ntype="AudioStreamOggVorbis"\n\n[params]\n\nloop=${loop}\nloop_offset=${offset}\nbpm=0\nbeat_count=0\nbar_beats=4\n`
    : `[remap]\n\nimporter="wav"\ntype="AudioStreamWAV"\n\n[params]\n\nforce/8_bit=false\nforce/mono=false\nforce/max_rate=false\nforce/max_rate_hz=44100\n` +
      `edit/trim=false\nedit/normalize=false\nedit/loop_mode=${loop ? 2 : 0}\nedit/loop_begin=0\nedit/loop_end=-1\ncompress/mode=2\n`;
  const p = path.join(OUT, `${file}.import`);
  // keep Godot's generated [remap]/[deps] (uid, dest paths) when the params already match
  if (fs.existsSync(p)) {
    const old = fs.readFileSync(p, 'utf8');
    const params = (s) => s.slice(s.indexOf('[params]')).trim();
    if (params(old) === params(body)) return;
  }
  fs.writeFileSync(p, body);
}

// ───────────────────────────── bake
fs.mkdirSync(OUT, { recursive: true });
const manPath = path.join(OUT, 'audio_bake.json');
const prev = fs.existsSync(manPath) ? JSON.parse(fs.readFileSync(manPath, 'utf8')) : {};
const man = {
  generator: 'tools/bake-audio.mjs', source: 'game/js/audio.js (web-frozen 753549a), module imported unmodified',
  tap: 'pre-compressor: bus gains (sfx 0.9 / amb 0.6 / music 0.8 x song gain) included, no compressor, no clipper',
  rate: RATE,
  master: { compressor: { threshold_db: -10, knee_db: 6, ratio: 6, attack_s: 0.003, release_s: 0.22 }, clip_ceiling: 0.93 },
  sfx: { ...(prev.sfx || {}) }, music: { ...(prev.music || {}) }, amb: { ...(prev.amb || {}) },
  engine: { ...(prev.engine || {}), model: { ...ENG, rpm_ref: +rpmRef.toFixed(5), v_ref: +vRef.toFixed(5) } },
};
let fails = 0;
const note = (ok, msg) => { if (!ok) fails++; console.log(`${ok ? 'ok   ' : 'FAIL '} ${msg}`); };
function writeOrCheck(fileName, bytes, chs, meta) {
  const file = path.join(OUT, fileName);
  if (!CHECK) { fs.writeFileSync(file, bytes); return; }
  if (!fs.existsSync(file)) { note(false, `${fileName} missing`); return; }
  if (fileName.endsWith('.wav')) {
    const old = fs.readFileSync(file); let maxd = 0, same = old.length === bytes.length;
    for (let i = 44; same && i < bytes.length; i += 2) maxd = Math.max(maxd, Math.abs(old.readInt16LE(i) - bytes.readInt16LE(i)));
    note(same && maxd <= 2, `check ${fileName} (max |Δ| ${maxd} LSB)`);
  } else {
    const o = meta.prev || {}; const s = meta.stats || stats(chs);
    note(Math.abs(s.rms - (o.rms || 0)) <= 0.01 * (o.rms || 1) && Math.abs(s.peak - (o.peak || 0)) <= 0.01 * (o.peak || 1) + 1e-3, `check ${fileName} rms ${s.rms} vs ${o.rms}`);
  }
}

for (const job of todo) {
  const t0 = Date.now();
  const chs = await render(job);
  if (job.kind === 'sfx' || job.kind === 'cheer' || job.kind === 'skill') {
    let y = trimTail(chs);
    let beat0 = 0;
    if (job.kind === 'cheer') { const from = S(0.06 - 0.04); y = y.map((c) => c.slice(from)); beat0 = 0.04; } // cheer t0 = ctx 0.06 s
    const st = stats(y); const hr = headroom(y); y = hr.chs;
    const skillRow = () => { const { seconds, ...row } = SKILL_SFX[job.name]; return { ...row, note: 'native-only skill SFX (bake-audio.mjs SKILL_SRC, docs/SKILLS.md 2-6)' }; };
    const base = job.kind === 'cheer' ? { g: 1, dur: 4.6, max: 1, gap: 1, stagger: 0, pri: 2 } : job.kind === 'skill' ? skillRow() : SFXT[job.name];
    const ent = man.sfx[job.name] && job.file !== job.name ? man.sfx[job.name] : { ...base, files: [] };
    if (job.file === job.name) ent.files = [];
    ent.files.push(`${job.file}.wav`);
    const sec = +(y[0].length / RATE).toFixed(4); // variants: longest take / loudest peak, one gain for all takes
    Object.assign(ent, ent.files.length > 1 ? { seconds: Math.max(ent.seconds, sec) } : { seconds: sec, channels: y.length, peak: st.peak, rms: st.rms, gain_db: hr.gain_db });
    if (ent.files.length > 1) { y = y.map((c) => c.map((v) => v * Math.pow(10, (hr.gain_db - ent.gain_db) / 20))); }
    writeOrCheck(`${job.file}.wav`, wav16(y), y, {});
    if (job.kind === 'cheer') Object.assign(ent, { beat0, bpm: RELEASE_BPM, note: 'cheerHorns(): 2x "대~한민국" + 짝짝 짝짝짝 + final 빠앙 on the release grid; release music enters 1 bar after beat0' });
    man.sfx[job.name] = ent;
    if (!CHECK) importFile(`${job.file}.wav`, false);
    console.log(`  ${job.file}.wav ${ent.seconds}s ch${y.length} peak ${st.peak} (${Date.now() - t0} ms)`);
    continue;
  }
  let cut, loopOffset = 0, q = 4, extra = {};
  if (job.kind === 'music') {
    const s = SONGS[job.name];
    const introLen = S(job.L0), N = S(job.P), A = S(job.s0 + job.L0 + job.P);
    cut = cutLoop(chs, { introFrom: S(job.s0), introLen, A, N, F: S(0.012) });
    loopOffset = +(introLen / RATE).toFixed(6);
    extra = { bpm: s.bpm, bars: s.bars, loop_bar: s.loopBar, loop_s: +(N / RATE).toFixed(4), gain: s.gain };
  } else if (job.kind === 'amb') {
    const N = S(job.N), F = S(job.F);
    let A = job.A != null ? S(job.A) : -1;
    if (A < 0) { // jam: boundaries where no distant honk is sounding (honk = full − bed with horn oscillators muted)
      const bed = await render({ ...job, mute: { osc: ['square', 'sawtooth'] } });
      const blk = S(0.01), nb = Math.floor(chs[0].length / blk), env = new Float32Array(nb);
      for (let b = 0; b < nb; b++) for (let c = 0; c < chs.length; c++) for (let i = b * blk; i < (b + 1) * blk; i++) {
        env[b] = Math.max(env[b], Math.abs(chs[c][i] - (bed[c] || bed[0])[i]));
      }
      const quiet = (s) => { for (let b = Math.floor((s - S(0.4)) / blk); b <= Math.ceil((s + S(0.1)) / blk); b++) if (!(env[b] < 1e-3)) return false; return true; };
      for (let s = S(3.5); s + N + S(0.2) < chs[0].length; s += blk) if (quiet(s) && quiet(s + N)) { A = s; break; }
      if (A < 0) throw new Error('bake-audio: no honk-free loop boundary in amb_jam');
    }
    cut = cutLoop(chs, { introFrom: 0, introLen: 0, A, N, F });
    q = 3; extra = { loop_s: +(N / RATE).toFixed(4), cut_at_s: +(A / RATE).toFixed(3), xfade_s: job.F };
  } else { // engine / road: exactly periodic
    const N = job.name === 'road' ? S(2.0) : S(ENG.loop_s), A = S(job.name === 'road' ? 4 : 2);
    cut = chs.map((x) => x.slice(A, A + N));
    const es = engState(job.v, job.th);
    extra = job.name === 'road' ? { v_ref: ENG.road[1], gain_ref: ENG.road[0] } : { th: job.th, f_ref: +es.f.toFixed(3), rpm_ref: +es.rpm.toFixed(5), lvl_ref: +es.lvl.toFixed(5) };
  }
  const seam = seamOf(cut, S(loopOffset));
  const st = stats(cut); const hr = headroom(cut); cut = hr.chs; extra.gain_db = hr.gain_db;
  const isOgg = job.kind === 'music' || job.kind === 'amb';
  const fileName = `${job.file}.${isOgg ? 'ogg' : 'wav'}`;
  const key = job.kind === 'engine' ? (job.name === 'road' ? 'road' : job.name.slice(4)) : job.name;
  const group = job.kind === 'engine' ? man.engine : job.kind === 'music' ? man.music : man.amb;
  let dseam = null, frames = cut[0].length;
  if (isOgg) {
    const outFile = CHECK ? path.join(TMP, fileName) : path.join(OUT, fileName);
    const r = ogg(cut, outFile, q);
    frames = r.frames; dseam = seamOf(r.dec, S(loopOffset));
    note(frames === cut[0].length, `${fileName} vorbis length ${frames} == ${cut[0].length} frames`);
    if (CHECK) writeOrCheck(fileName, null, cut, { stats: st, prev: (prev[job.kind === 'music' ? 'music' : 'amb'] || {})[key] });
  } else writeOrCheck(fileName, wav16(cut), cut, {});
  note(seam.ok, `${fileName} loop seam ${seam.err} (signal p99.9 Δ² ${seam.p999})${dseam ? `, decoded ${dseam.err}` : ''}`);
  group[key] = { file: fileName, seconds: +(frames / RATE).toFixed(4), channels: cut.length, loop: true, loop_offset: loopOffset,
    peak: st.peak, rms: st.rms, seam: seam.err, seam_ref: seam.p999, ...(dseam ? { seam_decoded: dseam.err } : {}), ...extra };
  if (!CHECK) importFile(fileName, true, loopOffset);
  console.log(`  ${fileName} ${group[key].seconds}s ch${cut.length} peak ${st.peak} (${Date.now() - t0} ms)`);
}
await browser.close();
fs.rmSync(TMP, { recursive: true, force: true });

let total = 0;
for (const f of fs.readdirSync(OUT)) if (/\.(wav|ogg)$/.test(f)) total += fs.statSync(path.join(OUT, f)).size;
man.total_bytes = total;
note(total <= 6 * 1024 * 1024, `total audio ${(total / 1048576).toFixed(2)} MB ≤ 6 MB`);
if (!CHECK) {
  const order = (o) => Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]]));
  man.sfx = order(man.sfx); man.music = order(man.music); man.amb = order(man.amb);
  fs.writeFileSync(manPath, JSON.stringify(man, null, 1) + '\n');
  const old = path.join(OUT, 'sfx_bake.json'); if (fs.existsSync(old)) fs.rmSync(old); // superseded by audio_bake.json
}
process.exit(fails ? 1 : 0);
