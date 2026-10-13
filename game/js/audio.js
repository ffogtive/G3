// game/js/audio.js — 1차선 참교육 사운드 (WebAudio 순수 합성, 외부 파일 0개)
// 가설: 외부 파일 없이 합성만으로 경적·펑크·폭발·"대~한민국" 경적 합주·뽕짝 BGM 을 만들면 해방의 쾌감이 2배가 된다.
//
// 신호 그래프
//   sfx bus ──────────────────┐
//   ambience bus ─────────────┼─► compressor ─► master gain ─► safety clipper ─► mute gain ─► destination
//   music bus ─► duck gain ───┘        (clipper = WaveShaper 소프트 니, 출력 |x| ≤ 0.93 보장)
//
// 계약 (docs/ARCHITECTURE.md § audio.js)
//  - init() 은 모든 pointerdown/keydown 마다 불린다 → 멱등·저렴. init({ context }) 로 OfflineAudioContext 바인딩(테스트용).
//  - 모든 메서드는 init 전/음소거 중 '무음 no-op' 이며 절대 throw 하지 않는다.
//    단, init 전에 요청된 setMuted / startMusic / startAmbience 는 '원하는 상태'로 기억했다가 init 때 반영한다
//    (main.js 는 사용자 제스처 전에 startMusic('menu') 를 부르므로).
//  - 음소거 = mute gain 0 + (실시간 컨텍스트면) suspend → CPU 0, 해제 시 resume. 음악/환경음 스케줄은 그대로 이어짐.
//  - play() 는 이름별 보이스 제한(최대 동시 수 + 최소 재트리거 간격). tack(7/s)·hit(4/s) 연사에도 피로/클리핑 없게.
//  - setEngine() 은 매 프레임 호출 → 노드 생성 없이 파라미터만 setTargetAtTime (20Hz 로 솎음).
//  - 음악은 lookahead 스케줄러(setInterval 25ms + ctx.currentTime). 오프라인 컨텍스트면 렌더 길이만큼 한 번에 예약.

const LOOKAHEAD = 0.14;      // 초. 스케줄러 선행 예약 구간
const TICK_MS = 25;
const MAX_LIVE = 40;         // 전역 동시 SFX 보이스 상한 (우선순위 낮은 것부터 버림)
const RELEASE_BPM = 130;     // 해방 BGM 템포 = 경적 합주 그리드

