// 1차선 참교육 — 메인: 상태 머신 · 카메라 연출 · 슬로모션 · 점수 · 오토파일럿 · 디버그 훅
//
// 가설: "막힘(분노 축적) → 원흉 발견 → 참교육(타이어 펑크) → 킬캠 → 드론샷 해방 물결 → 질주"의
//      대비가 쾌감의 본체. 연출 타이밍은 전부 이 파일에서 조율한다.
import * as THREE from 'three';
import {
  STAGES as HANDMADE, TUNE, laneX, toKmh, THANKS_LINES, BUMP_LINES, YIELD_LINES, NOWAY_LINES, NUM_LANES, LANE_W,
  LETIN_LINES, FRONT_RAGE_LINES, CHEATER_LINES, SHOULDER_LANE, MINI_TYPES, SHOP, SHOP_DEFAULT,
} from './config.js';
import { Input } from './input.js';
import { World } from './world.js';
import { Traffic, mulberry32, occupies } from './traffic.js';
import { Player } from './player.js';
import { BossManager } from './boss.js';
import { Weapons } from './weapons.js';
import { FX } from './fx.js';
import { audio } from './audio.js';
import { initUI, ui } from './ui.js';
import * as SC from './scenery.js';
import { setHeadlights } from './vehicles.js';
import * as VEH from './vehicles.js';
import { computeReward, applyReward } from './rewards.js';
import CATALOG from './data/villain_catalog.js';
import { buildStages } from './stagegen.js';

// 스테이지 목록: 리서치 카탈로그(100종)가 있으면 생성, 없으면 손으로 만든 5개
const STAGES = buildStages(CATALOG, HANDMADE);
const CHAPTERS = CATALOG?.chapters || null;

const params = new URLSearchParams(location.search);
const IS_TOUCH = (window.matchMedia && matchMedia('(pointer: coarse)').matches) || 'ontouchstart' in window;
const MOBILE = IS_TOUCH || Math.min(innerWidth, innerHeight) < 600;

// ───────────────────────────── 저장
const SAVE_KEY = 'lane1.progress.v1';
function loadProgress() {
  try {
    const p = JSON.parse(localStorage.getItem(SAVE_KEY) || 'null');
    if (p && typeof p.unlocked === 'number') return { unlocked: p.unlocked, stars: p.stars || {}, best: p.best || {}, wallet: p.wallet || 0, subs: p.subs || 0, album: p.album || {}, owned: p.owned || [], equip: { ...SHOP_DEFAULT, ...(p.equip || {}) } };
  } catch { /* 저장소 없음 */ }
  return { unlocked: 1, stars: {}, best: {}, wallet: 0, subs: 0, album: {}, owned: [], equip: { ...SHOP_DEFAULT } };
}
function saveProgress() {
  try { localStorage.setItem(SAVE_KEY, JSON.stringify(G.progress)); }
  catch {
    // 용량 초과 시 오래된 블박 사진부터 비움
    try { for (const k in G.progress.album || {}) G.progress.album[k].photo = null; localStorage.setItem(SAVE_KEY, JSON.stringify(G.progress)); } catch { /* 무시 */ }
  }
}

// ───────────────────────────── 렌더러/씬
const canvas = document.getElementById('game');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: !MOBILE, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, MOBILE ? 1.6 : 2));
renderer.setSize(innerWidth, innerHeight, false);
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(42, innerWidth / innerHeight, 0.5, 1400);
scene.add(camera);

const fx = new FX(scene, camera);
const world = new World(scene, { mobile: MOBILE });
const traffic = new Traffic(scene);
const player = new Player(scene);
const boss = new BossManager(scene, fx, audio);
const weapons = new Weapons(scene, fx, audio);
const input = new Input(canvas);

const G = {
  phase: 'boot', stageIdx: 0, stage: null,
  time: 0, phaseT: 0, phaseReal: 0, timeScale: 1, hitstop: 0, slowUntil: 0, slowScale: 1, realTime: 0,
  rage: 0, score: 0, combo: 0, maxCombo: 0, bumps: 0, supers: 0, hits: 0,
  progress: loadProgress(),
  paused: false,
  auto: params.get('auto') === '1',
  introStage: 0, introT2: 0,
  startS: 0, frontS: 0, tailS: 0, killS: 0,
  stageStart: 0, bossStart: 0, killTime: 0,
  mult: 10, releaseShown: 0, lastHorn: 0, lastBumpBubble: 0,
};
window.__game = G;

// ───────────────────────────── 화면 투영 & 말풍선
const _p = new THREE.Vector3();
function project(v3) {
  _p.copy(v3).project(camera);
  if (_p.z > 1 || _p.x < -1.2 || _p.x > 1.2 || _p.y < -1.2 || _p.y > 1.3) return null;
  return { x: (_p.x * 0.5 + 0.5) * innerWidth, y: (-_p.y * 0.5 + 0.5) * innerHeight };
}
const bubbles = new Map(); // key → { text, kind, until, pos: () => Vector3 }
function bubble(key, text, kind, dur, posFn) {
  bubbles.set(key, { text, kind, until: G.realTime + dur, pos: posFn });
}
function updateBubbles() {
  for (const [key, b] of bubbles) {
    if (G.realTime > b.until) { bubbles.delete(key); ui.removeBubble(key); continue; }
    const sp = project(b.pos());
    if (sp) ui.bubble(key, sp.x, sp.y, b.text, b.kind); else ui.removeBubble(key);
  }
}
function clearBubbles() { bubbles.clear(); ui.clearBubbles(); }
const hud = {
  popAt(pos, text, kind = 'hit') { const sp = project(pos); if (sp) ui.popText(sp.x, sp.y, text, kind); },
};
const carTop = (c, extra = 1.0) => () => _tmpTop.set(c.mesh.position.x, (c.mesh.userData.height || 1.6) + extra, c.mesh.position.z);
const _tmpTop = new THREE.Vector3();

// ───────────────────────────── 해방 물결 띠 (앞→뒤로 쓸고 가는 초록 빛)
const releaseWave = (() => {
  const cv = document.createElement('canvas'); cv.width = 16; cv.height = 128;
  const g = cv.getContext('2d');
  const grd = g.createLinearGradient(0, 0, 0, 128);
  grd.addColorStop(0, 'rgba(40,220,110,0)'); grd.addColorStop(0.42, 'rgba(60,235,120,0.7)');
  grd.addColorStop(0.5, 'rgba(170,255,190,0.95)'); grd.addColorStop(0.58, 'rgba(60,235,120,0.7)'); grd.addColorStop(1, 'rgba(40,220,110,0)');
  g.fillStyle = grd; g.fillRect(0, 0, 16, 128);
  const tex = new THREE.CanvasTexture(cv);
  const mat = new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, fog: false });
  const band = new THREE.Mesh(new THREE.PlaneGeometry(17, 9).rotateX(-Math.PI / 2), mat);
  const wall = new THREE.Mesh(new THREE.PlaneGeometry(17, 3.2), mat.clone());
  wall.material.opacity = 0.4;
  wall.position.y = 1.6;
  const grp = new THREE.Group(); grp.add(band, wall); grp.visible = false;
  scene.add(grp);
  let s = 0, active = false;
  return {
    start(_unused, front) { s = front; active = true; grp.visible = true; grp.position.set(0, 0.06, -s); },
    update(dt) {
      if (!active) return;
      s -= TUNE.releaseWaveSpeed * dt;
      grp.position.z = -s;
      const pulse = 0.8 + Math.sin(G.realTime * 18) * 0.2;
      wall.material.opacity = 0.38 * pulse;
      if (s < G.tailS - 20) { active = false; grp.visible = false; }
    },
    stop() { active = false; grp.visible = false; },
  };
})();

