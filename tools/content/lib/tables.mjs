// Hand-extracted tables for the one-time web export (NATIVE_PORT 3-5 rule: inline constants become data keys).
//
// Every traffic constant is written as K(value, 'file.js:LINE') and the export verifies that the cited line of the
// frozen web source really contains that number (so a typo in this file fails the export instead of shipping).
// The haptics table is transcribed from docs/NATIVE_PORT.md §2 "햅틱 맵" (event names = sim event names, not lines).

export class K {
  /** @param {number|string|boolean|Array|object} value @param {string} src 'traffic.js:337' @param {{pattern?: string}} [o] */
  constructor(value, src, o = {}) { this.value = value; this.src = src; this.pattern = o.pattern ?? null; }
}
const k = (value, line, o) => new K(value, `traffic.js:${line}`, o);
const m = (value, line, o) => new K(value, `main.js:${line}`, o);

/** Inline constants of traffic.js (IDM, per-lane-kind params, spawn gaps, events). Grouped by where they are used. */
export const TRAFFIC = {
  occupancy: {
    _doc: 'occupies(e, lane): |e.x - laneX(lane)| < e.w/2 + (LANE_W/2 - halfLaneMargin)',
    halfLaneMargin: k(0.6, 32),
  },
  car: {
    _doc: '_makeCar: RNG order mono, color, seed, personal, phase (5 draws). len/w come from vehicle_kinds.json dims.',
    monoP: k(0.68, 85),
    seedScale: k(1e6, 88, { pattern: '1e6' }),
    lenFallback: k(4.5, 94),
    wFallback: k(1.9, 94),
    personalBase: k(0.97, 95),
    personalSpan: k(0.06, 95),
    lcDurDefault: k(1.8, 92),
    vFreeDefault: k(30, 98),
    slowKinds: new K(['truck', 'bus', 'pickup1t'], 'traffic.js:47', { pattern: "'truck', 'bus', 'pickup1t'" }),
  },
  spawn: {
    _doc: 'spawnJam. RNG order is defined by the golden trace native/tests/golden/rng_trace_stage{1,5,6}.json',
    tailBehindPlayer: k(45, 125),
    frontRowFallback: new K([null, 'truck', 'truck', 'truck'], 'traffic.js:134', { pattern: "{ 1: 'truck', 2: 'truck', 3: 'truck' }" }),
    wallOffsetSpan: k(1.2, 142),
    emptyFrontRearBack: k(3, 147),
    leadGap: {
      _doc: 'first gap behind the front row: spaced ? base+rng*span : default; minus zigExtra on villain lanes of zigzag stages',
      spacedBase: k(9, 158), spacedSpan: k(4, 158), base: k(2.2, 158), span: k(1.6, 158), zigExtra: k(6, 158),
    },
    gap: {
      _doc: 'gapOf() by lane kind: base + rng*span (packed: (base + rng*span) / stage.density)',
      spaced: { base: k(7, 157), span: k(5, 157) },
      pass: { base: k(9, 157), span: k(5, 157) },
      train: { base: k(1.2, 157), span: k(0.5, 157) },
      flow: { base: k(2.6, 157), span: k(2, 157) },
      packed: { base: k(1.5, 157), span: k(1.7, 157), dividedByDensity: true },
    },
    laneCarV0Mul: k(0.7, 161),
    playerHoleHalf: k(3.4, 163),
    playerHolePushBack: k(2.0, 165),
    shoulderFallbackSpec: new K([['breakdown', 1], ['cones', 1], ['cheater', 1]], 'traffic.js:175', { pattern: "[['breakdown', 1], ['cones', 1], ['cheater', 1]]" }),
    crowdedCheaters: k(3, 177),
    darkSpec: new K([['debris', 3], ['breakdown', 1], ['cheater', 1]], 'traffic.js:178', { pattern: "[['debris', 3], ['breakdown', 1], ['cheater', 1]]" }),
    debrisSpec: new K([['debris', 4], ['cheater', 1]], 'traffic.js:179', { pattern: "[['debris', 4], ['cheater', 1]]" }),
    barrier: { fromBehindPlayer: k(20, 182), pastFront: k(30, 182), spacing: k(6, 582), xOffset: k(1.2, 584), zScale: k(0.5, 585) },
    blocked: { startFrac: k(0.45, 185), count: k(5, 186), spacing: k(12, 186) },
    shoulderStartAhead: k(38, 190),
    shoulderEndBeforeFront: k(22, 190),
    jitterBase: k(0.25, 194),
    jitterSpan: k(0.5, 194),
    cheaterKinds: new K([['sedan', 3], ['suv', 2], ['compact', 1]], 'traffic.js:196', { pattern: "[['sedan', 3], ['suv', 2], ['compact', 1]]" }),
    cheaterSpawnV: k(4.5, 196),
    cheaterVBase: k(4, 197),
    cheaterVSpan: k(2.5, 197),
    obstacleXOffset: k(0.1, 201),
    minis: {
      _doc: 'nMini = stage.minis ?? min(max, base + floor((difficulty ?? id ?? 1) / perDifficulty)); type = MINI_TYPES order (mini_types.json array)',
      max: k(4, 209), base: k(2, 209), perDifficulty: k(3, 209), window: k(30, 211), hp: k(12, 218), coolBase: k(0.6, 218),
    },
    opp: {
      _doc: 'opposite carriageway, 26 cars x 6 draws: lane, pickWeighted, mono, color, s, v',
      count: k(26, 227), lanes: k(4, 228), monoP: k(0.7, 230), sBehind: k(100, 235), sSpan: k(520, 235), vBase: k(24, 235), vSpan: k(12, 235), vPerLane: k(2, 235),
    },
  },
  idm: {
    _doc: 'acc = aMax*(1-(v/max(vFloor,v0))^delta) - aMax*(sStar/max(gapFloor,gap))^2, sStar = s0 + max(0, v*T + v*dv/(2*sqrt(aMax*b))), clamp [accMin, aMax]',
    b: k(3.0, 424),
    delta: k(4, 427, { pattern: 'vr * vr * vr * vr' }),
    vFloor: k(0.1, 426),
    gapFloor: k(0.3, 427),
    accMin: k(-9, 428),
    stopGap: k(0.25, 432),
    released: { T: k(0.5, 391), s0: k(2.0, 391), aMax: k(4.6, 391), aMaxSlow: k(2.6, 391) },
    wall: { follow: k(0.9, 394), T: k(0.5, 395), s0: k(1.5, 395), aMax: k(3.0, 395) },
    cheater: { v0Fallback: k(5, 397), T: k(0.6, 397), s0: k(2.0, 397), aMax: k(2.5, 397) },
    lanes: {
      _doc: 'unreleased normal cars by lane kind (laneKind[min(3, lane)]): v0 = jamSpeed * v0Mul [* personal]',
      train: { v0Mul: k(1.0, 400), personal: false, T: k(0.45, 400), s0: k(1.2, 400), aMax: k(1.6, 400) },
      flow: { v0Mul: k(0.95, 401), personal: true, T: k(0.8, 401), s0: k(2.2, 401), aMax: k(1.6, 401) },
      spaced: { v0Mul: k(1.05, 402), personal: true, T: k(1.6, 402), s0: k(5.5, 402), aMax: k(1.4, 402) },
      pass: { v0MulFallback: k(2.2, 403), v0MulKey: 'jamShape.passV', personal: true, T: k(1.0, 403), s0: k(3.0, 403), aMax: k(2.0, 403) },
      packed: {
        _doc: 'stop&go: lf = lfBase + lfAmp*(0.5+0.5*sin(t*lfFreq + lane*lfLanePhase)); v0 = jamSpeed*personal*lf*v0Mul',
        lfBase: k(0.35, 406), lfAmp: k(0.65, 406), lfFreq: k(0.42, 406), lfLanePhase: k(1.9, 406), v0Mul: k(1.25, 407), personal: true,
        T: k(0.5, 408), s0: k(1.4, 408), aMax: k(1.8, 408),
      },
    },
    pull: { v0Mul: k(2.2, 411), v0MulLetIn: k(3.6, 411), aMax: k(3.6, 411), T: k(0.3, 411), s0: k(1.0, 411) },
    brakeV0: k(0.01, 413),
    villainWall: { back: k(3, 421), zigExtra: k(5, 421) },
  },
  update: {
    randomBrake: { ratePerSec: k(0.6, 337), behindPlayer: k(10, 338), aheadPlayer: k(80, 338), holdBase: k(0.6, 339), holdSpan: k(0.7, 339) },
    cheaterEvent: {
      firstDelay: k(6, 344), minPlayerV: k(8, 345), nextBase: k(7, 346), nextSpan: k(5, 346),
      windowMin: k(14, 624), windowMax: k(30, 624), blockMargin: k(2, 627), vBase: k(4, 629), vSpan: k(2, 629), lcDur: k(0.9, 630),
    },
    minis: {
      dsMin: k(4, 357), dsMax: k(30, 357),
      cutin: { dsMin: k(10, 361), blockMargin: k(2, 361), v: k(3.5, 363), lcDur: k(0.8, 364), cool: k(3, 367) },
      throw: { maxActs: k(2, 368), coolBase: k(2.0, 371), coolSpan: k(1.2, 371) },
      marker: { lift: k(1.1, 355), bobFreq: k(6, 355), bobAmp: k(0.18, 355) },
    },
    release: { hazard: k(1.05, 382), nextLcBase: k(0.4, 383), nextLcSpan: k(0.6, 383), laneDelayCap: k(3, 314), wallExtra: k(0.35, 315), carExtra: k(0.08, 315) },
    laneChange: { yawGain: k(0.8, 440), yawMinV: k(2, 440), dtFloor: k(1e-4, 440, { pattern: '1e-4' }) },
    brakeLight: { accBelow: k(-0.25, 462), vBelow: k(1.6, 462), flickerFreq: k(1.3, 462), flickerAbove: k(0.2, 462) },
    hazard: { period: k(0.5, 464), onFrac: k(0.27, 464), cheaterFreq: k(2.2, 464) },
    opp: { recycleBehind: k(130, 475), respawnAhead: k(280, 475), respawnSpan: k(160, 475) },
    postRelease: {
      nextBase: k(0.8, 482), nextSpan: k(0.8, 482), slowMargin: k(3, 486), slowLcDur: k(1.4, 486),
      lookGap: k(22, 490), vMargin: k(3, 490), passMargin: k(3.5, 492), passLcDur: k(0.95, 492),
      cheaterReturnMargin: k(2.5, 451), cheaterReturnLcDur: k(1.2, 451),
    },
    stuck: {
      _doc: 'runs only while phase==="jam" in the web (NATIVE_PORT M1b R2: native runs it while jamLike)',
      vBelow: k(2.5, 499), decay: k(2, 500), rubberFallback: k(2.5, 501), rubberSafetyFallback: k(4, 506),
      pullAheadAfter: k(1, 508), towProbeAhead: k(16, 512), towProbeBehind: k(6, 512), autoTowAfter: k(2, 513),
    },
    jamWave: { amp: k(0.88, 523), speed: k(6, 523), hold: k(0.6, 523), life: k(6, 523), minStrength: k(0.15, 530), hitMargin: k(1.2, 533), holdCap: k(2.5, 535) },
    yieldSource: { behind: k(20, 550), ahead: k(5, 550), holdFallback: k(2.5, 553), waveOffset: k(1, 556), waveStrength: k(0.7, 556), waveAmp: k(0.8, 556), periodFallback: k(2.5, 560) },
  },
  queries: {
    canMergeInto: { margin: k(0.35, 281), yieldOverlap: k(1.3, 287) },
    hasGap: { lenFallback: k(4.2, 564), extra: k(1.0, 564), window: k(6, 575) },
    pullAhead: { range: k(18, 598), hold: k(1.2, 598) },
    letIn: { aheadMin: k(-3.5, 616), aheadMax: k(22, 616), pull: k(2.2, 616), behindMax: k(-14, 617), brake: k(2.2, 617), yieldFor: k(2.8, 617) },
    safeToEnter: { touch: k(-0.1, 639), closingGain: k(1.5, 640) },
    honk: {
      range: k(18, 656), rangeTrot: k(24, 656), rangeSiren: k(45, 656), probeBack: k(0.5, 657), villainRange: k(30, 658),
      cheaterRange: k(30, 662), cheaterRangeSiren: k(50, 662), cheaterLcDur: k(1.1, 664), rangeSlack: k(2, 675),
      fatigueRelax: k(8, 678), fatigueHalfP: k(0.5, 680), fatigueIgnoreAt: k(3, 680), yieldMargin: k(1.6, 686), yieldLcDur: k(0.85, 686),
    },
    rageHorn: { behind: k(2, 696), lcDur: k(0.7, 710), startledHold: k(0.5, 714) },
    miniTarget: { behind: k(-3, 728), ahead: k(26, 728), lateralLanes: k(1.2, 729) },
    miniHit: { jolt: k(0.6, 740), brake: k(2.5, 744), hazard: k(4, 745), lcDur: k(0.9, 746) },
    carsBehindFront: { n: k(6, 752), range: k(35, 752) },
  },
};