const noop = () => {};
const perfNow = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
const rand = (a, b) => a + Math.random() * (b - a);
const pick = (arr) => arr[(Math.random() * arr.length) | 0];
const clamp = (x, a, b) => (x < a ? a : x > b ? b : x);
const num = (x, d) => (typeof x === 'number' && isFinite(x) ? x : d);
const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);
const PC = { C: 0, 'C#': 1, Db: 1, D: 2, 'D#': 3, Eb: 3, E: 4, F: 5, 'F#': 6, Gb: 6, G: 7, 'G#': 8, Ab: 8, A: 9, 'A#': 10, Bb: 10, B: 11 };
function nm(s) { // 'C#5' → MIDI
  const m = /^([A-G][#b]?)(-?\d)$/.exec(s);
  return m ? 12 * (+m[2] + 1) + PC[m[1]] : 60;
}
const nf = (s) => mtof(nm(s));

// ───────────────────────────── 상태
const S = {
  own: false, offline: false, n: null, noClip: false,
  muted: false, hidden: false,
  waves: null, bufs: null, curves: null,
  lim: Object.create(null), live: [],
  eng: null, engT: -1e9, engCall: -1e9, engIdle: false,
  amb: null, wantAmb: null,
  song: null, dying: [], wantMusic: null,
  timer: 0, cheerT0: -1e9, resumeAt: -1e9, muteTok: 0, visHooked: false,
  analyser: null,
};
let C = null; // 현재 AudioContext (또는 OfflineAudioContext)

// ───────────────────────────── 노드 헬퍼
function G(v = 1, dest) { const g = C.createGain(); g.gain.value = v; if (dest) g.connect(dest); return g; }
function F(type, freq, Q = 0.7, dest) {
  const f = C.createBiquadFilter(); f.type = type; f.frequency.value = freq; f.Q.value = Q;
  if (dest) f.connect(dest); return f;
}
function osc(type, f, t0, t1, dest, det = 0) {
  const o = C.createOscillator();
  const w = S.waves && S.waves[type];
  if (w) o.setPeriodicWave(w); else o.type = type;
  o.frequency.setValueAtTime(f, t0);
  if (det) o.detune.setValueAtTime(det, t0);
  if (dest) o.connect(dest);
  o.start(t0); o.stop(t1);
  return o;
}
function noise(t0, t1, dest, opt) {
  const b = (opt && opt.buf) || S.bufs.white;
  const rate = (opt && opt.rate) || 1;
  const s = C.createBufferSource(); s.buffer = b; s.playbackRate.value = rate;
  s.connect(dest);
  const span = (t1 - t0) * rate;
  let off = 0;
  if (opt && typeof opt.off === 'number') off = opt.off;
  else if (b.duration > span + 0.05) off = Math.random() * (b.duration - span - 0.05);
  if (span > b.duration - off) s.loop = true;
  s.start(t0, off); s.stop(t1);
  return s;
}
function loopSrc(buf, dest, t, rate = 1) {
  const s = C.createBufferSource(); s.buffer = buf; s.loop = true; s.playbackRate.value = rate;
  s.connect(dest); s.start(t, Math.random() * buf.duration * 0.9); return s;
}
function panNode(p, dest) {
  if (!p || !C.createStereoPanner) return dest;
  const s = C.createStereoPanner(); s.pan.value = clamp(p, -1, 1); s.connect(dest); return s;
}
function curve(drive) {
  let c = S.curves.get(drive); if (c) return c;
  c = new Float32Array(1024); const k = Math.tanh(drive);
  for (let i = 0; i < 1024; i++) { const x = i / 511.5 - 1; c[i] = Math.tanh(x * drive) / k; }
  S.curves.set(drive, c); return c;
}
function shaper(drive, dest) { const w = C.createWaveShaper(); w.curve = curve(drive); if (dest) w.connect(dest); return w; }
// 퍼커시브 엔벨로프: 0 → peak (a초) → 지수 감쇠 (d초 뒤 ≈ −40 dB)
function perc(prm, t, peak, a, d) {
  prm.setValueAtTime(0, t); prm.linearRampToValueAtTime(peak, t + a); prm.setTargetAtTime(0, t + a, d / 4.6);
}

// ───────────────────────────── 버퍼/파형 (컨텍스트별 1회)
function makeBuffers() {
  const sr = C.sampleRate;
  const white = C.createBuffer(1, Math.floor(sr * 2), sr);
  { const d = white.getChannelData(0); for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1; }
  // 브라운 노이즈 (루프 이음매 없도록 선형 드리프트 제거)
  const brown = C.createBuffer(1, Math.floor(sr * 4), sr);
  {
    const d = brown.getChannelData(0); let b = 0;
    for (let i = 0; i < d.length; i++) { b = (b + 0.02 * (Math.random() * 2 - 1)) / 1.02; d[i] = b; }
    const n = d.length, drift = d[n - 1] - d[0]; let mx = 1e-6;
    for (let i = 0; i < n; i++) { d[i] -= drift * (i / (n - 1)); mx = Math.max(mx, Math.abs(d[i])); }
    for (let i = 0; i < n; i++) d[i] = (d[i] / mx) * 0.9;
  }
  // 크래클: 시간이 갈수록 성겨지는 임펄스 버스트 (폭발 파편)
  const crackle = C.createBuffer(1, Math.floor(sr * 2.5), sr);
  {
    const d = crackle.getChannelData(0); const n = d.length;
    for (let i = 0; i < n; i++) {
      const x = i / n; const dens = 0.0035 * Math.pow(1 - x, 1.6) + 0.0002;
      if (Math.random() < dens) {
        const a = (Math.random() * 0.7 + 0.3) * (Math.random() < 0.5 ? -1 : 1) * (1 - x * 0.6);
        const L = 4 + ((Math.random() * 30) | 0);
        for (let k = 0; k < L && i + k < n; k++) d[i + k] += a * Math.exp(-k / (L * 0.35)) * (Math.random() * 0.6 + 0.4);
      }
    }
  }
  return { white, brown, crackle };
}
function pulseWave(duty) {
  const n = 40; const re = new Float32Array(n), im = new Float32Array(n);
  for (let k = 1; k < n; k++) re[k] = (2 / (k * Math.PI)) * Math.sin(k * Math.PI * duty);
  return C.createPeriodicWave(re, im);
}
function clipCurve() {
  // |x| ≤ 0.8 선형, 이후 소프트 니로 0.93 에 수렴 (입력이 ±1 을 넘어도 끝값으로 클램프 → 피크 < 1.0 보장)
  const N = 4096, c = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    const x = (i / (N - 1)) * 2 - 1, ax = Math.abs(x);
    const y = ax <= 0.8 ? ax : 0.8 + 0.13 * Math.tanh((ax - 0.8) / 0.13);
    c[i] = Math.sign(x) * y;
  }
  return c;
}

// ───────────────────────────── 컨텍스트 바인딩
function teardown() {
  if (S.timer) { clearInterval(S.timer); S.timer = 0; }
  if (!C) return;
  try { if (S.eng) S.eng.srcs.forEach((s) => { try { s.stop(); } catch (e) { /* */ } }); } catch (e) { /* */ }
  try { if (S.amb) S.amb.srcs.forEach((s) => { try { s.stop(); } catch (e) { /* */ } }); } catch (e) { /* */ }
  try { S.n && S.n.mute.disconnect(); } catch (e) { /* */ }
  if (S.own && C.close && C.state !== 'closed') { try { C.close().catch(noop); } catch (e) { /* */ } }
  C = null; S.n = null; S.eng = null; S.amb = null; S.song = null; S.dying = []; S.analyser = null;
}

function bind(ctx, opts) {
  teardown();
  C = ctx;
  S.offline = typeof ctx.startRendering === 'function';
  S.noClip = !!(opts && opts.noLimiter);
  S.curves = new Map();
  const n = {};
  n.mute = G(S.muted ? 0 : 1, ctx.destination);
  n.clip = C.createWaveShaper(); n.clip.curve = clipCurve(); n.clip.connect(n.mute);
  n.master = G(0.9, S.noClip ? n.mute : n.clip);
  n.comp = C.createDynamicsCompressor();
  n.comp.threshold.value = -12; n.comp.knee.value = 8; n.comp.ratio.value = 6;
  n.comp.attack.value = 0.003; n.comp.release.value = 0.22;
  n.comp.connect(n.master);
  n.sfx = G(0.9, n.comp);
  n.amb = G(0.6, n.comp);
  n.duck = G(1, n.comp);
  n.music = G(0.7, n.duck);
  S.n = n;
  S.waves = { p25: pulseWave(0.25), p12: pulseWave(0.125) };
  S.bufs = makeBuffers();
  S.lim = Object.create(null); S.live = [];
  S.eng = null; S.engIdle = false;
  S.cheerT0 = -1e9;
  if (S.wantMusic) startSong(S.wantMusic);
  if (S.wantAmb) startAmb(S.wantAmb);
  if (!S.offline) {
    S.timer = setInterval(() => { try { tick(); } catch (e) { /* */ } }, TICK_MS);
    if (S.muted && ctx.state === 'running') ctx.suspend().catch(noop);
  }
  tick();
}

function hookVisibility() {
  if (S.visHooked || typeof document === 'undefined' || !document.addEventListener) return;
  S.visHooked = true;
  document.addEventListener('visibilitychange', () => {
    try {
      S.hidden = !!document.hidden;
      if (!C || S.offline) return;
      if (S.hidden) { if (C.state === 'running') C.suspend().catch(noop); }
      else if (!S.muted) { S.resumeAt = perfNow(); C.resume().catch(noop); }
    } catch (e) { /* */ }
  });
}

function ready() {
  if (!C || !S.n || S.muted) return false;
  if (S.offline) return true;
  if (S.hidden || C.state === 'closed') return false;
  return C.state === 'running' || perfNow() - S.resumeAt < 600;
}

// ───────────────────────────── 보이스 제한
function admit(name, t, m) {
  let L = S.lim[name];
  if (!L) L = S.lim[name] = { last: -1e9, ends: [] };
  let at = t;
  if (Math.abs(at - L.last) < m.gap) {
    if (m.stagger && L.last + m.stagger - t < 0.4) at = L.last + m.stagger; // 펑펑펑: 겹치지 말고 연달아
    else return -1;
  }
  L.ends = L.ends.filter((e) => e > at); // 이 보이스 시작 시점에 아직 울리는 것만 센다
  if (L.ends.length >= m.max) return -1;
  S.live = S.live.filter((e) => e > at);
  if (S.live.length >= MAX_LIVE && (m.pri || 1) < 2) return -1;
  L.last = at; L.ends.push(at + m.dur); S.live.push(at + m.dur);
  return at;
}

// ───────────────────────────── 경적
// fs: 주파수 배열 (보통 2톤). 각 톤마다 살짝 디튠된 오실레이터 2개 → 로우패스 → 피킹(혼 공명) → d
function hornTone(t, dur, fs, d, o = {}) {
  const types = o.types || ['square', 'sawtooth'];
  const det = o.det != null ? o.det : 6, scoop = o.scoop != null ? o.scoop : 0.035, scoopT = o.scoopT || 0.03;
  const mix = G(0); const lp = F('lowpass', o.cut || 2300, 0.9); const pk = F('peaking', o.body || 1150, 1.3);
  pk.gain.value = o.bodyGain != null ? o.bodyGain : 6;
  mix.connect(lp); lp.connect(pk); pk.connect(d);
  const end = t + dur + 0.15;
  fs.forEach((f, i) => {
    for (const dt of [-det, det]) {
      const x = C.createOscillator(); x.type = types[i % types.length];
      x.detune.value = dt + rand(-2, 2);
      x.frequency.setValueAtTime(f * (1 - scoop), t); x.frequency.exponentialRampToValueAtTime(f, t + scoopT);
      x.connect(mix); x.start(t); x.stop(end);
    }
  });
  const lvl = (1.6 / (fs.length * 2)) * (o.lvl || 1), a = 0.008, hold = t + Math.max(a + 0.005, dur);
  const g = mix.gain;
  g.setValueAtTime(0, t); g.linearRampToValueAtTime(lvl, t + a); g.setValueAtTime(lvl, hold); g.setTargetAtTime(0, hold, 0.018);
  return end;
}
function sfxHornTruck(t, p, d) {
  const end = hornTone(t, 0.85, [220 * p, 277 * p, 330 * p], d, { types: ['sawtooth'], cut: 1500, det: 9, scoop: 0.07, scoopT: 0.09, body: 640, bodyGain: 8, lvl: 1.15 });
  const g = G(0, d); noise(t, t + 0.25, F('bandpass', 1900, 0.8, g)); perc(g.gain, t, 0.35, 0.005, 0.18); // 에어 밸브 '취익'
  return end;
}
function sfxHornAngry(t, p, d) {
  let e = t;
  for (const [o, l] of [[0, 0.085], [0.135, 0.085], [0.27, 0.19]]) e = hornTone(t + o, l, [440 * p, 550 * p], d, { scoop: 0.05, lvl: 1.05 });
  return e;
}

// ───────────────────────────── 전투
function sfxTack(t, p, d) {
  // 압정 발사 '틱-퓻': 짧은 고역 클릭 + 하강 처프. 7/s 연사에도 귀가 안 피곤하게 짧고 둥글게.
  const g = G(0, d); noise(t, t + 0.03, F('bandpass', 3800 * p, 1.2, g)); perc(g.gain, t, 0.9, 0.001, 0.02);
  const g2 = G(0, d); const o = osc('triangle', 1900 * p, t, t + 0.07, F('lowpass', 4500, 0.7, g2));
  o.frequency.exponentialRampToValueAtTime(780 * p, t + 0.045); perc(g2.gain, t, 0.5, 0.002, 0.045);
  return t + 0.07;
}
function sfxHit(t, p, d) {
  // 차체 '팅': 비조화 금속 배음 + 짧은 노이즈 + 작은 '턱'
  const j = rand(0.97, 1.03) * p;
  for (const [f, a, dd] of [[2480, 0.32, 0.09], [3710, 0.2, 0.06], [1330, 0.16, 0.05]]) {
    const g = G(0, d); osc('sine', f * j, t, t + dd * 1.6 + 0.01, g); perc(g.gain, t, a, 0.001, dd);
  }
  const gn = G(0, d); noise(t, t + 0.025, F('highpass', 2500, 0.7, gn)); perc(gn.gain, t, 0.35, 0.001, 0.015);
  const gt = G(0, d); const o = osc('sine', 210 * p, t, t + 0.08, gt); o.frequency.exponentialRampToValueAtTime(90, t + 0.05); perc(gt.gain, t, 0.35, 0.002, 0.05);
  return t + 0.16;
}
function sfxCrit(t, p, d) {
  // 크리티컬 '캉!': 굵은 금속 배음 + 반짝 상승음 + 펀치
  for (const [f, a, dd] of [[1180, 0.3, 0.32], [1837, 0.25, 0.26], [2710, 0.2, 0.2], [3490, 0.14, 0.14], [4930, 0.08, 0.1]]) {
    const g = G(0, d); osc('sine', f * p, t, t + dd * 1.6 + 0.01, g); perc(g.gain, t, a, 0.001, dd);
  }
  const gn = G(0, d); noise(t, t + 0.05, F('bandpass', 3000, 0.8, gn)); perc(gn.gain, t, 1.2, 0.001, 0.035);
  const gt = G(0, d); const o = osc('sine', 170 * p, t, t + 0.2, gt); o.frequency.exponentialRampToValueAtTime(55, t + 0.1); perc(gt.gain, t, 0.6, 0.002, 0.14);
  const gb = G(0, d); const ob = osc('sine', 1600 * p, t + 0.03, t + 0.35, gb); ob.frequency.exponentialRampToValueAtTime(3200 * p, t + 0.12); perc(gb.gain, t + 0.03, 0.16, 0.003, 0.25);
  return t + 0.5;
}
function sfxPop(t, p, d) {
  // 타이어 펑크: '뻥!' 광대역 버스트 + '쿵' 저역 + '쉬이익~' 바람 빠지는 꼬리 + 고무 펄럭
  const g1 = G(0, d); noise(t, t + 0.08, F('lowpass', 7000, 0.5, g1)); perc(g1.gain, t, 1.0, 0.0015, 0.06);
  const g2 = G(0, d); const o = osc('sine', 120 * p, t, t + 0.32, g2); o.frequency.exponentialRampToValueAtTime(38 * p, t + 0.18); perc(g2.gain, t, 0.9, 0.003, 0.22);
  const g3 = G(0, d); const bp = F('bandpass', 5200 * p, 0.6, g3); const hp = F('highpass', 2200, 0.5, bp);
  noise(t + 0.015, t + 0.95, hp);
  bp.frequency.setValueAtTime(5200 * p, t); bp.frequency.exponentialRampToValueAtTime(2400 * p, t + 0.9);
  g3.gain.setValueAtTime(0, t); g3.gain.linearRampToValueAtTime(0.55, t + 0.04); g3.gain.setTargetAtTime(0, t + 0.06, 0.22);
  for (let i = 0; i < 3; i++) {
    const tt = t + 0.08 + i * rand(0.06, 0.085); const gf = G(0, d);
    noise(tt, tt + 0.05, F('bandpass', 320 * p, 1.5, gf)); perc(gf.gain, tt, 0.9 * (1 - i * 0.28), 0.002, 0.03);
  }
  return t + 1.0;
}
function boom(t, p, d, k = 1) {
  const dur = 1.6 * k;
  const g0 = G(0, d); noise(t, t + 0.06, F('highpass', 900, 0.6, g0)); perc(g0.gain, t, 0.75, 0.001, 0.05); // 크랙
  const g1 = G(0, d); const lp = F('lowpass', 3000 * p, 0.7, g1); noise(t, t + dur, shaper(3, lp)); // 몸통: 왜곡 노이즈 → 하강 로우패스
  lp.frequency.setValueAtTime(3000 * p, t); lp.frequency.exponentialRampToValueAtTime(140 * p, t + 1.1 * k);
  g1.gain.setValueAtTime(0, t); g1.gain.linearRampToValueAtTime(0.7, t + 0.008); g1.gain.setTargetAtTime(0, t + 0.06, 0.33 * k);
  const g2 = G(0, d); const o = osc('sine', 95 * p, t, t + dur, g2); o.frequency.exponentialRampToValueAtTime(30 * p, t + 0.8 * k); // 서브 드롭
  g2.gain.setValueAtTime(0, t); g2.gain.linearRampToValueAtTime(0.9, t + 0.006); g2.gain.setTargetAtTime(0, t + 0.05, 0.3 * k);
  const g3 = G(0, d); noise(t + 0.05, t + dur, F('bandpass', 2400, 0.7, g3), { buf: S.bufs.crackle, off: 0 }); // 파편 크래클
  g3.gain.setValueAtTime(0, t); g3.gain.setValueAtTime(1.1, t + 0.05); g3.gain.setTargetAtTime(0, t + 0.2, 0.4 * k);
  return t + dur;
}
function sfxSuperHit(t, p, d) {
  // 분노 미사일 명중 / 킬: 거대한 충격 (슬램 + 금속 크런치 + 폭발 + 초저역 꼬리 + 영화식 이명)
  boom(t, p * 0.9, d, 1.5);
  const gs = G(0, d); const o = osc('sine', 180 * p, t, t + 0.4, gs); o.frequency.exponentialRampToValueAtTime(38, t + 0.16); perc(gs.gain, t, 1.0, 0.002, 0.25);
  const gc = G(0, d); noise(t, t + 0.4, shaper(8, F('bandpass', 950 * p, 1.4, gc))); perc(gc.gain, t, 0.55, 0.002, 0.3);
  const gb = G(0, d); const ob = osc('sine', 62 * p, t, t + 2.4, gb); ob.frequency.exponentialRampToValueAtTime(24, t + 1.8);
  gb.gain.setValueAtTime(0, t); gb.gain.linearRampToValueAtTime(0.7, t + 0.02); gb.gain.setTargetAtTime(0, t + 0.1, 0.55);
  const gr = G(0, d); osc('sine', 3150, t + 0.05, t + 2.2, gr);
  gr.gain.setValueAtTime(0, t); gr.gain.linearRampToValueAtTime(0.035, t + 0.15); gr.gain.setTargetAtTime(0, t + 0.4, 0.45);
  return t + 2.6;
}
function sfxSuper(t, p, d) {
  // 분노 미사일 발사: 점화 '퍽' + 상승 분사 노이즈 + 휘슬
  const gi = G(0, d); noise(t, t + 0.1, F('lowpass', 2200, 0.6, gi)); perc(gi.gain, t, 0.7, 0.002, 0.08);
  const gt = G(0, d); const ot = osc('sine', 150 * p, t, t + 0.25, gt); ot.frequency.exponentialRampToValueAtTime(50, t + 0.14); perc(gt.gain, t, 0.6, 0.003, 0.15);
  const gr = G(0, d); const bp = F('bandpass', 300 * p, 1.0, gr); noise(t, t + 1.3, bp);
  bp.frequency.setValueAtTime(300 * p, t); bp.frequency.exponentialRampToValueAtTime(2600 * p, t + 0.9);
  gr.gain.setValueAtTime(0, t); gr.gain.linearRampToValueAtTime(1.6, t + 0.12); gr.gain.setValueAtTime(1.6, t + 0.55); gr.gain.setTargetAtTime(0, t + 0.55, 0.18);
  const gw = G(0, d); const ow = osc('sine', 520 * p, t + 0.03, t + 1.2, gw); ow.frequency.exponentialRampToValueAtTime(2300 * p, t + 1.0);
  gw.gain.setValueAtTime(0, t + 0.03); gw.gain.linearRampToValueAtTime(0.16, t + 0.25); gw.gain.setTargetAtTime(0, t + 0.75, 0.12);
  return t + 1.35;
}
function sfxLaunch(t, p, d) {
  // 하늘로 '피유우우웅~' 슬라이드 휘슬 (코믹)
  const dur = 1.15;
  const g = G(0, d); const o = osc('sine', 330 * p, t, t + dur + 0.05, g);
  o.frequency.exponentialRampToValueAtTime(560 * p, t + 0.25); o.frequency.exponentialRampToValueAtTime(1750 * p, t + dur);
  const l = G(28); osc('sine', 7, t, t + dur + 0.05, l); l.connect(o.detune);
  const gb = G(0, d); const bp = F('bandpass', 330 * p, 6, gb); noise(t, t + dur, bp); // 숨결
  bp.frequency.setValueAtTime(330 * p, t); bp.frequency.exponentialRampToValueAtTime(560 * p, t + 0.25); bp.frequency.exponentialRampToValueAtTime(1750 * p, t + dur);
  for (const [gg, a] of [[g, 0.5], [gb, 0.35]]) {
    gg.gain.setValueAtTime(0, t); gg.gain.linearRampToValueAtTime(a, t + 0.04); gg.gain.linearRampToValueAtTime(a * 0.6, t + 0.8);
    gg.gain.setTargetAtTime(0, t + dur - 0.12, 0.05);
  }
  return t + dur + 0.05;
}
function bell(t, f, a, dec, d) {
  const ny = C.sampleRate * 0.45;
  for (const [m, aa, dd] of [[1, 1, 1], [2.76, 0.35, 0.5], [5.4, 0.12, 0.25]]) {
    if (f * m > ny) continue;
    const g = G(0, d); osc('sine', f * m, t, t + dec * dd * 1.6 + 0.02, g); perc(g.gain, t, a * aa, 0.002, dec * dd);
  }
}
function sfxTwinkle(t, p, d) {
  // 반짝★ '팅~': 사인 벨 아르페지오 + 고역 쉬머
  [1568, 2093, 2637, 3136, 4186].forEach((f, i) => bell(t + i * 0.055, f * p, 0.2 * (1 - i * 0.1), 0.8 - i * 0.06, panNode(i % 2 ? 0.25 : -0.25, d)));
  const g = G(0, d); noise(t, t + 0.95, F('highpass', 6500, 0.7, g));
  const lg = G(0); osc('sine', 19, t, t + 0.95, lg); lg.connect(g.gain);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.09, t + 0.1); g.gain.setTargetAtTime(0, t + 0.2, 0.2);
  lg.gain.setValueAtTime(0, t); lg.gain.linearRampToValueAtTime(0.08, t + 0.1); lg.gain.setTargetAtTime(0, t + 0.2, 0.2);
  return t + 1.2;
}
function brakeTone(t, p, d, dur, lvl) {
  // 타이어 비명: 좁은 대역 톱니 2개 + 빠른 FM 떨림 + 노이즈 거칠기
  const g = G(0, d); const bp = F('bandpass', 1500 * p, 6, g);
  const fm = G(60 * p); osc('sine', 31, t, t + dur + 0.1, fm);
  const fm2 = G(30 * p); osc('triangle', 8.5, t, t + dur + 0.1, fm2);
  for (const [f, ty, a] of [[1400, 'sawtooth', 1], [1412, 'sawtooth', 0.8], [2810, 'square', 0.25]]) {
    const o = osc(ty, f * p * 1.03, t, t + dur + 0.1, G(a * 0.5, bp));
    o.frequency.linearRampToValueAtTime(f * p * 0.86, t + dur);
    fm.connect(o.frequency); fm2.connect(o.frequency);
  }
  const gn = G(0, d); noise(t, t + dur + 0.1, F('bandpass', 2900 * p, 2.5, gn));
  for (const [gg, a] of [[g, 1.6 * lvl], [gn, 0.6 * lvl]]) {
    gg.gain.setValueAtTime(0, t); gg.gain.linearRampToValueAtTime(a, t + 0.03); gg.gain.linearRampToValueAtTime(a * 0.75, t + dur * 0.7);
    gg.gain.setTargetAtTime(0, t + dur - 0.08, 0.05);
  }
  return t + dur + 0.1;
}
function sfxBump(t, p, d) {
  // 추돌 '쿵' + 플라스틱 덜컹
  const g = G(0, d); const o = osc('sine', 120 * p, t, t + 0.3, g); o.frequency.exponentialRampToValueAtTime(45 * p, t + 0.14); perc(g.gain, t, 0.95, 0.003, 0.2);
  const gn = G(0, d); noise(t, t + 0.12, F('lowpass', 420, 0.7, gn)); perc(gn.gain, t, 1.4, 0.002, 0.08);
  let tt = t + 0.02;
  for (let i = 0; i < 5; i++) {
    tt += rand(0.016, 0.034); const gr = G(0, d);
    noise(tt, tt + 0.03, F('bandpass', rand(1400, 3200) * p, 4, gr)); perc(gr.gain, tt, 2.2 * (1 - i * 0.17), 0.001, 0.014);
  }
  return tt + 0.06;
}
function sfxLane(t, p, d) {
  // 차선 변경 '슉' + 깜빡이 '틱'
  const g = G(0, d); const bp = F('bandpass', 600 * p, 1.3, g); noise(t, t + 0.2, bp);
  bp.frequency.setValueAtTime(600 * p, t); bp.frequency.exponentialRampToValueAtTime(2600 * p, t + 0.15);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(1.6, t + 0.06); g.gain.setTargetAtTime(0, t + 0.07, 0.035);
  const gk = G(0, d); noise(t, t + 0.012, F('bandpass', 3000, 3, gk)); perc(gk.gain, t, 1.4, 0.0005, 0.008);
  return t + 0.22;
}
function sfxWhoosh(t, p, d) {
  const dur = 0.5 / Math.sqrt(p);
  const g = G(0, d); const bp = F('bandpass', 350 * p, 0.9, g); noise(t, t + dur + 0.02, bp);
  bp.frequency.setValueAtTime(350 * p, t); bp.frequency.exponentialRampToValueAtTime(1900 * p, t + dur * 0.55); bp.frequency.exponentialRampToValueAtTime(520 * p, t + dur);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(1.6, t + dur * 0.5); g.gain.linearRampToValueAtTime(0, t + dur);
  return t + dur + 0.03;
}
function blip(t, f, len, a, d, wave = 'p25') {
  const g = G(0, d); osc(wave, f, t, t + len + 0.1, g);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(a, t + 0.003);
  g.gain.setTargetAtTime(a * 0.6, t + 0.003, 0.03); g.gain.setTargetAtTime(0, t + len, 0.015);
}
function sfxUi(t, p, d) {
  const g = G(0, d); const o = osc('p25', 1046 * p, t, t + 0.08, g); o.frequency.setValueAtTime(1318 * p, t + 0.025);
  perc(g.gain, t, 0.3, 0.002, 0.05); return t + 0.09;
}
function sfxUiConfirm(t, p, d) { blip(t, 784 * p, 0.06, 0.28, d); blip(t + 0.065, 1175 * p, 0.14, 0.3, d); return t + 0.3; }
function sfxRage(t, p, d) {
  // 분노 충전: 상승 아르페지오 + '부우웅' 스윕 + 반짝
  [60, 64, 67, 72, 76, 79, 84].forEach((m, i) => blip(t + i * 0.045, mtof(m) * p, 0.08, 0.2, d));
  const g = G(0, d); const lp = F('lowpass', 400, 4, g); const o = osc('sawtooth', 110 * p, t, t + 0.55, lp);
  o.frequency.exponentialRampToValueAtTime(880 * p, t + 0.4);
  lp.frequency.setValueAtTime(400, t); lp.frequency.exponentialRampToValueAtTime(4200, t + 0.4);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.2, t + 0.3); g.gain.setTargetAtTime(0, t + 0.4, 0.04);
  bell(t + 0.33, 2093 * p, 0.12, 0.5, d); bell(t + 0.36, 3136 * p, 0.08, 0.4, d);
  return t + 0.9;
}
function sfxWarn(t, p, d) {
  // 경고 '삐뽀삐뽀' 2톤
  [1040, 780, 1040, 780].forEach((f, i) => {
    const tt = t + i * 0.125; const g = G(0, d); osc('square', f * p, tt, tt + 0.13, F('lowpass', 3200, 0.7, g));
    g.gain.setValueAtTime(0, tt); g.gain.linearRampToValueAtTime(0.2, tt + 0.004); g.gain.setValueAtTime(0.2, tt + 0.1); g.gain.linearRampToValueAtTime(0, tt + 0.115);
  });
  return t + 0.52;
}
function sfxThrow(t, p, d) {
  // 투척 '휙' + 작은 '흡'
  const g = G(0, d); const bp = F('bandpass', 800 * p, 1.1, g); noise(t, t + 0.24, bp);
  bp.frequency.setValueAtTime(800 * p, t); bp.frequency.exponentialRampToValueAtTime(2800 * p, t + 0.18);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(1.4, t + 0.08); g.gain.linearRampToValueAtTime(0, t + 0.22);
  const g2 = G(0, d); const o = osc('triangle', 260 * p, t, t + 0.12, g2); o.frequency.exponentialRampToValueAtTime(620 * p, t + 0.08); perc(g2.gain, t, 0.2, 0.004, 0.07);
  return t + 0.26;
}
function sfxSplat(t, p, d) {
  // 수박/커피 '철퍽': 왜곡 노이즈 + 급하강 로우패스 + '뿌직' 저역 + 물방울
  const g = G(0, d); const lp = F('lowpass', 4000 * p, 1.2, g); noise(t, t + 0.35, shaper(2.5, lp));
  lp.frequency.setValueAtTime(4000 * p, t); lp.frequency.exponentialRampToValueAtTime(260 * p, t + 0.16);
  perc(g.gain, t, 0.85, 0.002, 0.26);
  const gb = G(0, d); const o = osc('sine', 300 * p, t, t + 0.2, gb); o.frequency.exponentialRampToValueAtTime(62 * p, t + 0.13); perc(gb.gain, t, 0.7, 0.003, 0.16);
  for (let i = 0; i < 3; i++) {
    const tt = t + rand(0.07, 0.26), f = rand(700, 1400) * p; const gd = G(0, d);
    const od = osc('sine', f, tt, tt + 0.05, gd); od.frequency.exponentialRampToValueAtTime(f * 1.7, tt + 0.03); perc(gd.gain, tt, 0.14, 0.002, 0.03);
  }
  return t + 0.42;
}
function sfxStar(t, p, d) {
  // 코인 '띠링': B5 → E6
  blip(t, 988 * p, 0.07, 0.26, d);
  const g = G(0, d); osc('p25', 1319 * p, t + 0.07, t + 0.6, g);
  g.gain.setValueAtTime(0, t + 0.07); g.gain.linearRampToValueAtTime(0.26, t + 0.073); g.gain.setTargetAtTime(0, t + 0.08, 0.11);
  bell(t + 0.07, 2638 * p, 0.06, 0.4, d);
  return t + 0.65;
}
function sfxClear(t, p, d) {
  // 스테이지 클리어 팡파레: 솔도미솔~ 미솔 도~~
  const q = 0.1;
  for (const [n, s, l] of [['G4', 0, 1], ['C5', 1, 1], ['E5', 2, 1], ['G5', 3, 2], ['E5', 5, 1], ['G5', 6, 1], ['C6', 7, 7]]) {
    mNote(d, t + s * q, l * q, { wave: 'p25', f: nf(n) * p, v: 0.24, gate: l > 1 ? 0.95 : 0.8, vib: l > 3 ? 22 : 0, rel: l > 3 ? 0.18 : 0.04 });
  }
  mNote(d, t + 7 * q, 7 * q, { wave: 'p12', f: nf('E5') * p, v: 0.11, gate: 0.95, rel: 0.18 });
  mNote(d, t + 7 * q, 7 * q, { wave: 'p12', f: nf('G5') * p, v: 0.1, gate: 0.95, rel: 0.18 });
  mNote(d, t + 3 * q, 2 * q, { wave: 'triangle', f: nf('G2') * p, v: 0.4, gate: 0.9 });
  mNote(d, t + 7 * q, 7 * q, { wave: 'triangle', f: nf('C3') * p, v: 0.45, gate: 0.95, rel: 0.2 });
  mKick(d, t, 0, { v: 0.5 }); mKick(d, t + 3 * q, 0, { v: 0.5 }); mKick(d, t + 7 * q, 0, { v: 0.7 }); mCrash(d, t + 7 * q, 0, { v: 0.3 });
  return t + 1.7;
}
function sfxCutin(t, p, d) {
  // 칼치기 당함: 끼익 + 짜증 '빵 빠앙!'
  brakeTone(t, p, d, 0.42, 0.6);
  hornTone(t + 0.12, 0.1, [400 * p, 500 * p], d, { scoop: 0.05 });
  return hornTone(t + 0.27, 0.3, [400 * p, 500 * p], d, { scoop: 0.06 });
}
function relayTick(t, fb, fs, a, d) {
  const g = G(0, d); noise(t, t + 0.012, F('bandpass', fb, 3, g)); perc(g.gain, t, 1.6 * a, 0.0005, 0.008);
  const g2 = G(0, d); osc('sine', fs, t, t + 0.04, g2); perc(g2.gain, t, 0.12 * a, 0.0008, 0.02);
}
function sfxBlink(t, p, d) { relayTick(t, 3400 * p, 2300 * p, 1, d); relayTick(t + 0.3, 1700 * p, 1250 * p, 0.8, d); return t + 0.36; }
const VOWELS = [[800, 1200], [500, 1700], [450, 850], [320, 2200], [380, 900]]; // 아 에 오 이 우 (F1, F2)
function syl(t, len, f0, f1, vow, a, d, rasp = 0) {
  const g = G(0, d); const src = G(1);
  src.connect(F('bandpass', vow[0], 5, g)); src.connect(F('bandpass', vow[1], 7, g));
  const o = osc('sawtooth', f0, t, t + len + 0.05, src); o.frequency.exponentialRampToValueAtTime(f1, t + len);
  if (rasp) { const fm = G(rasp); osc('square', 70, t, t + len + 0.05, fm); fm.connect(o.frequency); }
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(a, t + 0.012); g.gain.setValueAtTime(a, t + len * 0.7); g.gain.linearRampToValueAtTime(0, t + len);
}
function sfxTaunt(t, p, d) {
  // 빌런 말풍선 '냐냐냐~': 포먼트 음절 3~4개 + 마지막 하강 글라이드
  const base = rand(180, 240) * p; const n = 3 + ((Math.random() * 2) | 0);
  let tt = t;
  for (let i = 0; i < n; i++) {
    const last = i === n - 1; const len = last ? 0.17 : rand(0.055, 0.08);
    const f0 = base * pick([1, 1.12, 1.26, 1.34, 0.94]); const f1 = last ? f0 * 0.68 : f0 * rand(1.04, 1.2);
    syl(tt, len, f0, f1, pick(VOWELS), 3.2, d); tt += len + 0.014;
  }
  return tt + 0.05;
}
function sfxChicken(t, p, d) {
  // 닭 '복-꽤액!'
  syl(t, 0.05, 420 * p, 470 * p, [550, 1050], 3.0, d, 30);
  const tt = t + 0.075, len = 0.2;
  const g = G(0, d); const src = G(1);
  src.connect(F('bandpass', 1000 * p, 4, g)); src.connect(F('bandpass', 2300 * p, 5, g));
  const o = osc('sawtooth', 560 * p, tt, tt + len + 0.05, src);
  o.frequency.exponentialRampToValueAtTime(980 * p, tt + 0.05); o.frequency.exponentialRampToValueAtTime(600 * p, tt + len);
  const fm = G(90 * p); osc('square', 47, tt, tt + len + 0.05, fm); fm.connect(o.frequency);
  const gn = G(0, d); noise(tt, tt + len + 0.02, F('bandpass', 1700 * p, 2, gn));
  for (const [gg, a] of [[g, 3.4], [gn, 0.7]]) {
    gg.gain.setValueAtTime(0, tt); gg.gain.linearRampToValueAtTime(a, tt + 0.01); gg.gain.setValueAtTime(a, tt + 0.13); gg.gain.linearRampToValueAtTime(0, tt + len);
  }
  return tt + len + 0.05;
}
function sfxGo(t, p, d) {
  // 출발 징글 '따단 따~!'
  const q = 0.09;
  mNote(d, t, q, { wave: 'p25', f: nf('G5') * p, v: 0.24, gate: 0.7 });
  mNote(d, t + q, q, { wave: 'p25', f: nf('G5') * p, v: 0.24, gate: 0.7 });
  mNote(d, t + 2 * q, 0.4, { wave: 'p25', f: nf('C6') * p, v: 0.28, gate: 1, vib: 20, rel: 0.15 });
  mNote(d, t + 2 * q, 0.4, { wave: 'p12', f: nf('E5') * p, v: 0.13, gate: 1, rel: 0.15 });
  mNote(d, t + 2 * q, 0.4, { wave: 'p12', f: nf('G5') * p, v: 0.11, gate: 1, rel: 0.15 });
  mNote(d, t + 2 * q, 0.4, { wave: 'triangle', f: nf('C3') * p, v: 0.4, gate: 1, rel: 0.15 });
  mKick(d, t + 2 * q, 0, { v: 0.6 }); mCrash(d, t + 2 * q, 0, { v: 0.25 });
  return t + 0.9;
}