// ───────────────────────────── 이벤트 연결
boss.onPop = (v, p) => {
  hud.popAt(p.clone().setY(1.6), '펑크!', 'crit');
  ui.flash('#ffffff', 60);
};
boss.onGone = (v) => {
  if (v.isLast) {
    ui.banner('원인 제거!', 'big', 1500);
    G.releaseAt = G.realTime + 0.95; // 반짝★을 잠깐 감상한 뒤 드론샷으로
  }
};
traffic.onReleased = (c) => {
  if (Math.random() < 0.28 && bubbles.size < 8 && G.phase === 'release') {
    const line = THANKS_LINES[Math.floor(Math.random() * THANKS_LINES.length)];
    bubble('c' + c.id, line, 'thanks', 1.7, carTop(c, 0.8));
  }
  if (Math.random() < 0.18) fx.hearts(c.mesh.position.clone().setY((c.mesh.userData.height || 1.6) + 0.6));
  if (Math.random() < 0.06) audio.play('blink', { volume: 0.4 });
};
traffic.onCheater = (c) => {
  if (G.phase !== 'jam') return;
  bubble('cheat' + c.id, '갓길 얌체 끼어들기!', 'angry', 1.6, carTop(c, 0.8));
  addRage(TUNE.cutinRage);
  audio.play('cutin');
  if (!G.cheaterHinted) { G.cheaterHinted = true; ui.hint?.('갓길 얌체! 경적 울리면 제자리(4차선)로 돌아갑니다', 2800); }
};

function addRage(a) {
  const before = G.rage;
  G.rage = Math.min(1, G.rage + a);
  const seg = (r) => Math.floor(r * TUNE.rageSegs + 1e-6);
  if (seg(G.rage) > seg(before)) {
    audio.play('rageFull', { volume: 0.7 });
    const sp = project(player.mesh.position.clone().setY(2.6));
    if (sp) ui.popText(sp.x, sp.y, G.rage >= 0.999 ? '분노 MAX!!' : '분노 충전!', 'crit');
  }
}

// ───────────────────────────── 상점 장착 상태
const ITEM = Object.fromEntries(SHOP.map((it) => [it.id, it]));
const owns = (id) => (ITEM[id] && ITEM[id].price === 0) || (G.progress.owned || []).includes(id);
const equipped = (cat) => ITEM[G.progress.equip?.[cat]] || ITEM[SHOP_DEFAULT[cat]];
function onBuy(id) {
  const it = ITEM[id]; const p = G.progress;
  if (!it || owns(id)) return;
  if ((p.wallet || 0) < it.price) { audio.play('warn'); return; }
  p.wallet -= it.price;
  (p.owned ||= []).push(id);
  if (['car', 'weapon', 'finish'].includes(it.cat)) (p.equip ||= {})[it.cat] = id;
  saveProgress();
  audio.play('stageClear');
  ui.refreshShop?.(p);
}
function onEquip(id) {
  const it = ITEM[id]; const p = G.progress;
  if (!it || !owns(id) || !['car', 'weapon', 'finish'].includes(it.cat)) return;
  (p.equip ||= {})[it.cat] = id;
  saveProgress();
  audio.play('ui');
  ui.refreshShop?.(p);
}

// 잔챙이 빌런 행동 (꽁초·쓰레기 투척 / 갓길 칼치기)
traffic.onMiniAct = (c, type) => {
  if (!['jam', 'boss'].includes(G.phase)) return;
  const T = MINI_TYPES[type];
  bubble('mini' + c.id, T.lines[Math.floor(Math.random() * T.lines.length)], 'taunt', 1.4, carTop(c, 1.6));
  if (T.item) boss.throwFrom({ x: c.x, h: c.mesh.userData.height || 1.6, s: c.s }, player.lane, player, T.item);
  else { addRage(TUNE.cutinRage); audio.play('cutin'); }
  if (!G.miniHinted) { G.miniHinted = true; ui.hint?.(IS_TOUCH ? '주황 표식 = 잔챙이 빌런! 가까이서 [발사] 꾹 → 참교육 (★미션)' : '주황 표식 = 잔챙이 빌런! 가까이서 Space 꾹 → 압정 참교육 (★미션)', 3200); }
};
function onMiniHit(c, dmg, pos) {
  const r = traffic.miniHit(c, dmg);
  if (!r) return;
  fx.hitFlash(pos);
  fx.sparks(pos, { count: 6, speed: 5 });
  hud.popAt(pos, `-${dmg}`, 'hit');
  G.combo++; G.maxCombo = Math.max(G.maxCombo, G.combo);
  if (r === 'down') {
    const T = MINI_TYPES[c.mini.type];
    G.minisDone++; G.miniFines += T.fine; G.score += 400;
    audio.play('pop');
    fx.debris(c.mesh.position.clone().setY(1), [0xff9a1a, 0xffffff, 0x222222], 10);
    fx.shake(0.3, 0.2);
    bubble('mini' + c.id, T.sorry[Math.floor(Math.random() * T.sorry.length)], 'thanks', 1.6, carTop(c, 0.8));
    hud.popAt(c.mesh.position.clone().setY(3.2), `${T.name} 참교육! +${(T.fine / 10000).toFixed(0)}만원`, 'score');
  }
}

// 분노의 경적 (정체 구간 R): 갓길 앞을 싹 쓸고 2초 가속
function rageHorn() {
  if (G.rage < TUNE.superCost - 1e-6) { hud.popAt(player.mesh.position.clone().setY(2.6), '분노 부족!', 'warn'); return; }
  G.rage = Math.max(0, G.rage - TUNE.superCost);
  G.rageHorns++;
  audio.play('hornTruck', { volume: 1 });
  audio.play('superHit', { volume: 0.55 });
  fx.shake(0.75, 0.5);
  ui.flash('#ffd23a', 120);
  ui.banner('분노의 경적!!', 'warn', 900);
  for (let i = 0; i < 4; i++) fx.shockwave(new THREE.Vector3(laneX(SHOULDER_LANE) - 1.2, 0.1, -(player.s + 6 + i * 10)), 9 + i * 2.5, 0xffd23a);
  const r = traffic.rageHorn(player, TUNE.rageHornRange);
  for (const o of r.smashed) flingObstacle(o, false);
  for (const o of r.towed) flingObstacle(o, true);
  for (const c of r.cheaters) { bubble('rh' + c.id, CHEATER_LINES[Math.floor(Math.random() * CHEATER_LINES.length)], 'thanks', 1.4, carTop(c, 0.8)); G.cheaters++; G.score += 300; }
  for (const c of r.startled.slice(0, 4)) bubble('st' + c.id, ['깜짝이야!', '헉!', '고막…', '무슨 소리야?!'][Math.floor(Math.random() * 4)], 'angry', 1.2, carTop(c, 0.8));
  player.boostT = TUNE.boostTime;
}
// 보스·엘리트 페이즈 전환 연출
function onBossPhase(e) {
  G.hitstop = Math.max(G.hitstop, 0.12);
  fx.shake(0.6, 0.4);
  ui.flash('#ff6b3d', 120);
  ui.banner(`${e.idx + 1}페이즈! ${e.label}`, 'boss', 1300);
  audio.play('hornAngry', { volume: 0.8 });
  const v = boss.alive[0];
  if (v) v.taunt = { text: ['이제부터 진짜다!', '어디 한번 해보자고!', '동생들 집합!'][e.idx % 3], until: G.time + 2 };
}

// 구조형 스테이지의 경적: 원흉을 깨운다(게이지 감소), 분노 = 사이렌 대경적
const RESCUE_POPS = ['빵! 정신 차려요!', '비상등 켜세요!', '갓길로 빼요!', '빵빵!', '괜찮아요?!'];
function rescueHonk(dt, fire, superFire) {
  G.honkCool = Math.max(0, (G.honkCool || 0) - dt);
  const tgt = boss.alive.filter((v) => Math.abs(v.s - player.s) < 45).sort((a, b) => Math.abs(a.s - player.s) - Math.abs(b.s - player.s))[0];
  if (superFire) {
    if (G.rage < TUNE.superCost - 1e-6) { hud.popAt(player.mesh.position.clone().setY(2.6), '분노 부족!', 'warn'); return; }
    if (!tgt) return;
    G.rage = Math.max(0, G.rage - TUNE.superCost); G.supers++;
    audio.play('hornTruck', { volume: 1 });
    fx.shockwave(new THREE.Vector3(tgt.x, 0.1, -tgt.s), 12, 0xffd23a);
    onWeaponHit(tgt, TUNE.superDmg, new THREE.Vector3(tgt.x, tgt.h + 0.8, -tgt.s), 'super');
    return;
  }
  if (!fire || G.honkCool > 0 || !tgt) return;
  G.honkCool = 0.28;
  audio.play('horn', { volume: 0.6, pitch: 0.95 + Math.random() * 0.1 });
  fx.shockwave(new THREE.Vector3(tgt.x, 0.1, -tgt.s), 4.5, 0xfff0c0);
  const pos = new THREE.Vector3(tgt.x, tgt.h + 0.8, -tgt.s);
  onWeaponHit(tgt, TUNE.tackDmg * 1.6, pos, 'honk');
  if (Math.random() < 0.25) hud.popAt(pos.clone().setY(tgt.h + 2.2), RESCUE_POPS[Math.floor(Math.random() * RESCUE_POPS.length)], 'score');
}