/** main.js setupStage — how a stage is turned into a spawn (frontS, start lane, RNG seed). */
export const SETUP = {
  _doc: 'main.js setupStage(stage): A = {...approach.default, ...stage.approach}; noShoulder = A.shoulder in noShoulderModes; jamLen = noShoulder ? min(stage.jamLength, A.jamLength ?? noShoulderJamLength) : stage.jamLength; startLane = noShoulder ? (A.startLane ?? noShoulderStartLane) : startLane; frontS = startS + jamLen + frontGap; traffic rng = mulberry32(stage.id*trafficSeedMul + trafficSeedAdd)',
  startS: m(0, 347),
  noShoulderModes: new K(['closed', 'none'], 'main.js:350', { pattern: "['closed', 'none']" }),
  noShoulderJamLength: m(85, 351),
  noShoulderStartLane: m(1, 352),
  startLane: m(3, 352),
  frontGap: m(30, 353),
  trafficSeedMul: m(1000, 360),
  trafficSeedAdd: m(7, 360),
  worldSeedMul: new K(7919, 'world.js:132'),
  worldSeedAdd: new K(13, 'world.js:132'),
};

// ─────────────────────────────────────────────────────────────────────────────
// Haptics (NATIVE_PORT §2 "햅틱 맵"). Pattern primitives:
//   { type: 'selection' } | { type: 'impactLight' } (UIKit generators, prepare() at phase start)
//   { type: 'transient', t, intensity, sharpness }   t = seconds from event start
//   { type: 'continuous', t, dur, intensity, sharpness, decayTo? }
// Android fallback (until M2 VibrationEffect.Composition): [{ t, ms, amp }] for Input.vibrate_handheld(ms, amp).
// null = not specified by the doc (tune on device; flagged ❓ in the doc).
const tr = (intensity, sharpness, t = 0) => ({ type: 'transient', t, intensity, sharpness });
const co = (dur, intensity, sharpness, t = 0, decayTo = null) => ({ type: 'continuous', t, dur, intensity, sharpness, decayTo });
const an = (ms, amp, t = 0) => ({ t, ms, amp });