// 이름 → { g: 기본 게인, dur: 보이스 점유(초), max: 동시 수, gap: 최소 재트리거, stagger?: 겹치면 이 간격으로 미룸, pri: 0~2 }
const SFX = {
  horn:         { g: 0.36, dur: 0.5,  max: 3, gap: 0.05, fn: (t, p, d) => hornTone(t, 0.35, [420 * p, 520 * p], d) },
  hornShort:    { g: 0.4,  dur: 0.27, max: 3, gap: 0.05, fn: (t, p, d) => hornTone(t, 0.12, [420 * p, 520 * p], d) },
  hornTruck:    { g: 0.4,  dur: 1.0,  max: 2, gap: 0.1,  fn: sfxHornTruck },
  hornAngry:    { g: 0.36, dur: 0.6,  max: 2, gap: 0.12, fn: sfxHornAngry },
  tack:         { g: 0.45, dur: 0.07, max: 2, gap: 0.045, pri: 0, fn: sfxTack },
  hit:          { g: 0.6,  dur: 0.14, max: 3, gap: 0.06, pri: 0, fn: sfxHit },
  crit:         { g: 0.7,  dur: 0.4,  max: 2, gap: 0.08, fn: sfxCrit },
  pop:          { g: 1.2,  dur: 0.9,  max: 4, gap: 0.06, stagger: 0.085, pri: 2, fn: sfxPop },
  explosion:    { g: 0.8,  dur: 1.6,  max: 2, gap: 0.12, pri: 2, fn: (t, p, d) => boom(t, p, d, 1) },
  whoosh:       { g: 0.45, dur: 0.5,  max: 3, gap: 0.06, fn: sfxWhoosh },
  bump:         { g: 0.55, dur: 0.25, max: 2, gap: 0.08, fn: sfxBump },
  laneChange:   { g: 0.35, dur: 0.2,  max: 2, gap: 0.05, pri: 0, fn: sfxLane },
  ui:           { g: 1.2,  dur: 0.08, max: 2, gap: 0.03, pri: 2, fn: sfxUi },
  uiConfirm:    { g: 0.6,  dur: 0.25, max: 2, gap: 0.05, pri: 2, fn: sfxUiConfirm },
  rageFull:     { g: 0.7,  dur: 0.8,  max: 1, gap: 0.2,  pri: 2, fn: sfxRage },
  super:        { g: 0.6,  dur: 1.2,  max: 2, gap: 0.15, pri: 2, fn: sfxSuper },
  superHit:     { g: 0.85, dur: 2.4,  max: 2, gap: 0.15, pri: 2, fn: sfxSuperHit },
  brakeScreech: { g: 0.32, dur: 0.8,  max: 2, gap: 0.15, fn: (t, p, d) => brakeTone(t, p, d, 0.78, 1) },
  warn:         { g: 0.42, dur: 0.5,  max: 1, gap: 0.3,  pri: 2, fn: sfxWarn },
  throw:        { g: 0.45, dur: 0.25, max: 2, gap: 0.08, fn: sfxThrow },
  splat:        { g: 0.85, dur: 0.4,  max: 3, gap: 0.05, fn: sfxSplat },
  launch:       { g: 0.4,  dur: 1.15, max: 2, gap: 0.2,  pri: 2, fn: sfxLaunch },
  twinkle:      { g: 0.9,  dur: 1.1,  max: 2, gap: 0.15, pri: 2, fn: sfxTwinkle },
  stageClear:   { g: 0.6,  dur: 1.6,  max: 1, gap: 0.5,  pri: 2, fn: sfxClear },
  star:         { g: 0.8,  dur: 0.6,  max: 3, gap: 0.05, pri: 2, fn: sfxStar },
  cutin:        { g: 0.36, dur: 0.7,  max: 2, gap: 0.2,  fn: sfxCutin },
  blink:        { g: 0.7,  dur: 0.35, max: 3, gap: 0.04, pri: 0, fn: sfxBlink },
  tauntBlip:    { g: 0.22, dur: 0.4,  max: 2, gap: 0.1,  fn: sfxTaunt },
  chicken:      { g: 0.3,  dur: 0.35, max: 2, gap: 0.1,  fn: sfxChicken },
  go:           { g: 0.55, dur: 0.9,  max: 1, gap: 0.3,  pri: 2, fn: sfxGo },
};