// 장애물 날려버리기 (분노의 경적 / 레커차 견인)
function flingObstacle(o, towed) {
  o.mesh.updateMatrixWorld(true);
  for (const ch of [...o.mesh.children]) {
    scene.attach(ch);
    boss.debris.push({
      obj: ch, bounce: !towed, life: towed ? 1.6 : 2.4,
      vel: towed ? new THREE.Vector3(9 + Math.random() * 3, 7, -(3 + Math.random() * 3)) : new THREE.Vector3((Math.random() - 0.2) * 7, 8 + Math.random() * 7, -(6 + Math.random() * 8)),
      spin: towed ? new THREE.Vector3(0.5, 3, 1.5) : new THREE.Vector3(Math.random() * 12, Math.random() * 8, Math.random() * 12),
    });
  }
  scene.remove(o.mesh);
  hud.popAt(new THREE.Vector3(o.x, 2.5, -o.s), towed ? '견인 완료!' : '싹~', 'score');
  G.score += towed ? 150 : 50;
}

// ───────────────────────────── UI
initUI({
  onStartStage: (i) => { audio.init(); audio.play('uiConfirm'); startStage(i); },
  onNext: () => { audio.play('uiConfirm'); const n = G.stageIdx + 1; if (n < STAGES.length) startStage(n); else goTitle(); },
  onRetry: () => { audio.play('uiConfirm'); startStage(G.stageIdx); },
  onMenu: () => { audio.play('ui'); goTitle(); },
  onToggleMute: () => toggleMute(),
  onPause: () => setPaused(!G.paused),
  onBuy: (id) => onBuy(id),
  onEquip: (id) => onEquip(id),
  onControl: (name, pressed) => {
    audio.init();
    if (name === 'pause') { if (pressed) setPaused(!G.paused); return; }
    input.control(name, pressed);
  },
});

function toggleMute() {
  audio.init();
  audio.setMuted(!audio.isMuted());
  ui.setMuted(audio.isMuted());
}
function setPaused(p) {
  if (!['jam', 'boss'].includes(G.phase)) p = false;
  G.paused = p;
  ui.setPausedVisible(p);
  input.reset();
}
document.addEventListener('visibilitychange', () => { if (document.hidden) setPaused(true); });
const unlockAudio = () => audio.init();
window.addEventListener('pointerdown', unlockAudio, true);
window.addEventListener('keydown', unlockAudio, true);

// ───────────────────────────── 스테이지 구성
function setupStage(stage) {
  clearBubbles();
  releaseWave.stop();
  fx.clear();
  weapons.reset();
  const startS = 0;
  const frontS = startS + stage.jamLength + 30;
  G.startS = startS; G.frontS = frontS;
  world.build(stage, startS - 160, frontS + 950, { startS, frontS });
  const night = !!world.night;
  boss.spawn(stage, frontS);
  const rng = mulberry32(stage.id * 1000 + 7);
  traffic.spawnJam(stage, boss.villains, { s: startS, lane: 3 }, rng, night);
  G.tailS = traffic.sTail;
  player.reset(startS, 3);
  setHeadlights(player.mesh, night);
  for (const v of boss.villains) setHeadlights(v.mesh, night);
  // 사실 기반 대수: 정체 길이(km) × 차로 수 × 정체 밀도(대/km/차로). docs/FEEDBACK_LOG.md 근거
  G.displayCars = Math.round(stage.displayKm * NUM_LANES * TUNE.jamDensity);
  G.mult = G.displayCars / Math.max(1, traffic.cars.length);
  G.rage = 0; G.score = 0; G.combo = 0; G.maxCombo = 0; G.bumps = 0; G.supers = 0; G.hits = 0;
  G.hitsTaken = 0; G.minisDone = 0; G.miniFines = 0; G.rageHorns = 0; G.airbag = 0;
  G.minisTotal = traffic.cars.filter((c) => c.mini).length;
  G.frontLocked = false; G.jumpCool = 0; G.droneT = 0;
  // 장착 아이템 적용
  const car = equipped('car');
  player.setKind?.(car.kind, night);
  player.stats = { speed: 1, armor: 0, ...(car.stats || {}) };
  player.armorLeft = player.stats.armor || 0;
  G.airbag = owns('pas_airbag') ? 3 : 0;
  weapons.setWeapon(equipped('weapon'));
  boss.finishStyle = (equipped('finish').id || 'fin_rocket').replace('fin_', '');
  if (owns('pas_coffee')) G.rage = TUNE.superCost;
  setDrone(owns('mv_drone'));
  G.releaseShown = 0;
  G.releaseAt = 0;
  G.cheaters = 0;
}

function startStage(idx) {
  G.stageIdx = idx;
  G.stage = STAGES[idx];
  G.paused = false;
  ui.setPausedVisible(false);
  ui.hideTitle();
  ui.hideResult();
  ui.hideBoss();
  ui.setReleaseCounter(null);
  setupStage(G.stage);
  enterPhase('intro');
}

function goTitle() {
  ui.hideResult();
  ui.hideBoss();
  ui.setReleaseCounter(null);
  ui.setTouchVisible(false);
  G.stageIdx = Math.min(G.progress.unlocked - 1, STAGES.length - 1);
  G.stage = STAGES[0];
  setupStage(G.stage);
  enterPhase('title');
}