export const HAPTICS = {
  schema_version: 1,
  source: 'docs/NATIVE_PORT.md §2 햅틱 맵 (2026-10-13). Values are ❓ until tuned on device (M1a/M1b).',
  global: {
    maxPerSecond: 12,
    realtime: true,            // fires immediately in real time, independent of hitstop/slow-mo
    settingKey: 'haptics',     // user can disable in settings
    silentModeTell: true,      // in silent play, haptic ticks replace sound tells (V04_SPEC open question 7)
    iosEngine: { autoShutdown: false, prewarmPatterns: true, restartOn: ['appActive', 'resetHandler', 'stoppedHandler'] },
  },
  events: {
    laneChange: { web: ["main.js:1066 'laneChange'"], ios: [{ type: 'selection' }], android: [an(10, 0.25)], minIntervalMs: null },
    horn: { web: ["main.js:1078 'horn'"], ios: [tr(0.35, 0.3)], android: [an(20, 0.35)], minIntervalMs: null },
    tackHit: { web: ["main.js:613 'hit'"], ios: [tr(0.2, 0.8)], android: [an(8, 0.2)], minIntervalMs: 120, maxPerSecond: 4 },
    crit: { web: [], ios: [tr(0.6, 0.6)], android: [an(25, 0.6)], minIntervalMs: null, note: 'crit hit; same pattern as shoulderSmash' },
    shoulderSmash: { web: ['main.js:790 fx.shake(0.25, 0.2)'], ios: [tr(0.6, 0.6)], android: [an(25, 0.6)], minIntervalMs: null },
    tirePop: { web: ['boss.js:253 fx.shake(0.35, 0.25)'], ios: [tr(0.9, 0.9)], android: [an(40, 0.9)], minIntervalMs: null },
    playerHitThrow: { web: ['main.js:734 fx.shake(0.4, 0.25)'], ios: [tr(0.5, 0.3)], android: [an(30, 0.5)], minIntervalMs: null },
    playerBump: { web: ['main.js:803 fx.shake(0.45, 0.25)'], ios: [tr(0.7, 0.3)], android: [an(35, 0.7)], minIntervalMs: null },
    playerHitBoss: { web: ['main.js:744 fx.shake(0.6, 0.35)'], ios: [tr(0.8, 0.2), co(0.08, 0.4, null)], android: [an(50, 0.8)], minIntervalMs: null },
    miniCaught: { web: ['main.js:233 fx.shake(0.3, 0.2)'], ios: [tr(0.5, 0.7, 0), tr(0.5, 0.7, 0.06)], android: [an(15, 0.5, 0), an(15, 0.5, 0.06)], minIntervalMs: null },
    rageFull: { web: ["main.js:178 'rageFull'"], ios: [tr(0.3, 0.8, 0), tr(0.6, 0.8, null), tr(0.9, 0.8, null)], android: [an(10, null, 0), an(10, null, null), an(10, null, null)], minIntervalMs: null, note: '3 rising ticks; spacing not specified (null)' },
    rageFire: { web: ['main.js:246 fx.shake(0.75, 0.5)'], ios: [co(0.08, 1.0, 0.4)], android: [an(80, 1.0)], minIntervalMs: null },
    rageHit: { web: ['main.js:606 fx.shake(0.8, 0.35)'], ios: [tr(0.9, 0.5)], android: [an(60, 0.9)], minIntervalMs: null },
    bossPhase: { web: ['main.js:261 fx.shake(0.6, 0.4)'], ios: [tr(0.9, 0.6)], android: [an(60, 0.9)], minIntervalMs: null },
    villainDownOne: { web: ['main.js:630 fx.shake(0.7, 0.4)'], ios: [tr(0.8, 0.5)], android: [an(50, 0.8)], minIntervalMs: null },
    villainKill: { web: ['main.js:496 fx.shake(1.1, 0.6)'], ios: [tr(1.0, 0.7), co(0.6, 0.6, 0.2, 0, 0)], android: [an(120, 1.0)], minIntervalMs: null },
    releaseWave: { web: ['main.js:523 fx.shake(0.5, 0.4)'], ios: [tr(0.6, 0.4), tr(0.5, 0.4, null), tr(0.4, 0.4, null), tr(0.3, 0.4, null), tr(0.2, 0.4, null)], android: [an(20, 0.6), an(20, 0.5, null), an(20, 0.4, null), an(20, 0.3, null), an(20, 0.2, null)], minIntervalMs: null, note: '5 transients timed to the release-wave beats (t = null: driven by the wave), intensity 0.6→0.2' },
    wreck: { web: ['main.js:481 fx.shake(1.0, 0.5)'], ios: [tr(1.0, 0.3), co(0.3, 0.2, 0.1)], android: [an(80, 1.0), an(300, 0.2, 0.08)], minIntervalMs: null },
    uiLight: { web: ['result stars/stamp', '1-5 blinker click', 'N3 enforce ring'], ios: [{ type: 'impactLight' }], iosAlt: [tr(0.3, 0.8)], android: [an(10, 0.3)], minIntervalMs: null },
  },
  _webShakeSites: 'all 13 web fx.shake sites are mapped: boss.js:253, main.js:233 246 261 481 496 523 606 630 734 744 790 803',
};