// ───────────────────────────── "대~한민국! 짝짝 짝짝짝" 경적 합주
// C장조 근처로 조율된 차 6대 → 화음처럼 들리고, 이어지는 해방 BGM(C장조)으로 자연스럽게 넘어간다.
const CHEER_CARS = [
  { f: [392, 494], pan: -0.8, v: 0.85, types: ['square', 'sawtooth'], cut: 2600, lag: 0.006 },        // 흰 세단
  { f: [440, 523], pan: -0.42, v: 0.8, types: ['sawtooth', 'square'], cut: 2300, lag: -0.004 },      // 택시
  { f: [330, 392], pan: 0.1, v: 0.85, types: ['square'], cut: 2000, lag: 0.012 },                    // SUV
  { f: [523, 659], pan: 0.45, v: 0.6, types: ['square'], cut: 3200, lag: -0.008 },                   // 경차 (앵앵)
  { f: [196, 247, 294], pan: 0.82, v: 0.8, types: ['sawtooth'], cut: 1500, lag: 0.018, truck: true }, // 1톤 트럭 에어혼
  { f: [262, 330], pan: -0.12, v: 0.7, types: ['sawtooth', 'square'], cut: 1800, lag: 0.002 },       // 고속버스
];
const CHEER_SYL = [[0, 2.55, 1], [3, 0.72, 0.82], [4, 0.72, 0.82], [5, 1.0, 1.05]]; // 대~ 한 민 국 (16분 슬롯, 길이, 세기)
const CHEER_CLAPS = [8, 9, 11, 12, 13];                                              // 짝 짝 · 짝 짝 짝
function cheerCar(car, hits, end) {
  hits.sort((a, b) => a[0] - b[0]);
  const d = panNode(car.pan, S.n.sfx);
  const mix = G(0); const lp = F('lowpass', car.cut, 0.9); const pk = F('peaking', car.truck ? 650 : 1150, 1.3);
  pk.gain.value = 6; mix.connect(lp); lp.connect(pk); pk.connect(d);
  const t0 = Math.max(0, hits[0][0] - 0.02);
  const oscs = car.f.map((f, i) => {
    const o = C.createOscillator(); o.type = car.types[i % car.types.length]; o.detune.value = rand(-6, 6);
    o.frequency.setValueAtTime(f, t0); o.connect(mix); o.start(t0); o.stop(end); return o;
  });
  const g = mix.gain; const lvl = (car.v * 0.72) / car.f.length;
  g.setValueAtTime(0, t0);
  let prevEnd = -1;
  for (const [h0, len, a] of hits) {
    const ht = Math.max(h0, prevEnd + 0.012), amp = lvl * a;
    g.setValueAtTime(0, ht); g.linearRampToValueAtTime(amp, ht + 0.008);
    g.setValueAtTime(amp, ht + Math.max(0.012, len)); g.linearRampToValueAtTime(0, ht + len + 0.025);
    prevEnd = ht + len + 0.025;
    const sc = car.truck ? 0.06 : 0.035, st = car.truck ? 0.07 : 0.03;
    oscs.forEach((o, i) => { const f = car.f[i]; o.frequency.setValueAtTime(f * (1 - sc), ht); o.frequency.exponentialRampToValueAtTime(f, ht + st); });
  }
}
function clap(t, dest, a, pan, f) {
  // 손뼉 = 아주 빠른 노이즈 버스트 3번(여러 손바닥) + 짧은 잔향
  const g = G(0, panNode(pan, dest));
  noise(t, t + 0.2, F('highpass', 500, 0.7, F('bandpass', f, 1.1, g)));
  const gg = g.gain; gg.setValueAtTime(0, t);
  [0, 0.0095, 0.0195].forEach((k, i) => { const aa = a * (i === 2 ? 1 : 0.7); gg.setValueAtTime(aa, t + k); gg.exponentialRampToValueAtTime(aa * 0.12, t + k + 0.0085); });
  gg.setValueAtTime(a * 0.85, t + 0.029); gg.setTargetAtTime(0, t + 0.03, 0.03);
}
function crowdClap(t, a) {
  clap(t, S.n.sfx, 6.5 * a, rand(-0.6, -0.2), rand(1050, 1250));
  clap(t + rand(0.003, 0.011), S.n.sfx, 5.5 * a, rand(-0.15, 0.15), rand(1250, 1500));
  clap(t + rand(0.008, 0.02), S.n.sfx, 5.0 * a, rand(0.2, 0.6), rand(1500, 1850));
}