// ───────────────────────────── 페이즈 전환
function enterPhase(name) {
  G.phase = name;
  G.phaseT = 0;
  G.phaseReal = 0;
  const stage = G.stage;
  switch (name) {
    case 'title': {
      ui.showTitle(STAGES, G.progress, CHAPTERS, SHOP);
      audio.startMusic('menu');
      audio.startAmbience(null);
      fx.speedLines(0);
      break;
    }
    case 'intro': {
      G.introStage = 0; G.introT2 = 0;
      ui.setTouchVisible(false);
      audio.startMusic('jam');
      audio.startAmbience('jam');
      fx.speedLines(0);
      const v0 = boss.villains[0];
      v0.taunt = { text: stage.villainLine.replace(/"/g, ''), until: G.time + 3.2 };
      ui.showStageCard(stage, stageMissions()).then(() => { if (G.phase === 'intro') { G.introStage = 1; G.introT2 = 0; } });
      break;
    }
    case 'jam': {
      G.stageStart = G.time;
      G.stuckHinted = false;
      ui.banner('출발!', 'go', 900);
      ui.setTouchVisible(IS_TOUCH);
      G.hasJump = owns('mv_jump');
      ui.setControls?.({ jump: G.hasJump });
      audio.play('go');
      G.cheaterHinted = G.stageIdx > 0;
      if (G.stageIdx === 0 || G.auto) {
        setTimeout(() => G.phase === 'jam' && ui.hint?.(IS_TOUCH ? '꽉 막혔다! ▶ 갓길로 빠져서 원인을 찾아라 (긴급차량)' : '꽉 막혔다! → 갓길로 빠져서 원인을 찾아라 (긴급차량)', 3400), 900);
        setTimeout(() => G.phase === 'jam' && ui.hint?.(IS_TOUCH ? '갓길이 막히면 [경적] → 4차선이 끼워줍니다' : '갓길이 막히면 Space(경적) → 4차선이 끼워줍니다', 3200), 5200);
      }
      break;
    }
    case 'boss': {
      G.bossStart = G.time;
      boss.attackT = 2.0;
      const names = boss.villains.map((v) => v.name).join(' & ');
      ui.banner(G.stage.honkOnly ? '원인 발견! 구조 출동!' : '원인 발견!', 'boss', 1300);
      G.frontLocked = false;
      ui.showBoss({ name: names, hp: 1, tires: 4 });
      audio.startMusic('boss');
      audio.play('warn');
      const hint = G.stage.honkOnly
        ? (IS_TOUCH ? '구조 상황! 압정 금지 · [발사] = 경적으로 깨우기 → 갓길로 유도' : '구조 상황! 압정 금지 · Space = 경적으로 깨우기 → 갓길로 유도')
        : (IS_TOUCH ? '[발사] 꾹 = 화물차 너머로 압정 선제공격 · 갓길로 앞질러 정면 참교육!' : 'Space 꾹 = 화물차 너머로 압정 선제공격 · 갓길로 앞질러 정면 참교육!');
      setTimeout(() => G.phase === 'boss' && !G.frontLocked && ui.hint?.(hint, 3600), 1500);
      audio.play('hornAngry', { volume: 0.5 });
      // 벽 차량들 짜증 경적
      for (const c of traffic.carsBehindFront(5)) bubble('w' + c.id, FRONT_RAGE_LINES[Math.floor(Math.random() * FRONT_RAGE_LINES.length)], 'angry', 1.8, carTop(c, 0.8));
      break;
    }
    case 'kill': {
      G.killTime = G.time;
      G.hitstop = 0.16;
      G.slowUntil = G.realTime + 1.25;
      G.slowScale = 0.28;
      ui.flash('#ffffff', 160);
      ui.hideBoss();
      fx.shake(1.1, 0.6);
      audio.duck(0.75, 2.6);
      audio.play('superHit');
      ui.setTouchVisible(false);
      clearBubbles();
      G.killS = G.killVillain.s;
      G.photoAt = G.realTime + 0.45; // 폭발+슬로모 순간을 블박 캡처
      G.photo = null;
      break;
    }
    case 'release': {
      traffic.release(G.time);
      world.setVMS('소통 원활\n1차선은 추월차선!', '#3dff7f');
      audio.cheerHorns();
      audio.startAmbience(null);
      setTimeout(() => { if (G.phase === 'release' || G.phase === 'cruise') audio.startMusic('release'); }, 600);
      ui.banner('1차선 개방!', 'go', 1100);
      setTimeout(() => (G.phase === 'release' || G.phase === 'cruise') && ui.banner('뻥 뚫렸다!!', 'big', 2400), 1250);
      ui.setReleaseCounter(0);
      fx.confetti(new THREE.Vector3(0, 0, -(G.killS - 30)), 220, 46);
      releaseWave.start(G.frontS + (G.time - 0) * 0, traffic.frontLine);
      fx.shake(0.5, 0.4);
      player.ghost = true;
      break;
    }
    case 'cruise': {
      fx.speedLines(0.85);
      audio.startAmbience('free');
      ui.banner('질주 타임!', 'go', 1000);
      break;
    }
    case 'result': {
      fx.speedLines(0.3);
      showResult();
      break;
    }
  }
}

function stageMissions() {
  const n = G.minisTotal || 0;
  return [
    { label: G.stage?.honkOnly ? '원인 해결 (구조 완료 · 압정 금지)' : '원인 제거 (참교육 완료)' },
    { label: '추돌·피격 합계 3회 이하' },
    { label: n ? `잔챙이 빌런 ${n}명 전원 참교육` : '잔챙이 빌런 없음 (자동 달성)' },
  ];
}

function showResult() {
  const stage = G.stage;
  const freed = Math.min(G.displayCars, Math.round(traffic.countReleased() * G.mult));
  const bossTime = Math.max(0, G.killTime - G.bossStart);
  const total = Math.max(0, G.killTime - G.stageStart);
  let cath = 70 + (G.bumps === 0 ? 12 : -Math.min(30, G.bumps * 5)) + (bossTime < 14 ? 10 : bossTime < 22 ? 4 : -4)
    + (G.supers > 0 ? 6 : 0) + Math.min(8, G.maxCombo / 5);
  cath = Math.max(12, Math.min(100, Math.round(cath)));
  // 별 = 명시적 미션 3개 (docs/SHOP.md)
  const missions = stageMissions().map((m, i) => ({ label: m.label, done: i === 0 ? true : i === 1 ? (G.bumps + G.hitsTaken) <= 3 : G.minisDone >= G.minisTotal }));
  const stars = missions.filter((m) => m.done).length;
  // 아낀 시간(사실 기반): 정체 통과(약 9km/h) − 정상 통과(100km/h) × 해방 대수
  const savedMin = (stage.displayKm / 9 - stage.displayKm / 100) * 60;
  const savedHours = Math.round((savedMin * freed) / 60);
  const score = Math.round(G.score + freed * 5 + cath * 40);
  const mm = Math.floor(total / 60), ss = Math.floor(total % 60);
  const p = G.progress;
  const reward = computeReward(stage, { stars, cath, freed, bumps: G.bumps, cheaters: G.cheaters || 0, miniFines: G.miniFines || 0, payMult: owns('pas_4k') ? 1.25 : 1 }, Math.floor(G.time * 1000) % 997 + 1);
  const { milestone } = applyReward(p, stage, reward, G.photo);
  p.unlocked = Math.min(STAGES.length, Math.max(p.unlocked, G.stageIdx + 2));
  p.stars[stage.id] = Math.max(p.stars[stage.id] || 0, stars);
  p.best[stage.id] = Math.max(p.best[stage.id] || 0, score);
  saveProgress();
  ui.showResult({
    stageName: `${stage.highway} · ${stage.direction}`,
    villainName: stage.villains.map((v) => v.name).join(' & '),
    stars, score,
    stats: [
      { label: '해방된 차량', value: `${freed.toLocaleString('ko-KR')}대` },
      { label: '근거', value: `${stage.displayKm}km×${NUM_LANES}차로×${TUNE.jamDensity}대/km` },
      { label: '아낀 시간 합계', value: `${savedHours.toLocaleString('ko-KR')}시간` },
      { label: '추돌+피격', value: `${G.bumps + G.hitsTaken}회` },
      { label: '잔챙이 참교육', value: `${G.minisDone}/${G.minisTotal}` },
      { label: '소요 시간', value: `${mm}:${String(ss).padStart(2, '0')}` },
      { label: '속시원함 지수', value: `${cath}%` },
    ],
    isLast: G.stageIdx >= STAGES.length - 1,
    missions,
    reward: { ...reward, photo: G.photo, wallet: p.wallet, subs: p.subs, milestone, stageId: stage.id, cause: stage.cause },
  });
  if (milestone) setTimeout(() => audio.play('stageClear'), 2600);
  audio.play('stageClear');
  missions.forEach((m, i) => m.done && setTimeout(() => audio.play('star', { pitch: 1 + i * 0.25 }), 700 + i * 380));
}

// ───────────────────────────── 전투 피격
function onWeaponHit(v, dmg, pos, kind, fromRear = false) {
  if (v && v.mini) return onMiniHit(v, dmg, pos);
  const r = boss.damage(v, dmg, pos, kind, fromRear);
  G.hits++;
  G.combo++;
  G.maxCombo = Math.max(G.maxCombo, G.combo);
  G.score += Math.round(dmg * 10 * (1 + G.combo * 0.05));
  if (kind === 'super') {
    G.hitstop = Math.max(G.hitstop, 0.07);
    fx.shake(0.8, 0.35);
    ui.flash('#ffe08a', 90);
    hud.popAt(pos, `분노 폭발! -${dmg}`, 'crit');
    audio.play('superHit');
  } else {
    if (G.hits % 2 === 0) audio.play('hit', { volume: 0.55, pitch: 0.9 + Math.random() * 0.3 });
    fx.hitFlash(pos);
    if (Math.random() < 0.5) fx.sparks(pos, { count: 5, speed: 5 });
    hud.popAt(pos, `-${Math.round(dmg * 10) / 10}`, 'hit');
    if (weapons.wpn.slow) boss.attackT += 0.25; // 물풍선: 앞유리 범벅 → 공격 지연
  }
  if (r.killed) {
    const isLast = !boss.anyAlive;
    if (isLast) {
      G.killVillain = v;
      boss.startDeath(v, true);
      enterPhase('kill');
    } else {
      boss.startDeath(v, false);
      ui.banner('1대 참교육!', 'warn', 1000);
      const other = boss.alive[0];
      if (other) other.taunt = { text: v.index === 0 ? '형님!!!' : '아우야!!!', until: G.time + 2 };
      fx.shake(0.7, 0.4);
    }
  }
}

function onPlayerHit(ev) {
  if (player.invuln > 0) return;
  G.hitsTaken++;
  if (ev.type === 'miniHit' || !G.frontLocked) {
    // 정체 구간(잔챙이 투척)·보스 뒤쪽: 살짝 휘청만
    player.invuln = 0.8; player.bumpKick = 1; player.v *= 0.5;
    G.combo = 0; addRage(TUNE.miniRage); fx.shake(0.4, 0.25); ui.flash('#ff3b30', 90); audio.play('bump');
    hud.popAt(player.mesh.position.clone().setY(2.4), ev.text || '으악!', 'bump');
    return;
  }
  // 정면전: 맞으면 앞으로 밀려나며 휘청 (빌런과의 간격은 자동 복귀)
  player.knock(-(ev.push || 2.5), 1);
  player.v = boss.refV() + 5;
  if (ev.flash) ui.flash('#fffbe0', 380);
  G.combo = 0;
  addRage(TUNE.hitRage);
  fx.shake(0.6, 0.35);
  ui.flash('#ff3b30', 110);
  audio.play('bump');
  hud.popAt(player.mesh.position.clone().setY(2.4), ev.text || '으악!', 'bump');
  G.score = Math.max(0, G.score - 50);
}

// 블박 드론 (상점): 플레이어 위를 따라다니며 잔챙이·원흉에게 자동 투척
let drone = null;
function setDrone(on) {
  if (drone) { scene.remove(drone); drone = null; }
  if (!on) return;
  try { drone = VEH.buildFxProp ? VEH.buildFxProp('drone') : null; } catch { drone = null; }
  if (!drone) { drone = new THREE.Mesh(new THREE.BoxGeometry(1, 0.25, 1), new THREE.MeshLambertMaterial({ color: 0xffffff })); drone.userData = {}; }
  scene.add(drone);
}
function updateDrone(dt, jamLike, miniT) {
  if (!drone) return;
  const t = G.realTime;
  drone.position.set(player.x - 1.5 + Math.sin(t * 1.3) * 0.6, 5.2 + Math.sin(t * 2.1) * 0.3, -(player.s + 2));
  for (const r of drone.userData.rotors || []) r.rotation.y += dt * 40;
  G.droneT -= dt;
  if (G.droneT > 0 || !['jam', 'boss'].includes(G.phase)) return;
  const tgt = miniT || (G.phase === 'boss' ? boss.targetFor(player) || boss.alive[0] : null);
  if (!tgt) return;
  G.droneT = 0.7;
  const save = { x: player.x, hop: player.hop };
  player.hop = 3.4; // 드론 위치에서 던지는 것처럼 (총구 높이만 빌림)
  weapons.fireAt(player, tgt);
  player.hop = save.hop;
}

// 콘·낙하물 날려버리기: 조각들이 하늘로 튀고(파편 물리는 boss.debris 재사용) 점수 소폭
function onSmash(o) {
  const r = traffic.smash(o);
  if (!r) return;
  for (const pc of r.pieces) {
    scene.attach(pc.obj);
    boss.debris.push({
      obj: pc.obj, bounce: true, life: 2.2,
      vel: new THREE.Vector3((Math.random() - 0.3) * 6, 6 + Math.random() * 6, -(player.v + 4 + Math.random() * 6)),
      spin: new THREE.Vector3(Math.random() * 12, Math.random() * 8, Math.random() * 12),
    });
  }
  scene.remove(r.group);
  fx.debris(new THREE.Vector3(player.x, 0.6, -(player.s + player.len / 2)), o.kind === 'cones' ? [0xff7a1a, 0xffffff] : [0xc8955a, 0x24262a], 10);
  fx.shake(0.25, 0.2);
  audio.play('bump', { volume: 0.6 });
  G.score += 50;
  hud.popAt(player.mesh.position.clone().setY(2.4), o.kind === 'cones' ? '콘 날리기!' : '낙하물 치움!', 'score');
  addRage(TUNE.smashRage);
}

function onBump(other) {
  // 1톤 포터 장갑 / 에어백: 추돌을 흡수
  if (player.armorLeft > 0) { player.armorLeft--; hud.popAt(player.mesh.position.clone().setY(2.4), '튼튼!', 'score'); audio.play('bump', { volume: 0.4 }); traffic.jolt?.(other); return; }
  if (G.airbag > 0) { G.airbag--; hud.popAt(player.mesh.position.clone().setY(2.4), '에어백!', 'score'); audio.play('bump', { volume: 0.4 }); traffic.jolt?.(other); return; }
  G.bumps++;
  G.combo = 0;
  addRage(TUNE.bumpRage);
  fx.shake(0.45, 0.25);
  const cp = new THREE.Vector3(player.x, 0.8, -(player.s + player.len / 2));
  fx.sparks(cp, { count: 8, speed: 5 });
  audio.play('bump');
  if (Math.random() < 0.6) audio.play('hornAngry', { volume: 0.6, pan: (other.x - player.x) / 8 });
  hud.popAt(cp.clone().setY(2.2), '쿵!', 'bump');
  traffic.jolt?.(other);
  if (G.realTime - G.lastBumpBubble > 1.2 && other.mesh) {
    G.lastBumpBubble = G.realTime;
    bubble('b' + (other.id || 0), BUMP_LINES[Math.floor(Math.random() * BUMP_LINES.length)], 'angry', 1.4, carTop(other, 0.8));
  }
}

// ───────────────────────────── 오토파일럿 (자동 플레이테스트 / 데모)
let autoNext = 0;
function autopilot(phase) {
  const out = { left: false, right: false, fire: false, super: false, brake: false, horn: false };
  if (G.realTime < autoNext) { out.fire = phase === 'boss'; return out; }
  if (phase === 'jam' || (phase === 'boss' && !G.frontLocked)) {
    if (traffic.miniTarget(player) || (phase === 'boss' && boss.targetFor(player))) out.fire = true;
    if (G.rage >= TUNE.superCost * 2 && traffic.gapAhead(SHOULDER_LANE, player.s, player).gap < 20 && Math.random() < 0.05) out.super = true;
    // 전략: 갓길로 빠져서 달리고, 갓길이 막히면 경적 → 4차선으로 잠깐 끼었다가 다시 갓길
    const SL = SHOULDER_LANE;
    const front = player.s + player.len / 2;
    const free = (l) => l >= 0 && l <= SL && !traffic.canMergeInto(l, player, 0.5);
    if (player.lane < SL) {
      if (free(player.lane + 1)) { out.right = true; autoNext = G.realTime + 0.22; }
      else { out.horn = true; autoNext = G.realTime + 0.3; }
    } else {
      const { gap, who } = traffic.gapAhead(SL, front, player);
      if (who && gap < 16 && !who.smash) {
        out.horn = true;
        if (gap < 7 && !who.isCheater && free(SL - 1)) { out.left = true; autoNext = G.realTime + 0.3; }
      }
    }
    // 4차선으로 끼어 있는데 갓길이 비었으면 복귀
    if (player.lane === SL - 1 && free(SL)) {
      const { gap } = traffic.gapAhead(SL, player.s - player.len / 2 - 1, player);
      if (gap > 8) { out.right = true; out.left = false; autoNext = G.realTime + 0.25; }
    }
  } else if (phase === 'cruise') {
    const L = traffic.leaderOf(player);
    if (L && L.gap < 14) {
      for (const d of [-1, 1]) {
        const l = player.lane + d;
        if (l < 0 || l >= NUM_LANES) continue;
        if (!traffic.laneBlocked(l, player.s - player.len / 2 - 1, player.s + player.len / 2 + 6, player)) { out[d < 0 ? 'left' : 'right'] = true; autoNext = G.realTime + 0.4; break; }
      }
    }
  } else if (phase === 'boss') {
    out.fire = true;
    const danger = boss.dangerLanes(player);
    const v = boss.alive[0];
    let want = player.lane;
    if (v) {
      const vl = Math.round(v.lanePos);
      const pref = [vl + 1, vl - 1, vl, vl + 2, vl - 2].filter((l) => l >= 0 && l <= SHOULDER_LANE && !danger.has(l));
      if (pref.length) want = pref[0];
    }
    if (danger.has(player.lane)) {
      const safe = [player.lane - 1, player.lane + 1].filter((l) => l >= 0 && l <= SHOULDER_LANE && !danger.has(l));
      if (safe.length) want = safe[0];
    }
    if (want !== player.lane) { out[want < player.lane ? 'left' : 'right'] = true; autoNext = G.realTime + 0.25; }
    if (G.rage >= TUNE.superCost && Math.random() < 0.02) out.super = true;
  }
  return out;
}

// ───────────────────────────── 카메라
const camPos = new THREE.Vector3(0, 30, 40), camLook = new THREE.Vector3();
const tPos = new THREE.Vector3(), tLook = new THREE.Vector3();
const A = new THREE.Vector3(), AL = new THREE.Vector3();
let fovTarget = 42;
const portrait = () => innerHeight > innerWidth * 1.05;

function chaseTarget(outPos, outLook, cruise = false) {
  const por = portrait();
  // 플레이어가 화면 하단 1/3 지점에 오도록: 카메라는 뒤·위, 시선은 차 앞 약간
  const H = por ? 21 : (cruise ? 10.5 : 12.5);
  const D = por ? 17 : (cruise ? 15 : 16);
  const L = por ? 9 : (cruise ? 14 : 11);
  outPos.set(player.x * 0.45 + (por ? 1.0 : 2.4), H, -player.s + D);
  outLook.set(player.x * 0.6, 0.4, -player.s - L);
}

function updateCamera(realDt) {
  const por = portrait();
  let k = 6;
  switch (G.phase) {
    case 'title': {
      const span = Math.max(60, G.frontS - G.startS);
      const t = (G.phaseReal * 4.5) % (span + 40);
      const s = G.startS - 20 + t;
      tPos.set(16, por ? 34 : 24, -s + 8);
      tLook.set(-1, 0, -(s + 36));
      k = 2;
      break;
    }
    case 'intro': {
      const v = boss.villains[0].mesh.position;
      const sway = Math.sin(G.phaseReal * 0.6) * 1.5;
      A.set(v.x + 6.5 + sway, 4.2, v.z - 13);
      AL.set(v.x - 0.5, 1.3, v.z + 3);
      if (G.introStage === 0) {
        tPos.copy(A); tLook.copy(AL);
        if (G.phaseReal < 0.05) { camPos.copy(A); camLook.copy(AL); }
        k = 8;
      } else {
        const e0 = Math.min(1, G.introT2 / 2.0);
        const e = e0 * e0 * (3 - 2 * e0);
        chaseTarget(tPos, tLook);
        tPos.lerpVectors(A, tPos, e);
        tPos.y += Math.sin(Math.PI * e) * 22;
        tLook.lerpVectors(AL, tLook, e);
        camPos.copy(tPos); camLook.copy(tLook);
        k = 50;
      }
      break;
    }
    case 'jam':
      chaseTarget(tPos, tLook);
      break;
    case 'boss': {
      if (!G.frontLocked) {
        // 뒤에서 접근 중: 추격 카메라인데 시선을 원흉 쪽으로 당김
        chaseTarget(tPos, tLook);
        const rv = boss.alive[0] || boss.villains[0];
        tLook.x = tLook.x * 0.5 + rv.x * 0.5;
        tLook.z = Math.min(tLook.z, -(player.s + 16));
        tPos.y += 2;
        k = 4;
        break;
      }
      // 정면전 카메라: 빌런 줄 뒤·위에서 앞(플레이어)을 본다 → 빌런이 전경, 플레이어가 그 앞
      const ref = boss.alive[0] || boss.villains[0];
      const vs = ref.baseS ?? ref.s;
      // 높고 가운데서: 키 큰 앞줄 화물차가 빌런을 가리지 않게
      const cx = (ref.x + player.x) / 2;
      // 빌런 = 화면 중하단, 플레이어(11m 앞) = 중상단 이 되도록 (H=19, 뒤 8m, 시선은 빌런 6m 앞)
      tPos.set(cx + (por ? 0.6 : 1.4), por ? 27 : 19, -vs + (por ? 11 : 8));
      tLook.set(cx * 0.9, 0.3, -(vs + 6));
      k = 4;
      break;
    }
    case 'kill': {
      // 앞줄(화물차·버스)이 빌런 옆에 붙어 있으니, 그 반대편(분리대 쪽)에서 높게 돈다
      const vp = G.killVillain.mesh.position;
      const wallX = traffic.cars.filter((c) => c.isWall).reduce((a, c, _, arr) => a + c.x / arr.length, 0) || vp.x + 4;
      const side = vp.x <= wallX ? -1 : 1;
      const ang = -0.9 + G.phaseReal * 0.5;             // 앞쪽 → 옆 → 뒤쪽으로 쓸고 지나감
      const r = por ? 16 : 13;
      tPos.set(vp.x + side * Math.cos(ang) * r, Math.max(7.5, vp.y * 0.55 + 8), vp.z - Math.sin(ang) * r);
      tLook.copy(vp);
      if (G.killVillain.vel) tLook.addScaledVector(G.killVillain.vel, 0.12);
      k = 7;
      break;
    }
    case 'release': {
      const t = G.phaseT;
      tPos.set(13 + t * 1.2, (por ? 44 : 30) + t * 2.2, -(G.killS + 26 + t * 13));
      tLook.set(-2, 0, -(G.killS - 85 + t * 12));
      k = G.phaseReal < 0.4 ? 3 : 2.2;
      break;
    }
    case 'cruise':
    case 'result':
      chaseTarget(tPos, tLook, true);
      k = G.phase === 'cruise' && G.phaseReal < 1.2 ? 2.2 : 5;
      break;
    default:
      chaseTarget(tPos, tLook);
  }
  const a = 1 - Math.exp(-k * realDt);
  camPos.lerp(tPos, a);
  camLook.lerp(tLook, a);
  camera.position.copy(camPos).add(fx.shakeOffset);
  camera.lookAt(camLook);

  fovTarget = por ? 56 : 42;
  if (G.phase === 'boss') fovTarget = por ? 58 : 46;
  if (G.phase === 'cruise') fovTarget = (por ? 62 : 52) + Math.min(8, player.v * 0.15);
  if (G.phase === 'release') fovTarget = por ? 60 : 50;
  camera.fov += (fovTarget - camera.fov) * (1 - Math.exp(-3 * realDt));
  camera.updateProjectionMatrix();
}

// ───────────────────────────── 메인 업데이트
function update(realDt) {
  G.realTime += realDt;
  // 히트스톱 / 슬로모션
  let ts = 1;
  if (G.hitstop > 0) { G.hitstop -= realDt; ts = 0; }
  else if (G.realTime < G.slowUntil) ts = G.slowScale;
  if (G.paused) ts = 0;
  const dt = realDt * ts;
  G.time += dt;
  G.phaseT += dt;
  G.phaseReal += G.paused ? 0 : realDt;
  if (G.phase === 'intro' && G.introStage === 1) G.introT2 += realDt;

  // 시스템 키
  if (input.consume('mute')) toggleMute();
  if (input.consume('pause')) setPaused(!G.paused);
  if (G.paused) { input.endFrame(); return; }

  const ph = G.phase;
  // 정체처럼 움직이는 상태: 정체 구간 + 보스 발견 후 아직 앞을 못 막았을 때(뒤에서 접근 중)
  const jamLike = ph === 'jam' || (ph === 'boss' && !G.frontLocked);
  const ai = G.auto ? autopilot(ph) : null;
  const wantLeft = input.consume('left') || (ai && ai.left);
  const wantRight = input.consume('right') || (ai && ai.right);
  const wantBrake = input.isDown('brake') || (ai && ai.brake);
  const wantFire = input.isDown('fire') || (ai && ai.fire);
  const wantSuper = input.consume('super') || (ai && ai.super);
  const wantJump = input.consume('jump') || (ai && ai.jump);
  // 정체 중 발사 버튼: 사거리 안에 잔챙이 빌런이 있으면 압정, 없으면 경적
  const miniT = jamLike ? traffic.miniTarget(player) : null;
  const bossBehindT = ph === 'boss' && !G.frontLocked ? boss.targetFor(player) : null;
  const firePressed = input.consume('fire');
  const wantHorn = input.consume('horn') || (ph === 'jam' && firePressed && !miniT) || (ai && ai.horn);

  // 확인 키 (타이틀/결과)
  if (input.consume('confirm')) {
    if (ph === 'title') { audio.init(); startStage(Math.min(G.progress.unlocked - 1, STAGES.length - 1)); }
    else if (ph === 'result') { const n = G.stageIdx + 1; if (n < STAGES.length) startStage(n); else goTitle(); }
  }

  // 차선 변경
  if ((ph === 'jam' || ph === 'boss' || ph === 'cruise') && (wantLeft || wantRight)) {
    const r = player.requestLane(wantLeft ? -1 : 1, traffic);
    if (r === 'ok') audio.play('laneChange', { volume: 0.5 });
    else if (r && r.blocked) {
      const b = r.blocked;
      if (b.mesh && !b.isPlayer) {
        audio.play('hornShort', { volume: 0.5, pan: wantLeft ? -0.5 : 0.5 });
        if (G.realTime - G.lastBumpBubble > 0.8) { G.lastBumpBubble = G.realTime; bubble('lc' + (b.id || 'v'), '어딜 끼어들어!', 'angry', 1.1, carTop(b, 0.8)); }
      }
    }
  }
  if (wantHorn && G.realTime - G.lastHorn > 0.3 && (ph === 'jam' || ph === 'boss')) {
    G.lastHorn = G.realTime;
    audio.play('horn', { volume: 0.7 });
    hud.popAt(player.mesh.position.clone().setY(2.6), '빵!', 'warn');
    // 보스전 경적: 원흉은 절대 안 비킨다 (참교육의 명분)
    if (ph === 'boss' && G.frontLocked && boss.alive[0] && Math.random() < 0.7) boss.alive[0].taunt = { text: ['왜 빵빵거려?', '빵빵해도 안 비켜~', '내 차선인데?'][Math.floor(Math.random() * 3)], until: G.time + 1.6 };
    // 경적 → 앞 차가 비켜준다 (원흉은 절대 안 비킴)
    if (jamLike) {
      const r = traffic.honk(player, { siren: !!player.stats?.siren, trot: owns('pas_trot') });
      if (r && r.car && r.car.mesh) {
        const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
        const key = 'h' + (r.car.id || 'v');
        if (r.kind === 'cheater') {
          bubble(key, pick(CHEATER_LINES), 'thanks', 1.4, carTop(r.car, 0.8));
          G.score += 300; G.cheaters = (G.cheaters || 0) + 1;
          hud.popAt(r.car.mesh.position.clone().setY(2.6), '얌체 참교육 +300', 'score');
          audio.play('star', { pitch: 1.3 });
        } else if (r.kind === 'yield') bubble(key, pick(YIELD_LINES), 'thanks', 1.2, carTop(r.car, 0.8));
        else if (r.kind === 'letin') bubble(key, pick(LETIN_LINES), 'thanks', 1.2, carTop(r.car, 0.8));
        else if (r.kind === 'noway') { bubble(key, pick(NOWAY_LINES), 'angry', 1.1, carTop(r.car, 0.8)); addRage(TUNE.nowayRage); }
      }
    }
  }

  // 참교육 점프 (상점 아이템)
  G.jumpCool = Math.max(0, (G.jumpCool || 0) - dt);
  if (G.hasJump) ui.setControls?.({ jumpCd: G.jumpCool / 4 });
  if (wantJump && jamLike && owns('mv_jump') && G.jumpCool <= 0 && player.jump?.()) {
    G.jumpCool = 4; audio.play('whoosh', { pitch: 1.3 });
    hud.popAt(player.mesh.position.clone().setY(3), '참교육 점프!', 'score');
  }
  // 분노 사용: 정체(·보스 뒤쪽) = 분노의 경적 / 정면전 = 분노 폭탄(무기 쪽에서 처리)
  if (wantSuper && jamLike) rageHorn();
  // 잔챙이 압정 (정체 구간)
  if (jamLike && wantFire && miniT && !bossBehindT) weapons.tryFireAt(player, miniT);

  // 플레이어
  let pmode = 'idle', cruiseV = 0;
  if (ph === 'jam') pmode = 'jam';
  else if (ph === 'boss') pmode = G.frontLocked ? 'boss' : 'jam';
  else if (ph === 'kill') { pmode = 'idle'; cruiseV = boss.refV(); }
  else if (ph === 'release') { pmode = 'cruise'; cruiseV = G.phaseT > 0.8 ? 27 : boss.refV(); }
  else if (ph === 'cruise') { pmode = 'cruise'; cruiseV = TUNE.cruiseSpeed; }   // 제한속도 110km/h
  else if (ph === 'result') { pmode = 'cruise'; cruiseV = Math.max(0, 22 - G.phaseReal * 6); }
  else if (ph === 'intro') { pmode = 'idle'; cruiseV = 0; }
  const pev = player.update(dt, {
    mode: pmode, traffic, brake: wantBrake, cruiseV, boostT: player.boostT,
    bossRefS: boss.refS(), bossRefV: boss.refV(),
  });
  for (const e of pev) {
    if (e.type === 'bump') onBump(e.other);
    else if (e.type === 'smash') onSmash(e.other);
    else if (e.type === 'tow') { traffic.obstacles.splice(traffic.obstacles.indexOf(e.other), 1); flingObstacle(e.other, true); audio.play('whoosh'); }
  }
  player.boostT = Math.max(0, (player.boostT || 0) - dt);
  updateDrone(dt, jamLike, miniT);

  // 교통
  traffic.update(dt, {
    dt, time: G.time, player, villains: boss.villains, phase: ph,
    allowEvents: ph === 'jam', jamLike, focusS: ph === 'release' ? G.killS : player.s,
  });

  // 원흉
  const bev = boss.update(dt, { time: G.time, phase: ph, player, hud, night: world.night, playerBehind: ph === 'boss' && !G.frontLocked, laneFree: (lane) => !traffic.cars.some((c) => c.isWall && c.lane === lane) });
  for (const e of bev) {
    if (e.type === 'playerHit' || e.type === 'miniHit') onPlayerHit(e);
    else if (e.type === 'phase') onBossPhase(e);
  }

  // 무기
  if (ph === 'boss') {
    if (G.stage.honkOnly) {
      // 구조형(졸음·고장·대피): 압정·폭탄 대신 경적으로 깨워 갓길로 유도
      rescueHonk(dt, wantFire, wantSuper && G.frontLocked);
      weapons.update(dt, { phase: ph, player, boss, wantFire: false, wantSuper: false, rage: 0, onHit: onWeaponHit });
    } else {
      // 뒤에서 접근 중: 압정 선제공격(화물차 너머로) 가능, 분노는 '경적'으로 위에서 처리됨
      const wr = weapons.update(dt, { phase: ph, player, boss, wantFire, wantSuper: wantSuper && G.frontLocked, rage: G.rage, onHit: onWeaponHit });
      if (wr.superFired) { G.rage = Math.max(0, G.rage - TUNE.superCost); G.supers++; }
      else if (wantSuper && G.frontLocked && G.rage < TUNE.superCost) hud.popAt(player.mesh.position.clone().setY(2.6), '분노 부족!', 'warn');
    }
  } else {
    weapons.update(dt, { phase: ph, player, boss, wantFire: false, wantSuper: false, rage: 0, onHit: onWeaponHit });
  }

  // 막혀서 서 있으면 경적 힌트 (스테이지당 1회)
  if (jamLike && !G.stuckHinted) {
    G.stuckT = player.v < 2 ? (G.stuckT || 0) + dt : 0;
    if (G.stuckT > 2.2) { G.stuckHinted = true; ui.hint?.(player.lane === SHOULDER_LANE ? '갓길 막힘! 경적 → 4차선이 끼워줘요' : '꽉 막혔다! 오른쪽 갓길로 빠지세요 →', 2800); }
  }
  // 분노: 정체 속에서 서 있으면 쌓인다
  if (jamLike) addRage((TUNE.baseRage + (player.v < 5 ? TUNE.timeRage : 0)) * dt);

  // 페이즈 진행
  // 발견: 원흉 뒤 35m 안으로 들어오면 / 정면 참교육: 앞줄을 앞질러 원흉 앞으로 끼어들면
  if (ph === 'jam' && player.s > boss.refS() - 35) enterPhase('boss');
  if (ph === 'boss' && !G.frontLocked && player.s > boss.refS() + 2.5) {
    G.frontLocked = true;
    ui.banner('앞을 막았다! 정면 참교육!', 'go', 1100);
    audio.play('warn');
    const fh = G.stage.honkOnly
      ? (IS_TOUCH ? '[발사] = 경적으로 깨우기 · [분노] = 사이렌 대경적 · 갓길로 유도하면 구조 완료' : 'Space = 경적으로 깨우기 · R = 사이렌 대경적 · 갓길로 유도하면 구조 완료')
      : (IS_TOUCH ? '[발사] 꾹 = 뒤로 압정 (밟으면 펑크!) · [분노] = 분노 폭탄 · 공격은 차선 바꿔 피하기' : 'Space 꾹 = 뒤로 압정 (밟으면 펑크!) · R = 분노 폭탄 · 공격은 차선 바꿔 피하기');
    setTimeout(() => G.phase === 'boss' && ui.hint?.(fh, 3400), 900);
  }
  if (ph === 'release') {
    const waveDone = G.phaseT > (G.frontS - G.tailS) / TUNE.releaseWaveSpeed + 1.4;
    if (waveDone && G.phaseT > 4.2) enterPhase('cruise');
  }
  if (ph === 'cruise' && G.phaseT > TUNE.cruiseTime) enterPhase('result');
  if (ph === 'kill' && G.releaseAt && G.realTime > G.releaseAt) { G.releaseAt = 0; enterPhase('release'); }
  if (ph === 'intro' && G.introStage === 1 && G.introT2 > 2.05) enterPhase('jam');

  // 인과 연출: 빌런 바로 뒤 차들이 빌런한테 짜증 (경적 + 말풍선)
  if ((ph === 'intro' || ph === 'jam' || ph === 'boss') && G.realTime > (G.nextFrontRage || 0)) {
    G.nextFrontRage = G.realTime + 1.1 + Math.random() * 0.9;
    const cs = traffic.carsBehindFront(8, 30);
    if (cs.length) {
      const c = cs[Math.floor(Math.random() * cs.length)];
      bubble('fr' + c.id, FRONT_RAGE_LINES[Math.floor(Math.random() * FRONT_RAGE_LINES.length)], 'angry', 1.5, carTop(c, 0.8));
      if (Math.random() < 0.5 && project(c.mesh.position)) audio.play('hornShort', { volume: 0.35, pan: Math.max(-1, Math.min(1, (c.x - player.x) / 10)) });
    }
  }
  // 원흉 도발 말풍선 (보일 때마다 분노 +)
  for (const v of boss.villains) {
    const key = 'v' + v.index;
    if (v.taunt && v.taunt !== v._seenTaunt && (ph === 'jam' || ph === 'boss') && project(_tmpTop.set(v.x, v.h + 1.3, -v.s))) {
      v._seenTaunt = v.taunt;
      addRage(TUNE.tauntRage);
    }
    if (v.taunt && (v.alive || v.dying) && ph !== 'release') {
      bubbles.set(key, { text: v.taunt.text, kind: 'taunt', until: G.realTime + 0.1, pos: () => _tmpTop.set(v.mesh.position.x, v.h + 1.3, v.mesh.position.z) });
    }
  }

  // HUD
  if (['jam', 'boss', 'release', 'cruise'].includes(G.phase)) {
    const distM = Math.max(0, boss.refS() - player.s);
    ui.setHUD({ phase: G.phase, speedKmh: Math.round(toKmh(Math.max(0, player.v))), distM: Math.round(distM), rage: G.rage, score: G.score, combo: G.combo, minis: { done: G.minisDone || 0, total: G.minisTotal || 0 }, boostT: Math.min(1, (player.boostT || 0) / TUNE.boostTime), rageMode: G.phase === 'boss' && G.frontLocked ? (G.stage.honkOnly ? 'siren' : 'bomb') : 'horn' });
    const span = Math.max(1, G.frontS - G.startS);
    let released = 0;
    if (G.phase === 'release' || G.phase === 'cruise') released = Math.min(1, (G.time - traffic.releaseTime) * TUNE.releaseWaveSpeed / Math.max(1, G.frontS - G.tailS));
    ui.setNav({ progress: Math.max(0, Math.min(1, (player.s - G.startS) / span)), released });
    ui.vignette(G.phase === 'jam' ? Math.max(0, G.rage - 0.5) * 0.7 : 0);
  }
  if (G.phase === 'boss') {
    const a = boss.alive[0] || boss.villains[0];
    ui.showBoss({ name: boss.villains.map((v) => v.name).join(' & '), hp: boss.hpFrac(), tires: a ? a.tires : 0 });
  }
  if (G.phase === 'release' || G.phase === 'cruise') {
    const n = Math.round(traffic.countReleased() * G.mult);
    if (n !== G.releaseShown) { G.releaseShown = n; ui.setReleaseCounter(n); }
  }
  if (G.phase === 'result' && G.phaseReal > 0.2) ui.setReleaseCounter(null);

  // 엔진음
  audio.setEngine(Math.max(0, player.v), ph === 'jam' && !wantBrake ? 1 : 0.4);

  input.endFrame();
}

// ───────────────────────────── 루프
let last = performance.now();
const FF = Math.max(1, Math.min(20, +(params.get('ff') || 1)));   // 디버그: 프레임당 고정 스텝 수 (헤드리스 자동 테스트용)
let fpsAcc = 0, fpsN = 0;
function step(realDt) {
  try { update(realDt); } catch (e) { console.error(e); G.lastError = String(e && e.stack || e); }
  const fxDt = G.paused ? 0 : realDt * (G.hitstop > 0 ? 0 : (G.realTime < G.slowUntil ? G.slowScale : 1));
  fx.update(fxDt);
  releaseWave.update(fxDt);
  updateCamera(realDt);
  world.update(camera, _focus.set(player.x, 0, -(G.phase === 'release' ? G.killS - 40 : player.s + 10)), realDt);
}
function frame(now) {
  requestAnimationFrame(frame);
  const raw = Math.max(0, (now - last) / 1000);
  last = now;
  fpsAcc += raw; fpsN++;
  if (fpsAcc > 1) { G.fps = Math.round(fpsN / fpsAcc); fpsAcc = 0; fpsN = 0; }
  if (G.phase !== 'boot') {
    if (FF > 1) for (let i = 0; i < FF; i++) step(1 / 30);
    else step(Math.min(0.05, raw));
    updateBubbles();
  }
  renderer.render(scene, camera);
  if (G.photoAt && G.realTime >= G.photoAt) { G.photoAt = 0; G.photo = captureDashcam(); }
}
const _focus = new THREE.Vector3();

// 블박 캡처: 렌더 직후 캔버스를 작게 줄여 JPEG (도감 카드용, ~10KB)
const _shot = document.createElement('canvas');
function captureDashcam() {
  try {
    const W = 256, H = 144;
    _shot.width = W; _shot.height = H;
    const g = _shot.getContext('2d');
    const src = renderer.domElement;
    const sa = src.width / src.height, da = W / H;
    let sw = src.width, sh = src.height, sx = 0, sy = 0;
    if (sa > da) { sw = sh * da; sx = (src.width - sw) / 2; } else { sh = sw / da; sy = (src.height - sh) / 2; }
    g.drawImage(src, sx, sy, sw, sh, 0, 0, W, H);
    return _shot.toDataURL('image/jpeg', 0.62);
  } catch { return null; }
}

function onResize() {
  renderer.setSize(innerWidth, innerHeight, false);
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
}
window.addEventListener('resize', onResize);
window.addEventListener('orientationchange', () => setTimeout(onResize, 200));

// ───────────────────────────── 부팅
async function boot(data) {
  if (data && data.progress && typeof data.progress.unlocked === 'number') G.progress = data.progress;
  try { await Promise.race([SC.preloadFonts ? SC.preloadFonts() : Promise.resolve(), new Promise((r) => setTimeout(r, 3000))]); } catch { /* 폰트 없이 진행 */ }
  try { window.claude?.hot?.snapshot?.(() => ({ progress: G.progress })); } catch { /* 뷰어 밖 */ }
  if (params.get('mute') === '1') { audio.setMuted(true); ui.setMuted(true); }
  document.getElementById('boot')?.remove();

  const st = params.get('stage');
  const skip = params.get('skip');
  if (st) {
    startStage(Math.max(0, Math.min(STAGES.length - 1, (+st || 1) - 1)));
    if (skip) debugSkip(skip);
  } else {
    goTitle();
  }
  requestAnimationFrame(frame);
}

// 디버그: 특정 페이즈로 점프
function debugSkip(to) {
  if (G.phase === 'intro') { G.introStage = 1; G.introT2 = 9; enterPhase('jam'); }
  if (to === 'jam') return;
  // 보스 앞까지 순간이동
  player.s = boss.refS() + 4;
  player.lane = SHOULDER_LANE; player.x = laneX(SHOULDER_LANE);
  G.rage = 1;
  enterPhase('boss');
  G.frontLocked = true;
  if (to === 'boss') return;
  const v = boss.villains[boss.villains.length - 1];
  for (const o of boss.villains) if (o !== v) { o.hp = 0; boss.startDeath(o, false); }
  onWeaponHit(v, v.hp + 1, v.mesh.position.clone(), 'super');
  if (to === 'kill') return;
}
G.debugSkip = debugSkip;
G.startStage = startStage;
G.enterPhase = enterPhase;
G.objs = { player, traffic, boss, weapons, world, fx, camera, scene, renderer };

const hot = window.claude?.hot;
if (hot && hot.ready) hot.ready(boot); else boot(hot?.data ?? {});