// ───────────────────────────── 음악: 악기
// 공통 시그니처 (dest, t, d초, p)
function mNote(dest, t, d, p) {
  const o = C.createOscillator();
  const w = S.waves[p.wave || 'p25'];
  if (w) o.setPeriodicWave(w); else o.type = p.wave;
  const dur = Math.max(0.03, d * (p.gate != null ? p.gate : 0.9));
  o.frequency.setValueAtTime(p.f, t);
  if (p.slide) { o.frequency.setValueAtTime(p.f * Math.pow(2, -p.slide / 12), t); o.frequency.exponentialRampToValueAtTime(p.f, t + 0.07); }
  if (p.det) o.detune.setValueAtTime(p.det, t);
  const g = G(0);
  if (p.lp) { o.connect(F('lowpass', p.lp, 0.8, g)); } else o.connect(g);
  g.connect(dest);
  const v = p.v != null ? p.v : 0.3, a = p.a || 0.005, sus = p.sus != null ? p.sus : 0.7, rel = p.rel || 0.05;
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v, t + a);
  g.gain.setTargetAtTime(v * sus, t + a, p.dec || 0.08);
  g.gain.setTargetAtTime(0, t + Math.max(a, dur), rel / 3);
  const end = t + dur + rel * 2 + 0.03;
  if (p.vib && dur > 0.22) {
    const l = C.createOscillator(); l.frequency.value = p.vibHz || 5.8; const lg = G(0); l.connect(lg); lg.connect(o.detune);
    lg.gain.setValueAtTime(0, t + 0.12); lg.gain.linearRampToValueAtTime(p.vib, t + 0.3); l.start(t); l.stop(end);
  }
  o.start(t); o.stop(end);
}
function mBeep(dest, t, d, p) {
  // 통화대기음 칩 소리: 사각+사인, 테이프 늘어짐처럼 음정이 살짝 출렁 (일부러 약간 짜증나게)
  const wob = 14 * Math.sin(t * 1.3) + 9 * Math.sin(t * 0.37 + 1);
  mNote(dest, t, d, { f: p.f, v: p.v * 0.7, wave: 'square', lp: 1500, det: wob - 8, a: 0.02, dec: 0.2, sus: 0.6, gate: 0.92, rel: 0.12 });
  mNote(dest, t, d, { f: p.f, v: p.v * 0.8, wave: 'sine', det: wob, a: 0.02, dec: 0.3, sus: 0.5, gate: 0.92, rel: 0.15 });
}
function mPad(dest, t, d, p) {
  for (const f of p.fs) mNote(dest, t, d, { f, v: p.v, wave: 'triangle', a: 0.12, dec: 0.4, sus: 0.8, gate: 0.97, rel: 0.3, det: rand(-6, 6) });
}
function mStab(dest, t, d, p) {
  for (const f of p.fs) mNote(dest, t, d, { f, v: p.v, wave: p.wave || 'square', lp: p.lp || 2400, a: 0.003, dec: 0.05, sus: 0.45, gate: 0.8, rel: 0.04 });
}
function mKick(dest, t, d, p) {
  const g = G(0, dest); const o = osc('sine', 150, t, t + 0.35, g); o.frequency.exponentialRampToValueAtTime(42, t + 0.09);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(p.v != null ? p.v : 0.8, t + 0.003); g.gain.setTargetAtTime(0, t + 0.02, 0.07);
}
function mSnare(dest, t, d, p) {
  const v = p.v != null ? p.v : 0.5;
  const g = G(0, dest); noise(t, t + 0.25, F('highpass', 600, 0.7, F('bandpass', 1900, 0.6, g))); perc(g.gain, t, v * 2.2, 0.001, 0.14);
  const g2 = G(0, dest); const o = osc('triangle', 185, t, t + 0.12, g2); o.frequency.exponentialRampToValueAtTime(160, t + 0.06); perc(g2.gain, t, v * 0.7, 0.001, 0.07);
}
function mHat(dest, t, d, p) {
  const g = G(0, dest); noise(t, t + (p.open ? 0.2 : 0.06), F('highpass', 7500, 0.7, g));
  perc(g.gain, t, (p.v != null ? p.v : 0.2) * 1.6, 0.001, p.open ? 0.12 : 0.035);
}
function mClap(dest, t, d, p) { clap(t, dest, (p.v != null ? p.v : 0.4) * 4, 0, 1300); }
function mRim(dest, t, d, p) {
  const v = p.v != null ? p.v : 0.2;
  const g = G(0, dest); osc('sine', 1750, t, t + 0.05, g); perc(g.gain, t, v * 0.5, 0.001, 0.02);
  const g2 = G(0, dest); noise(t, t + 0.02, F('bandpass', 2400, 3, g2)); perc(g2.gain, t, v * 2, 0.0005, 0.008);
}
function mBrush(dest, t, d, p) {
  const g = G(0, dest); noise(t, t + 0.3, F('bandpass', 3500, 0.5, g));
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime((p.v != null ? p.v : 0.2) * 1.5, t + 0.025); g.gain.setTargetAtTime(0, t + 0.03, 0.05);
}
function mTom(dest, t, d, p) {
  const g = G(0, dest); const o = osc('sine', p.f, t, t + 0.3, g); o.frequency.exponentialRampToValueAtTime(p.f * 0.6, t + 0.18);
  perc(g.gain, t, p.v != null ? p.v : 0.5, 0.002, 0.22);
}
function mCrash(dest, t, d, p) {
  const g = G(0, dest); noise(t, t + 1.4, F('highpass', 4500, 0.6, g)); perc(g.gain, t, (p.v != null ? p.v : 0.25) * 1.4, 0.002, 1.1);
}

// ───────────────────────────── 음악: 시퀀서 빌더 (16분음표 그리드, 1마디 = 16스텝)
function parseLine(str) {
  // 토큰: 'C5' 음, '-' 앞 음 늘이기, '.' 쉼표, '|' 무시. 접미 '~' = 꺾기(반음 아래서 슬라이드)
  const out = []; let cur = null; let i = 0;
  for (const tok of str.trim().split(/\s+/)) {
    if (tok === '|') continue;
    if (tok === '-') { if (cur) cur.len++; i++; continue; }
    const m = /^([A-G][#b]?-?\d)(~?)$/.exec(tok);
    if (!m) { cur = null; i++; continue; }
    cur = { i, n: m[1], len: 1, slide: !!m[2] }; out.push(cur); i++;
  }
  return out;
}
const QUAL = { '': [0, 4, 7], m: [0, 3, 7], maj7: [0, 4, 7, 11], m7: [0, 3, 7, 10], 7: [0, 4, 7, 10] };
function chordOf(name) { const m = /^([A-G][#b]?)(.*)$/.exec(name); return { root: PC[m[1]], iv: QUAL[m[2]] || QUAL[''] }; }
function voicing(name, lo) { // 밀집 배치: 모든 구성음을 [lo, lo+12) 안으로
  const { root, iv } = chordOf(name);
  return iv.map((x) => { let m = root + x; while (m < lo) m += 12; while (m >= lo + 12) m -= 12; return m; }).sort((a, b) => a - b);
}
const bassOf = (name, oct = 2) => 12 * (oct + 1) + chordOf(name).root;
class SB {
  constructor(bpm, bars, o = {}) {
    this.bpm = bpm; this.stepDur = 60 / bpm / 4; this.total = bars * 16;
    this.loopStart = (o.loopBar || 0) * 16; this.swing = o.swing || 0; this.gain = o.gain || 0.5;
    this.ev = Array.from({ length: this.total }, () => []);
  }
  add(step, fn, p) { if (step >= 0 && step < this.total) this.ev[step].push([fn, p]); }
  line(bar, str, fn, p = {}, res = 2) {
    for (const n of parseLine(str)) this.add(bar * 16 + n.i * res, fn, { ...p, f: mtof(nm(n.n) + (p.tr || 0)), steps: n.len * res, slide: n.slide ? 1 : 0 });
  }
  lines(bar0, arr, fn, p, res) { arr.forEach((s, i) => this.line(bar0 + i, s, fn, p, res)); }
  drum(b0, b1, pat, fn, p = {}) {
    pat = pat.replace(/\s+/g, ''); const per = 16 / pat.length;
    for (let b = b0; b < b1; b++) for (let i = 0; i < pat.length; i++) {
      const c = pat[i]; if (c === '.') continue;
      const v = (p.v != null ? p.v : 0.6) * (c === 'X' ? 1.25 : c === 'o' ? 0.55 : 1);
      this.add(b * 16 + Math.round(i * per), fn, { ...p, v });
    }
  }
  // 반마디 단위 코드 진행 순회. 'C|D' = 앞 반마디 C, 뒤 반마디 D
  halves(chords, fn) { chords.forEach((c, b) => { const h = c.split('|'); fn(b * 16, h[0], b); fn(b * 16 + 8, h[1] || h[0], b); }); }
}

const SONGS = {
  // 메뉴: 통통 튀는 칩튠 (G장조 132bpm, 8마디)
  menu() {
    const b = new SB(132, 8, { gain: 0.42 });
    const ch = ['G', 'Em', 'C', 'D', 'G', 'Em', 'C|D', 'G'];
    b.lines(0, [
      'G5 . D5 . G5 A5 B5 .',
      'G5 . E5 . B4 . E5 G5',
      'C6 . B5 . A5 G5 E5 .',
      'F#5 . A5 . D6 . C6 .',
      'B5 . A5 G5 . G5 A5 B5',
      'C6 . B5 . G5 . E5 .',
      'C5 E5 A5 . D5 F#5 A5 .',
      'G5 . D5 . B4 . G4 .',
    ], mNote, { wave: 'p25', v: 0.2, gate: 0.55, dec: 0.06, sus: 0.5, lp: 5200 });
    b.halves(ch, (s, c) => {
      const r = bassOf(c, 2);
      b.add(s, mNote, { wave: 'triangle', f: mtof(r), steps: 2, v: 0.5, gate: 0.85 });
      b.add(s + 4, mNote, { wave: 'triangle', f: mtof(r + 12), steps: 2, v: 0.4, gate: 0.7 });
      const vs = voicing(c, 67), arp = [vs[0], vs[1], vs[2], vs[0] + 12];
      for (let k = 0; k < 8; k++) b.add(s + k, mNote, { wave: 'p12', f: mtof(arp[k % 4]), steps: 1, v: 0.05, gate: 0.6, dec: 0.03, sus: 0.3 });
    });
    b.drum(0, 8, 'x.......x.......', mKick, { v: 0.55 });
    b.drum(0, 8, '....x.......x...', mSnare, { v: 0.3 });
    b.drum(0, 8, '..x...x...x...x.', mHat, { v: 0.12 });
    return b;
  },
  // 정체: 일부러 느릿·답답한 엘리베이터/통화대기 음악 (80bpm 스윙, 8마디, 해결 안 되고 무한 반복)
  jam() {
    const b = new SB(80, 8, { swing: 0.6, gain: 0.34 });
    const ch = ['Cmaj7', 'Am7', 'Dm7', 'G7', 'Em7', 'A7', 'Dm7', 'G7'];
    b.lines(0, [
      'E5 - - D5 E5 - G5 -',
      'A5 - - G5 E5 - - -',
      'F5 - - E5 F5 - A5 -',
      'G5 - - F5 D5 - - -',
      'G5 - - F5 E5 - D5 -',
      'C#5 - E5 - G5 - - -',
      'F5 - E5 D5 B4 - D5 -',
      'C5 - - - . . . .',
    ], mBeep, { v: 0.22 });
    ch.forEach((c, i) => {
      const s = i * 16, r = bassOf(c, 2);
      b.add(s, mPad, { fs: voicing(c, 55).map(mtof), v: 0.045, steps: 16 });
      b.add(s, mNote, { wave: 'triangle', f: mtof(r), steps: 6, v: 0.42, gate: 0.9, rel: 0.1 });
      b.add(s + 8, mNote, { wave: 'triangle', f: mtof(r + 7), steps: 6, v: 0.36, gate: 0.9, rel: 0.1 });
      if (i === 3 || i === 7) b.add(s + 14, mNote, { wave: 'triangle', f: mtof(bassOf(ch[(i + 1) % 8], 2) - 1), steps: 2, v: 0.3, gate: 0.8 });
    });
    b.drum(0, 8, 'x.......x.......', mKick, { v: 0.28 });
    b.drum(0, 8, '....x.......x...', mBrush, { v: 0.22 });
    b.drum(0, 8, 'x..x..x...x.x...', mRim, { v: 0.14 });
    return b;
  },
  // 보스: 긴박한 단조 칩튠 (A단조 150bpm, 16마디: A 8 + B 8), 옥타브 펌핑 베이스 + 드럼
  boss() {
    const b = new SB(150, 16, { gain: 0.44 });
    const ch = ['Am', 'Am', 'F', 'G', 'Am', 'Am', 'F', 'E', 'Dm', 'Am', 'Dm', 'E', 'F', 'G', 'E', 'E'];
    const lead = { wave: 'p25', v: 0.18, gate: 0.82, dec: 0.07, sus: 0.6, lp: 6000, vib: 18 };
    b.lines(0, [
      'A4 A4 C5 A4 E5 - D5 C5',
      'B4 C5 B4 A4 G#4 - E4 -',
      'F4 A4 C5 A4 F5 - E5 D5',
      'D5 E5 D5 C5 B4 - G4 -',
      'A4 A4 C5 A4 E5 - A5 -',
      'G5 - E5 - C5 D5 E5 -',
      'F5 E5 D5 C5 D5 C5 B4 A4',
      'G#4 - B4 - E5 - - -',
      'D5 - F5 - A5 - F5 D5',
      'E5 - C5 - A4 - C5 E5',
      'F5 - A5 - D6 - C6 A5',
      'B5 - G#5 - E5 - B4 -',
      'C6 B5 A5 G5 F5 E5 F5 A5',
      'B5 A5 G5 F5 D5 E5 F5 G5',
      'G#5 - - - B5 - - -',
      'E6 - D6 C6 B5 G#5 E5 -',
    ], mNote, lead);
    ch.forEach((c, i) => {
      const s = i * 16, r = bassOf(c, 2);
      for (let k = 0; k < 8; k++) b.add(s + k * 2, mNote, { wave: 'square', lp: 750, f: mtof(k % 2 ? r + 12 : r), steps: 2, v: 0.22, gate: 0.7, dec: 0.05, sus: 0.6 });
      const vs = voicing(c, 69), arp = [vs[0], vs[1], vs[2], vs[0] + 12, vs[2], vs[1]];
      for (let k = 0; k < 16; k++) b.add(s + k, mNote, { wave: 'p12', f: mtof(arp[k % 6]), steps: 1, v: i < 8 ? 0.035 : 0.055, gate: 0.5, dec: 0.02, sus: 0.3 });
    });
    for (const fill of [7, 15]) {
      b.drum(fill, fill + 1, 'x...x...x...x...', mKick, { v: 0.75 });
      b.drum(fill, fill + 1, '....x.......xxXX', mSnare, { v: 0.32 });
    }
    for (const [b0, b1, kick, hat] of [[0, 7, 'x...x...x...x...', '..x...x...x...x.'], [8, 15, 'x...x...x.x.x...', 'oxoxoxoxoxoxoxox']]) {
      b.drum(b0, b1, kick, mKick, { v: 0.75 });
      b.drum(b0, b1, '....x.......x...', mSnare, { v: 0.36 });
      b.drum(b0, b1, hat, mHat, { v: 0.11 });
    }
    b.add(0, mCrash, { v: 0.2 }); b.add(8 * 16, mCrash, { v: 0.24 });
    return b;
  },
  // 해방: 고속도로 휴게소 뽕짝 메들리 (C장조 펜타토닉 130bpm). 인트로 2마디(쿵짝+베이스) → 16마디 루프
  //  인트로 1마디째가 '대~한민국' 2회차와, 2마디째 첫 박이 합주 마무리 '빠앙!' 과 맞물린다.
  release() {
    const b = new SB(RELEASE_BPM, 18, { loopBar: 2, gain: 0.5 });
    const ch = ['C', 'G', 'C', 'C', 'G', 'G', 'C', 'Am', 'G', 'C', 'F', 'C', 'F', 'G', 'C', 'Am', 'G', 'C'];
    const lead = { wave: 'p25', v: 0.2, gate: 0.86, dec: 0.08, sus: 0.65, lp: 6500, vib: 30, vibHz: 6.4 };
    const hookA = [
      'E5 . E5 G5 A5~ . G5 .',
      'E5 . D5 . C5 - - .',
      'D5 . D5 E5 G5 . E5 .',
      'D5 . C5 . D5~ - - .',
      'E5 . E5 G5 A5 . C6~ .',
      'A5 . G5 . E5 - G5 .',
      'G5 . A5 . G5 E5 D5 .',
      'C5 - - - . . G4 A4',
    ];
    const hookB = [
      'C6~ . A5 . C6 . A5 G5',
      'E5 . G5 - - . . .',
      'C6~ . A5 . C6 D6 C6 A5',
      'G5 - - . . . E5 G5',
      'A5 A5 G5 E5 G5 . E5 D5',
      'E5 . D5 C5 A4 - C5 D5',
      'E5 . D5 . G5 . A5~ .',
      'C6 - - - . . . .',
    ];
    b.lines(2, hookA, mNote, lead);
    b.lines(10, hookB, mNote, lead);
    b.lines(10, hookB, mNote, { wave: 'p12', v: 0.07, gate: 0.8, tr: -12, lp: 3000 }); // B 파트 옥타브 아래 더블링
    ch.forEach((c, i) => {
      const s = i * 16, r = bassOf(c, 2);
      // 쿵(1·3박) = 근음/5도 베이스, 짝(2·4박) = 오르간 코드 스탭
      if (i === 1) { for (const [k, n] of [[0, 'G2'], [8, 'A2'], [12, 'B2']]) b.add(s + k, mNote, { wave: 'triangle', f: nf(n), steps: 3, v: 0.55, gate: 0.85 }); }
      else if (i === 9) { for (const [k, n] of [[0, 'C2'], [8, 'D2'], [12, 'E2']]) b.add(s + k, mNote, { wave: 'triangle', f: nf(n), steps: 3, v: 0.55, gate: 0.85 }); }
      else {
        b.add(s, mNote, { wave: 'triangle', f: mtof(r), steps: 3, v: 0.55, gate: 0.85 });
        b.add(s + 8, mNote, { wave: 'triangle', f: mtof(r - 5), steps: 3, v: 0.5, gate: 0.85 });
      }
      const fs = voicing(c, 60).map(mtof);
      b.add(s + 4, mStab, { fs, v: 0.06, steps: 2 }); b.add(s + 12, mStab, { fs, v: 0.06, steps: 2 });
    });
    b.drum(0, 18, 'x.......x.......', mKick, { v: 0.8 });
    b.drum(0, 18, '....x.......x...', mSnare, { v: 0.42 });
    b.drum(0, 18, '..x...x...x...x.', mHat, { v: 0.14, open: true });
    b.drum(10, 18, '....x.......x...', mClap, { v: 0.3 });
    for (const [bar, f0] of [[1, 220], [9, 200], [17, 220]]) {
      [8, 10, 12, 14].forEach((k, j) => b.add(bar * 16 + k, mTom, { f: f0 * Math.pow(0.84, j), v: 0.45 }));
    }
    b.add(2 * 16, mCrash, { v: 0.26 }); b.add(10 * 16, mCrash, { v: 0.26 });
    return b;
  },
};
const SONG_CACHE = Object.create(null);
function getSong(kind) {
  if (!SONGS[kind]) return null;
  return SONG_CACHE[kind] || (SONG_CACHE[kind] = SONGS[kind]());
}

// ───────────────────────────── 음악: 스케줄러
function startSong(kind) {
  const song = getSong(kind); if (!song) return;
  const t = C.currentTime; let at = t + 0.06;
  // 해방 BGM 은 경적 합주 그리드(같은 템포)에 맞춰 마디 경계에서 진입
  if (kind === 'release' && S.cheerT0 > 0) {
    const bar = 16 * song.stepDur, rel = at - S.cheerT0;
    if (rel <= 0 && rel > -1) at = Math.max(t, S.cheerT0);                 // 합주와 같은 틱 → 같은 다운비트
    else if (rel > 0 && rel < 2 * bar) at = S.cheerT0 + Math.max(1, Math.ceil(rel / bar - 0.02)) * bar; // 다음 마디 경계
  }
  if (S.song) retire(S.song, at, 0.35);
  S.song = { kind, song, out: G(song.gain, S.n.music), step: 0, next: at, startAt: at, stopAt: Infinity, dieAt: Infinity };
  tick();
}
function retire(sp, at, fade) {
  sp.stopAt = Math.min(sp.stopAt, at);
  const g = sp.out.gain;
  g.cancelScheduledValues(at); g.setValueAtTime(sp.song.gain, at); g.linearRampToValueAtTime(0.0001, at + fade);
  sp.dieAt = at + fade + 1.5;
  if (!S.dying.includes(sp)) S.dying.push(sp);
}
function pump(sp, horizon) {
  const s = sp.song, sd = s.stepDur;
  const lim = Math.min(horizon, sp.stopAt);
  let guard = 0;
  while (sp.next < lim && guard++ < 8192) {
    if (!S.offline && sp.next < C.currentTime - 0.08) {
      // 메인 스레드 렉/탭 복귀로 밀렸으면 몰아서 연주하지 말고 그리드 유지한 채 건너뛴다
      const skip = Math.ceil((C.currentTime - sp.next) / sd);
      for (let i = 0; i < skip; i++) sp.step = sp.step + 1 >= s.total ? s.loopStart : sp.step + 1;
      sp.next += skip * sd; continue;
    }
    const st = sp.step;
    const tt = sp.next + (s.swing && (st & 3) === 2 ? s.swing * sd : 0);
    const evs = s.ev[st];
    for (let i = 0; i < evs.length; i++) {
      const e = evs[i];
      try { e[0](sp.out, tt, (e[1].steps || 1) * sd, e[1]); } catch (err) { /* 한 음 실패해도 계속 */ }
    }
    sp.step = st + 1 >= s.total ? s.loopStart : st + 1;
    sp.next += sd;
  }
}

// ───────────────────────────── 환경음
function startAmb(kind) {
  if (S.amb && S.amb.kind === kind) return;
  const t = C.currentTime;
  if (S.amb) {
    const a = S.amb; const g = a.out.gain;
    g.cancelScheduledValues(t); g.setValueAtTime(g.value, t); g.linearRampToValueAtTime(0, t + 0.6);
    a.srcs.forEach((s) => { try { s.stop(t + 0.7); } catch (e) { /* */ } });
    if (!S.offline) setTimeout(() => { try { a.out.disconnect(); } catch (e) { /* */ } }, 1500);
    S.amb = null;
  }
  if (kind !== 'jam' && kind !== 'free') return;
  const out = G(0, S.n.amb);
  const a = { kind, out, srcs: [], next: t + rand(0.4, 1.2) };
  if (kind === 'jam') {
    // 저역 웅웅 (수백 대 공회전) + 중역 웅성 (느리게 숨쉼)
    const rg = G(0.4, out); a.srcs.push(loopSrc(S.bufs.brown, F('lowpass', 150, 0.6, rg), t));
    const mg = G(0.09, out); a.srcs.push(loopSrc(S.bufs.white, F('bandpass', 320, 0.8, mg), t));
    const lg = G(0.035); lg.connect(mg.gain); a.srcs.push(osc('sine', 0.07, t, t + 36000, lg));
    out.gain.setValueAtTime(0, t); out.gain.linearRampToValueAtTime(1, t + 1.2);
  } else {
    // 바람: 노이즈 → (LFO 로 흔들리는) 밴드패스 → 로우패스, 점점 커짐 + 시작 '휘이잉'
    const wg = G(0.55, out); const bp = F('bandpass', 700, 0.5); bp.connect(F('lowpass', 2600, 0.5, wg));
    a.srcs.push(loopSrc(S.bufs.white, bp, t));
    const l1 = G(260); l1.connect(bp.frequency); a.srcs.push(osc('sine', 0.11, t, t + 36000, l1));
    const l2 = G(110); l2.connect(bp.frequency); a.srcs.push(osc('sine', 0.37, t, t + 36000, l2));
    const l3 = G(0.2); l3.connect(wg.gain); a.srcs.push(osc('sine', 0.21, t, t + 36000, l3));
    const sg = G(0, out); const sbp = F('bandpass', 250, 0.8, sg); a.srcs.push(noise(t, t + 1.8, sbp));
    sbp.frequency.setValueAtTime(250, t); sbp.frequency.exponentialRampToValueAtTime(1600, t + 0.8); sbp.frequency.exponentialRampToValueAtTime(700, t + 1.7);
    sg.gain.setValueAtTime(0, t); sg.gain.linearRampToValueAtTime(0.9, t + 0.7); sg.gain.linearRampToValueAtTime(0, t + 1.75);
    out.gain.setValueAtTime(0, t); out.gain.linearRampToValueAtTime(0.35, t + 0.5); out.gain.linearRampToValueAtTime(1, t + 3.5);
  }
  S.amb = a;
  tick();
}
const DISTANT = [[420, 520], [370, 466], [480, 600], [330, 415], [440, 554]];
function distantHonk(t, dest) {
  // 멀리서 '빵—' (랜덤 팬/피치, 거리감 = 낮은 컷오프 + 작은 볼륨)
  const r = Math.random(), p = rand(0.8, 1.25);
  const d = G(rand(0.12, 0.3), panNode(rand(-0.9, 0.9), dest));
  const cut = rand(900, 1700), fs = pick(DISTANT).map((f) => f * p);
  if (r < 0.55) hornTone(t, rand(0.12, 0.42), fs, d, { cut });
  else if (r < 0.8) { const dd = rand(0.07, 0.12); hornTone(t, dd, fs, d, { cut }); hornTone(t + dd + rand(0.06, 0.1), dd, fs, d, { cut }); }
  else if (r < 0.92) hornTone(t, rand(0.5, 0.9), [220 * p, 277 * p], d, { types: ['sawtooth'], cut: cut * 0.8, body: 640, scoop: 0.06, scoopT: 0.08 });
  else hornTone(t, rand(0.8, 1.2), fs, d, { cut, lvl: 1.1 }); // 참다 참다 길게 '빠아아앙'
}
function pumpAmb(a, horizon) {
  if (a.kind !== 'jam') return;
  let guard = 0;
  while (a.next < horizon && guard++ < 2048) {
    if (!S.offline && a.next < C.currentTime - 0.2) { a.next = C.currentTime + rand(0.2, 1); continue; }
    distantHonk(a.next, a.out); a.next += rand(0.6, 2.5);
  }
}

// ───────────────────────────── 엔진 (보이스 1개, 지연 생성, 이후 파라미터만 램프)
const GEARS = [0, 7, 15, 24, 33, 46];
function makeEngine() {
  const t = C.currentTime;
  const out = G(0, S.n.sfx);
  const lp = F('lowpass', 300, 2.5); lp.connect(shaper(1.6, out));
  const o1 = osc('sawtooth', 32, t, t + 36000, lp);
  const o2 = osc('sawtooth', 32, t, t + 36000, lp, 9);
  const subG = G(0.6, lp); const o3 = osc('sine', 16, t, t + 36000, subG);
  const amG = G(0); amG.connect(out.gain); const am = osc('sine', 16, t, t + 36000, amG); // 엔진 '부르르' 맥동
  const road = G(0, S.n.sfx); const rbp = F('bandpass', 650, 0.5); rbp.connect(F('lowpass', 1400, 0.5, road));
  const rs = loopSrc(S.bufs.white, rbp, t);
  return { out, lp, o1, o2, o3, am, amG, road, srcs: [o1, o2, o3, am, rs] };
}
function engineIdle(e, t) {
  e.out.gain.setTargetAtTime(0, t, 0.15); e.amG.gain.setTargetAtTime(0, t, 0.15); e.road.gain.setTargetAtTime(0, t, 0.15);
}

// ───────────────────────────── 틱 (25ms)
function tick() {
  if (!C || !S.n) return;
  const horizon = S.offline ? C.length / C.sampleRate : C.currentTime + LOOKAHEAD;
  if (S.song) pump(S.song, horizon);
  if (S.dying.length) {
    for (const sp of S.dying) pump(sp, horizon);
    if (!S.offline) S.dying = S.dying.filter((sp) => { if (C.currentTime > sp.dieAt) { try { sp.out.disconnect(); } catch (e) { /* */ } return false; } return true; });
  }
  if (S.amb) pumpAmb(S.amb, horizon);
  if (S.eng && !S.engIdle && !S.offline && perfNow() - S.engCall > 500) { S.engIdle = true; engineIdle(S.eng, C.currentTime); }
}

// ───────────────────────────── 공개 API
export const audio = {
  init(opts) {
    try {
      const ext = opts && opts.context;
      if (ext) { if (ext !== C) { bind(ext, opts); S.own = false; } return; }
      if (C && C.state === 'closed') teardown();
      if (!C) {
        const AC = typeof globalThis !== 'undefined' && (globalThis.AudioContext || globalThis.webkitAudioContext);
        if (!AC) return;
        let ctx;
        try { ctx = new AC({ latencyHint: 'interactive' }); } catch (e) { ctx = new AC(); }
        S.hidden = typeof document !== 'undefined' && !!document.hidden;
        bind(ctx, {}); S.own = true; hookVisibility();
      }
      if (!S.offline && !S.muted && !S.hidden && C.state !== 'running') {
        S.resumeAt = perfNow();
        const pr = C.resume(); if (pr && pr.catch) pr.catch(noop);
      }
    } catch (e) { /* 무음 */ }
  },

  setMuted(m) {
    try {
      S.muted = !!m;
      if (!C || !S.n) return;
      const t = C.currentTime, g = S.n.mute.gain;
      g.cancelScheduledValues(t); g.setValueAtTime(g.value, t); g.linearRampToValueAtTime(S.muted ? 0 : 1, t + 0.04);
      if (S.offline) return;
      const tok = ++S.muteTok;
      if (S.muted) setTimeout(() => { try { if (tok === S.muteTok && S.muted && C && C.state === 'running') C.suspend().catch(noop); } catch (e) { /* */ } }, 90);
      else if (!S.hidden && C.state !== 'running') { S.resumeAt = perfNow(); C.resume().catch(noop); }
    } catch (e) { /* */ }
  },

  isMuted() { return S.muted; },

  play(name, opts) {
    try {
      if (!ready()) return;
      const m = SFX[name]; if (!m) return;
      const o = opts || {};
      const vol = clamp(num(o.volume, 1), 0, 4); if (vol <= 0) return;
      const pitch = clamp(num(o.pitch, 1), 0.25, 4), pan = clamp(num(o.pan, 0), -1, 1);
      const at = admit(name, C.currentTime + 0.005 + clamp(num(o.delay, 0), 0, 10), m);
      if (at < 0) return;
      m.fn(at, pitch, G(vol * m.g, panNode(pan, S.n.sfx)));
    } catch (e) { /* */ }
  },

  setEngine(speedMs, throttle01) {
    try {
      if (!C || !S.n || S.muted) return;
      const pn = perfNow(); S.engCall = pn;
      if (!S.offline && pn - S.engT < 45 && !S.engIdle) return; // 매 프레임 호출 → 20Hz 로 솎기
      S.engT = pn; S.engIdle = false;
      const v = clamp(num(speedMs, 0), 0, 45), th = clamp(num(throttle01, 0), 0, 1);
      const e = S.eng || (S.eng = makeEngine());
      let gi = 0; while (gi < GEARS.length - 2 && v >= GEARS[gi + 1]) gi++;
      const fr = clamp((v - GEARS[gi]) / (GEARS[gi + 1] - GEARS[gi]), 0, 1);
      const rpm = gi === 0 ? 0.12 + 0.88 * fr : 0.38 + 0.62 * fr; // 기어 변속 시 회전수 툭 떨어짐
      const f = 30 + 105 * rpm;
      const lvl = 0.022 + 0.026 * th + 0.018 * rpm;
      const t = C.currentTime, k = 0.07;
      e.o1.frequency.setTargetAtTime(f, t, k); e.o2.frequency.setTargetAtTime(f, t, k);
      e.o3.frequency.setTargetAtTime(f / 2, t, k); e.am.frequency.setTargetAtTime(f / 2, t, k);
      e.lp.frequency.setTargetAtTime(220 + 1100 * th * (0.4 + rpm) + 500 * rpm, t, k);
      e.out.gain.setTargetAtTime(lvl, t, 0.1); e.amG.gain.setTargetAtTime(lvl * 0.35, t, 0.1);
      e.road.gain.setTargetAtTime(0.2 * Math.pow(v / 40, 1.5), t, 0.2);
    } catch (e) { /* */ }
  },

  startAmbience(kind) {
    try {
      S.wantAmb = kind === 'jam' || kind === 'free' ? kind : null;
      if (!C || !S.n) return;
      startAmb(S.wantAmb);
    } catch (e) { /* */ }
  },

  cheerHorns() {
    try {
      if (!ready()) return;
      const sd = 60 / RELEASE_BPM / 4; // 16분 슬롯 = 해방 BGM 그리드
      let t0 = C.currentTime + 0.06;
      if (S.song && S.song.kind === 'release') {
        // 이미 뽕짝이 흐르면 다음 '쿵'(반마디)에 맞춰 시작
        const sp = S.song; t0 = sp.next + ((8 - (sp.step % 8)) % 8) * sd;
      } else if (S.song) {
        // 보스/정체 음악은 함성에 자리를 내준다 (core 가 600ms 뒤 release 를 시작 → 이 그리드에 맞춰 진입)
        retire(S.song, C.currentTime, 0.25); S.song = null; S.wantMusic = null;
      }
      S.cheerT0 = t0;
      const end = t0 + 36 * sd + 0.5;
      CHEER_CARS.forEach((car, ci) => {
        const hits = [];
        for (let c = 0; c < 2; c++) {
          const base = t0 + c * 16 * sd, cres = c ? 1.12 : 1;
          for (const [s, l, a] of CHEER_SYL) hits.push([base + s * sd + car.lag + rand(-0.008, 0.008), l * sd, a * cres]);
          // 박수에 얹는 짧은 경적 찌르기 (차마다 번갈아, 2회차 '짝짝짝'은 다 같이)
          CHEER_CLAPS.forEach((s, k) => { if ((ci + k) % 2 === 0 || (c === 1 && k >= 2)) hits.push([base + s * sd + car.lag * 0.5 + rand(-0.006, 0.006), 0.42 * sd, 0.5 * cres]); });
        }
        hits.push([t0 + 32 * sd + car.lag, 4.2 * sd, 1.15]); // 마무리 '빠앙~!'
        cheerCar(car, hits, end);
      });
      for (let c = 0; c < 2; c++) for (const s of CHEER_CLAPS) crowdClap(t0 + (c * 16 + s) * sd, c ? 1.12 : 1);
    } catch (e) { /* */ }
  },

  startMusic(kind) {
    try {
      if (!kind) { audio.stopMusic(); return; }
      if (!SONGS[kind]) return;
      S.wantMusic = kind;
      if (!C || !S.n) return;
      if (S.song && S.song.kind === kind) return;
      startSong(kind);
    } catch (e) { /* */ }
  },

  stopMusic() {
    try {
      S.wantMusic = null;
      if (!C || !S.n || !S.song) return;
      retire(S.song, C.currentTime, 0.3); S.song = null;
    } catch (e) { /* */ }
  },

  duck(amount, seconds) {
    try {
      if (!C || !S.n || S.muted) return;
      const lvl = 1 - clamp(num(amount, 0.5), 0, 1), dur = clamp(num(seconds, 1), 0, 30);
      const t = C.currentTime, g = S.n.duck.gain;
      g.cancelScheduledValues(t); g.setValueAtTime(g.value, t);
      g.linearRampToValueAtTime(lvl, t + 0.06); g.setValueAtTime(lvl, t + 0.06 + dur); g.linearRampToValueAtTime(1, t + 0.6 + dur);
    } catch (e) { /* */ }
  },
};

// 개발 하네스/테스트 전용 (게임 코드는 쓰지 않음)
export function __audioDebug() {
  const nowT = C ? C.currentTime : 0;
  return {
    ctx: C, state: C ? C.state : 'none', offline: S.offline, muted: S.muted,
    music: S.song ? S.song.kind : null, wantMusic: S.wantMusic, musicStartAt: S.song ? S.song.startAt : null, cheerT0: S.cheerT0, ambience: S.amb ? S.amb.kind : null, wantAmbience: S.wantAmb,
    engine: !!S.eng, live: S.live.filter((e) => e > nowT).length,
    voices: Object.fromEntries(Object.entries(S.lim).map(([k, v]) => [k, v.ends.filter((e) => e > nowT).length])),
    sfxNames: Object.keys(SFX), musicKinds: Object.keys(SONGS),
    analyser() {
      if (!C || !S.n) return null;
      if (!S.analyser) { S.analyser = C.createAnalyser(); S.analyser.fftSize = 2048; S.n.mute.connect(S.analyser); }
      return S.analyser;
    },
  };
}
