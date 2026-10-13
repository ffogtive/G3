// 원흉(빌런) 시스템 v2 — 정면 참교육
//
// 가설: 빌런 뒤는 정체라 못 간다 → 플레이어는 갓길로 앞질러 빌런 '앞'에서 싸운다.
//       빌런의 공격은 앞으로 날아오고(상향등·경적·돌진·투척·굴리기·매연), 플레이어는 차선을 바꿔 피하며
//       뒤로 압정을 던져 빌런이 밟게 한다 → HP 25%마다 타이어 펑크 → 하늘로 날아가 반짝★.
import * as THREE from 'three';
import { laneX, LANE_W, NUM_LANES, SHOULDER_LANE } from './config.js';
import { buildVehicle, buildProjectile, buildWarningMarker, setBrake, setHazard, setFlash, setHeadlights } from './vehicles.js';
import { occupies } from './traffic.js';
import * as VEH from './vehicles.js';

// 피니시 소품 (아트 모듈에 없으면 간단한 대체 모델)
// 투척물 착지 높이(중심): 모델 반높이에 맞춤
const LAND_Y = { hay: 0.37, box: 0.28, tire: 0.43, cone: 0.4, tack: 0.2 };

function fxProp(kind) {
  try { const g = VEH.buildFxProp?.(kind); if (g) return g; } catch { /* 대체 */ }
  const g = new THREE.Group();
  const mat = (c, o = {}) => new THREE.MeshLambertMaterial({ color: c, ...o });
  if (kind === 'balloons') {
    const bunch = new THREE.Group();
    const cols = [0xff4d6d, 0xffd23a, 0x4dabf7, 0x51cf66, 0xcc5de8, 0xff922b];
    cols.forEach((c, i) => { const b = new THREE.Mesh(new THREE.SphereGeometry(0.55, 8, 6), mat(c)); b.position.set(Math.cos(i) * 0.8, 3 + (i % 3) * 0.5, Math.sin(i) * 0.8); bunch.add(b); });
    const str = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.02, 3, 4), mat(0xffffff)); str.position.y = 1.5; g.add(str, bunch);
    g.userData.bunch = bunch;
  } else if (kind === 'helicopter') {
    const body = new THREE.Mesh(new THREE.BoxGeometry(2.4, 2.2, 6), mat(0xffd23a)); body.position.y = 7.5; g.add(body);
    const rotor = new THREE.Mesh(new THREE.BoxGeometry(9, 0.12, 0.5), mat(0x333333)); rotor.position.y = 8.8; g.add(rotor);
    const cable = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.04, 6, 4), mat(0x222222)); cable.position.y = 3.2; g.add(cable);
    g.userData.rotor = rotor; g.userData.cableLen = 6;
  } else if (kind === 'ufo') {
    const saucer = new THREE.Mesh(new THREE.CylinderGeometry(3.5, 1.2, 1, 16), mat(0x9aa4b2)); saucer.position.y = 12; g.add(saucer);
    const beam = new THREE.Mesh(new THREE.ConeGeometry(2.6, 12, 16, 1, true), new THREE.MeshBasicMaterial({ color: 0x9cff9c, transparent: true, opacity: 0.35, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide }));
    beam.position.y = 6; g.add(beam); g.userData.beam = beam;
  }
  return g;
}

const POP_ORDER = [0, 1, 2, 3]; // 앞바퀴부터 (압정을 앞에서 밟으니까): FL, FR, RL, RR
const _v3 = new THREE.Vector3();

export class Villain {
  constructor(scene, spec, stage, s, index) {
    this.scene = scene;
    this.spec = spec;
    this.index = index;
    this.kind = spec.kind;
    this.name = spec.name;
    this.isVillain = true;
    this.mesh = buildVehicle(spec.kind, { color: spec.color, detailed: true });
    scene.add(this.mesh);
    const ud = this.mesh.userData;
    this.len = ud.length || 4.8;
    this.w = ud.width || 2.0;
    this.h = ud.height || 1.6;
    this.lanePos = spec.lane;
    this.homeLane = spec.lane;
    this.targetLanePos = spec.lane;
    this.x = laneX(spec.lane);
    this.baseS = s;          // 정속 기준 위치 (돌진 오프셋 제외) — 교통·플레이어는 이걸 기준으로
    this.s = s;
    this.lungeOff = 0;
    // 정차형 빌런(사고 후 다툼·차선 위 정차 등)은 멈춰서 길을 막는다
    this.stopped = !!spec.stopped;
    this.vNominal = this.stopped ? 0 : stage.jamSpeed;
    this.v = this.vNominal;
    this.hp = spec.hp;
    this.maxHp = spec.hp;
    this.tires = 4;
    this.alive = true;
    this.dying = false;
    this.gone = false;
    this.flash = 0;
    this.tiltX = 0; this.tiltZ = 0;
    this.nose = 0;
    this.yaw = 0;
    this.sparkCorners = [];
    this.sparkT = 0;
    this.zigT = Math.random() * 10;
    this.zigBoost = 0;
    // 지그재그형(폰·졸음·칼치기): 중심 차로 ±1을 휘젓는다
    this.zig = spec.zig ?? (spec.kind === 'villainPhone');
    this.zigC = Math.max(1, Math.min(2, Math.round(spec.lane)));
    this.taunt = null;
    this.nextTaunt = 1.5 + index * 1.7;
    this.mesh.position.set(this.x, 0, -s);
    // 머리 위 '정체 원인' 표식 (빨간 화살표, 통통 튐)
    this.marker = new THREE.Group();
    const mm = new THREE.MeshBasicMaterial({ color: 0xff2a2a });
    const arrow = new THREE.Mesh(new THREE.ConeGeometry(0.75, 1.5, 4), mm);
    arrow.rotation.x = Math.PI;
    const cap = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.7, 0.7), mm);
    cap.position.y = 1.05;
    this.marker.add(arrow, cap);
    scene.add(this.marker);
  }

  get lane() { return Math.round(this.lanePos); }
  get front() { return this.s + this.len / 2; }

  lanes() {
    const out = [];
    for (let i = 0; i < NUM_LANES; i++) if (occupies(this, i)) out.push(i);
    return out;
  }

  wheelWorldPos(i, out) {
    const w = this.mesh.userData.wheels?.[i];
    if (w && w.parent === this.mesh) return w.getWorldPosition(out);
    const sx = i % 2 === 0 ? -1 : 1, sz = i < 2 ? -1 : 1;
    out.set(this.x + sx * this.w * 0.45, 0.3, -this.s + sz * this.len * 0.35);
    return out;
  }
}

export class BossManager {
  constructor(scene, fx, audio) {
    this.scene = scene;
    this.fx = fx;
    this.audio = audio;
    this.villains = [];
    this.waves = [];
    this.beams = [];
    this.items = [];
    this.debris = [];
    this.pools = {};
    this.markerPool = [];
    this.attackT = 3;
    this.time = 0;
    this.hornMat = new THREE.MeshBasicMaterial({ color: 0xffd23a, transparent: true, opacity: 0.55, depthWrite: false, blending: THREE.AdditiveBlending });
    this.smokeMat = new THREE.MeshBasicMaterial({ color: 0x1b1b1b, transparent: true, opacity: 0.62, depthWrite: false });
    this.beamMat = new THREE.MeshBasicMaterial({ color: 0xfff6c8, transparent: true, opacity: 0.0, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide });
    this.ringGeo = new THREE.TorusGeometry(1.5, 0.22, 6, 18, Math.PI).rotateZ(0); // 반원 아치 (경적 충격파)
    this.slabGeo = new THREE.BoxGeometry(LANE_W * 0.92, 1.3, 2.2);
    // 상향등: 앞으로 퍼지는 사다리꼴 빛기둥 (길이 30m)
    this.beamGeo = new THREE.CylinderGeometry(3.2, 0.6, 30, 10, 1, true).rotateX(Math.PI / 2).translate(0, 1.0, -15);
  }

  clear() {
    for (const v of this.villains) { this.scene.remove(v.mesh); this.scene.remove(v.marker); if (v.prop) this.scene.remove(v.prop); }
    for (const w of this.waves) this.scene.remove(w.group);
    for (const b of this.beams) this.scene.remove(b.mesh);
    for (const it of this.items) { this._releaseItem(it.obj); if (it.marker) this._releaseMarker(it.marker); }
    for (const d of this.debris) this.scene.remove(d.obj);
    this.villains.length = 0; this.waves.length = 0; this.beams.length = 0; this.items.length = 0; this.debris.length = 0;
  }

  spawn(stage, sFront) {
    this.clear();
    this.stage = stage;
    this.villains = stage.villains.map((spec, i) => new Villain(this.scene, spec, stage, sFront, i));
    this.attackT = 2.2;
    this.totalMaxHp = this.villains.reduce((a, v) => a + v.maxHp, 0);
    // 공격표는 페이즈마다 바뀌므로 복사해서 쓴다 (stage 객체는 재도전 때 재사용)
    this.attacks = { ...(stage.attacks || {}) };
    this.intervalMul = 1;
    this.phases = (stage.phases || []).slice().sort((a, b) => b.hp - a.hp);
    this.phaseIdx = 0;
    this.parked = 0;   // 구조형: 갓길에 정차시킨 대수 (겹치지 않게 앞뒤로 비켜 세움)
  }

  get alive() { return this.villains.filter((v) => v.alive); }
  get anyAlive() { return this.villains.some((v) => v.alive); }
  hpFrac() {
    const hp = this.villains.reduce((a, v) => a + Math.max(0, v.hp), 0);
    return hp / Math.max(1, this.totalMaxHp);
  }
  tiresLeft() { return this.villains.reduce((a, v) => a + v.tires, 0); }
  // 정속 기준 위치 (돌진 중에도 흔들리지 않게 baseS)
  // 기준: 살아 있는 빌런 → (없으면) 연출 중인 빌런 → 전체. 날아가는 1호가 기준을 끌고 가지 않게
  _refSet() {
    const alive = this.villains.filter((v) => v.alive);
    if (alive.length) return alive;
    const dying = this.villains.filter((v) => v.dying);
    return dying.length ? dying : this.villains;
  }
  refS() {
    const src = this._refSet();
    if (!src.length) return 0;
    return src.reduce((acc, v) => acc + v.baseS, 0) / src.length;
  }
  refV() { const src = this._refSet(); return src.length ? src[0].vNominal : 0; }

  // 압정 투척 대상: 정면(앞) = 플레이어 차선 ±1 이내 / 뒤에서 = 42m 안이면 화물차 너머로 높이 던져 넣기
  targetFor(player) {
    let best = null, bd = Infinity;
    for (const v of this.villains) {
      if (!v.alive) continue;
      const ds = v.s - player.s;
      if (ds > 0) { // 플레이어가 뒤에 있음
        if (ds < 42 && ds < bd) { bd = ds; best = v; }
        continue;
      }
      // 정면: 빌런이 차지한 차로(차선 물기면 2개) ±1 차로 안이면 조준 가능
      const pl = Math.round((player.x + LANE_W * 1.5) / LANE_W);
      if (!v.lanes().some((l) => Math.abs(l - pl) <= 1)) continue;
      const dx = Math.abs(v.x - player.x);
      if (dx < bd) { bd = dx; best = v; }
    }
    return best;
  }

  // ── 피해. 반환 { popped, killed, villain }
  damage(v, amount, pos, kind = 'tack', fromRear = false) {
    if (!v || !v.alive) return { popped: false, killed: false };
    v.hitFromRear = fromRear;
    const before = v.hp / v.maxHp;
    v.hp -= amount;
    v.flash = 1;
    const after = Math.max(0, v.hp) / v.maxHp;
    let popped = false;
    if (!this.stage?.honkOnly) for (let k = 1; k <= 3; k++) {
      const th = 1 - k * 0.25;
      if (before > th && after <= th && v.tires > 1) { this._popTire(v); popped = true; }
    }
    if (v.hp <= 0) { v.alive = false; return { popped, killed: true, villain: v }; }
    return { popped, killed: false, villain: v };
  }

  _popTire(v) {
    // 맞은 쪽 바퀴부터 (뒤에서 던지면 뒷바퀴, 앞에서 막고 던지면 앞바퀴)
    v.popped = v.popped || [];
    const order = v.hitFromRear ? [2, 3, 0, 1] : POP_ORDER;
    const idx = order.find((i) => !v.popped.includes(i)) ?? 0;
    v.popped.push(idx);
    v.tires--;
    const wheel = v.mesh.userData.wheels?.[idx];
    const p = v.wheelWorldPos(idx, new THREE.Vector3());
    if (wheel && wheel.parent === v.mesh) {
      this.scene.attach(wheel);
      const side = idx % 2 === 0 ? -1 : 1;
      this.debris.push({
        obj: wheel, vel: new THREE.Vector3(side * (5 + Math.random() * 4), 7 + Math.random() * 3, -(v.v + 2) - Math.random() * 4),
        spin: new THREE.Vector3(8 + Math.random() * 8, Math.random() * 4, side * 6), life: 3.2, bounce: true,
      });
    }
    v.sparkCorners.push(idx);
    v.tiltZ += (idx % 2 === 0 ? 1 : -1) * 0.07;
    v.tiltX += (idx < 2 ? -1 : 1) * 0.05; // +rotation.x = 코 들림 → 앞바퀴 펑크면 코가 숙여짐
    this.fx.sparks(p, { count: 26, speed: 10 });
    this.fx.smokePuff(p, { count: 8, color: 0xdddddd });
    this.fx.shake(0.35, 0.25);
    this.audio.play('pop');
    this.onPop?.(v, p);
  }

  startDeath(v, isLast) {
    v.alive = false;
    v.marker.visible = false;
    v.dying = true;
    v.deathT = 0;
    v.isLast = isLast;
    v.lunge = null;
    v.vel = new THREE.Vector3(0, 8, -(v.v + 3));
    v.spin = new THREE.Vector3(3.5 + Math.random() * 2, 7 + Math.random() * 3, 2.5);
    v.launched = false;
    v.finish = this.stage?.honkOnly ? 'pullover' : (this.finishStyle || 'rocket');
    setHazard(v.mesh, true);
    for (const b of this.beams) if (b.v === v) b.life = 0;
    if (v.finish === 'pullover') {
      v.baseS = v.s; v.lungeOff = 0; v.lunge = null; v.lungeAt = 0;   // 돌진 중이었어도 그 자리에서 시작 (순간이동 금지)
      v.pullX = v.x; v.pullS0 = v.baseS;
      v.parkIdx = this.parked++;
      v.pullDist = 5 + v.parkIdx * (v.len + 2.5);
      const own = v.lanes();
      const right = [];
      for (let l = Math.max(...own) + 1; l < NUM_LANES; l++) right.push(l);
      this.onPullover?.(v, right);   // 갓길 쪽 차로의 앞줄 벽이 살짝 물러나 길을 터 줌
      this.audio.play('twinkle');
      return;
    }
    while (v.tires > 0) this._popTire(v);
    const p = v.mesh.position.clone(); p.y += 1;
    this.fx.explosion(p, v.len > 6 ? 1.4 : 1.0);
    this.fx.debris(p, [v.spec.color || 0xcccccc, 0x222222, 0xdddddd], 18);
    this.audio.play('explosion');
  }

  _updateDeath(v, dt) {
    if (v.finish === 'pullover') return this._updatePullover(v, dt);
    if (v.finish && v.finish !== 'rocket') return this._updateFinish(v, dt);
    v.deathT += dt;
    v.baseS += v.vNominal * dt;
    const m = v.mesh;
    if (!v.launched && v.deathT > 0.85) {
      v.launched = true;
      v.vel.set((Math.random() - 0.5) * 4, 36, -(v.v + 6));
      v.spin.multiplyScalar(1.8);
      this.audio.play('launch');
      this.fx.smokeTrail(m, 2.2);
    }
    const g = v.launched ? -5 : -26;
    v.vel.y += g * dt;
    m.position.addScaledVector(v.vel, dt);
    if (!v.launched && m.position.y < 0) { m.position.y = 0; v.vel.y = Math.abs(v.vel.y) * 0.45; this.fx.sparks(m.position, { count: 10 }); }
    m.rotation.x += v.spin.x * dt;
    m.rotation.y += v.spin.y * dt;
    m.rotation.z += v.spin.z * dt;
    v.s = -m.position.z;
    if (v.launched && v.deathT > 2.15 && !v.gone) {
      v.gone = true;
      v.dying = false;
      this.fx.twinkle(m.position.clone());
      this.audio.play('twinkle');
      m.visible = false;
      this.onGone?.(v);
    }
  }

  // 구조형 마무리: 정신 차리고 갓길로 빠져 비상등 정차 (날려 보내지 않는다)
  _updatePullover(v, dt) {
    v.deathT += dt;
    const t = v.deathT, m = v.mesh;
    const sm = (x) => { const c = Math.max(0, Math.min(1, x)); return c * c * (3 - 2 * c); };
    // 앞으로 살짝 빠져나간 뒤(벽 차량은 뒤로 물러남) 대각선으로 갓길 진입
    v.baseS = v.pullS0 + v.pullDist * sm(t / 1.9);
    v.s = v.baseS;
    const tx = laneX(SHOULDER_LANE);
    const k = sm((t - 0.45) / 1.5);
    v.x = v.pullX + (tx - v.pullX) * k;
    m.position.set(v.x, 0, -v.s);
    m.rotation.set(0, -Math.sin(k * Math.PI) * 0.25, 0);
    setHazard(m, Math.floor(t * 3) % 2 === 0);
    if (t > 2.2 && !v.gone) {
      v.gone = true; v.dying = false;
      this.fx.twinkle(m.position.clone().setY(v.h + 1.2));
      this.onGone?.(v);   // 메시는 갓길에 남겨 둔다 (비상등 정차)
    }
  }

  // 피니시 연출: 풍선 둥실 / 헬기 견인 / UFO 납치
  _updateFinish(v, dt) {
    v.deathT += dt;
    v.baseS += v.vNominal * dt;
    const m = v.mesh, t = v.deathT;
    const bounce = () => { // 처음 0.8초: 펑크 나고 털썩
      v.vel.y += -26 * dt; m.position.addScaledVector(v.vel, dt);
      if (m.position.y < 0) { m.position.y = 0; v.vel.y = Math.abs(v.vel.y) * 0.4; }
      m.rotation.y += v.spin.y * dt * 0.4;
    };
    if (t < 0.8) { bounce(); v.s = -m.position.z; return; }
    if (!v.prop) {
      v.prop = fxProp(v.finish === 'heli' ? 'helicopter' : v.finish === 'ufo' ? 'ufo' : 'balloons');
      this.scene.add(v.prop);
      m.rotation.set(0, m.rotation.y, 0);
      this.audio.play(v.finish === 'ufo' ? 'twinkle' : 'whoosh');
      v.liftY = m.position.y;
    }
    const u = t - 0.8;
    const P = v.prop;
    if (v.finish === 'balloon') {
      // 풍선 다발이 차 지붕에 묶여 둥실둥실
      v.liftY += (2 + u * 4.5) * dt;
      m.position.y = v.liftY;
      m.position.x += Math.sin(t * 2) * dt * 0.8;
      m.rotation.z = Math.sin(t * 2.3) * 0.12;
      P.position.set(m.position.x, m.position.y + v.h, m.position.z);
      if (P.userData.bunch) P.userData.bunch.rotation.z = Math.sin(t * 1.7) * 0.15;
    } else if (v.finish === 'heli') {
      // 헬기가 내려와 고리를 걸고 들어 올려 앞으로 날아감
      const hookY = Math.max(v.h + 0.2, 18 - u * 14);
      if (u < 1.0) { P.position.set(m.position.x, hookY, m.position.z); }
      else {
        v.liftY += (4 + (u - 1) * 7) * dt;
        m.position.y = v.liftY;
        m.position.z -= (6 + u * 6) * dt;
        m.rotation.z = Math.sin(t * 3) * 0.1;
        P.position.set(m.position.x, m.position.y + v.h + 0.2, m.position.z);
      }
      if (P.userData.rotor) P.userData.rotor.rotation.y += dt * 30;
      if (P.userData.tailRotor) P.userData.tailRotor.rotation.x += dt * 40;
    } else {
      // UFO: 빛줄기에 빨려 빙글빙글 올라감
      P.position.set(m.position.x, 0, m.position.z);
      if (u > 0.3) { v.liftY += (1.5 + (u - 0.3) * 9) * dt; m.position.y = v.liftY; m.rotation.y += dt * (3 + u * 6); }
      if (P.userData.beam) P.userData.beam.material.opacity = 0.25 + Math.sin(t * 20) * 0.08;
      if (m.position.y > 11) m.visible = false;
    }
    v.s = -m.position.z;
    const done = v.finish === 'ufo' ? 2.4 : 3.0;
    if (u > done && !v.gone) {
      v.gone = true; v.dying = false;
      this.fx.twinkle((v.finish === 'ufo' ? P.position.clone().setY(12) : m.position.clone()));
      this.audio.play('twinkle');
      m.visible = false;
      this.scene.remove(P); v.prop = null;
      this.onGone?.(v);
    }
  }

  _releaseMarker(mk) { mk.visible = false; this.markerPool.push(mk); }
  _getMarker() {
    const mk = this.markerPool.pop() || buildWarningMarker();
    if (!mk.parent) this.scene.add(mk);
    mk.visible = true;
    return mk;
  }
  _getItem(kind) {
    const pool = this.pools[kind] || (this.pools[kind] = []);
    const obj = pool.pop() || buildProjectile(kind);
    if (!obj.parent) this.scene.add(obj);
    obj.visible = true;
    obj.scale.set(1, 1, 1);
    obj.userData.kind = kind;
    return obj;
  }
  _releaseItem(obj) { obj.visible = false; obj.scale.set(1, 1, 1); (this.pools[obj.userData.kind] ||= []).push(obj); }

  // ── 공격 선택
  _chooseAttack() {
    const w = this.attacks || {};
    let tot = 0; for (const k in w) tot += w[k];
    if (tot <= 0) return null;   // 공격 없음(구조형 스테이지)
    let r = Math.random() * tot;
    for (const k in w) { if ((r -= w[k]) <= 0) return k; }
    return null;
  }

  // 페이즈 전환: HP 비율이 기준 아래로 → 공격표·이동 성격 교체 (반환: 이벤트 또는 null)
  _checkPhase(ctx = {}) {
    const ph = this.phases[this.phaseIdx];
    if (!ph || this.hpFrac() > ph.hp) return null;
    this.phaseIdx++;
    if (Object.keys(ph.attacks || {}).length) this.attacks = { ...ph.attacks };
    this.intervalMul *= 0.85;
    for (const v of this.villains) {
      if (!v.alive) continue;
      // 페이즈의 이동 성격을 그대로 적용 (켜기만이 아니라 끄기도): 정차 ↔ 서행 ↔ 정속, 지그재그 on/off
      v.stopped = !!ph.stopped;
      if (v.stopped) { v.vNominal = 0; v.lunge = null; v.lungeOff = 0; v.lungeAt = 0; v.returnAt = 0; v.targetLanePos = v.lanePos; }
      else v.vNominal = (this.stage.jamSpeed || 2.4) * (ph.slow ? 0.7 : 1);
      // 지그재그는 휘젓는 차로(중심 ±1)에 앞줄 벽·다른 빌런이 없을 때만 (없으면 공격표만 바뀜)
      const zc = Math.max(1, Math.min(2, Math.round(v.lanePos)));
      const sweepFree = [zc - 1, zc, zc + 1].every((l) => (!ctx.laneFree || ctx.laneFree(l, v))
        && !this.villains.some((o) => o !== v && (o.alive || o.dying) && Math.abs(o.lanePos - l) < 0.9));
      if (ph.zig && !v.stopped && sweepFree) { v.zig = true; v.zigC = zc; }
      else if (v.zig) { v.zig = false; v.targetLanePos = v.homeLane; }
      if (!v.stopped) setHazard(v.mesh, false);
      v.flash = 1;
    }
    this.attackT = 1.2;
    return { type: 'phase', label: ph.label || '2페이즈!', idx: this.phaseIdx };
  }

  _say(v, text, dur = 2.0) { v.taunt = { text, until: this.time + dur }; this.audio.play('tauntBlip'); }

  _attack(kind, v, ctx) {
    const { player, hud } = ctx;
    const top = _v3.set(v.x, v.h + 1.6, -v.s);
    switch (kind) {
      case 'highbeam': {
        hud.popAt(top, '상향등!', 'warn');
        this.audio.play('warn');
        const mesh = new THREE.Mesh(this.beamGeo, this.beamMat.clone());
        mesh.position.set(v.x, 0, -(v.front));
        this.scene.add(mesh);
        this.beams.push({ v, mesh, t: 0, tele: 0.75, on: 0.5, life: 1.4, hit: false, lanes: v.lanes() });
        break;
      }
      case 'horn': {
        hud.popAt(top, '빵!!!', 'warn');
        this.audio.play('hornAngry');
        this._wave(v, 'horn');
        break;
      }
      case 'lunge': {
        if (v.lunge) break;
        hud.popAt(top, '부릉부릉!', 'warn');
        this.audio.play('warn');
        v.lunge = { t: 0, phase: 'tele', reach: 0, hit: false };
        break;
      }
      case 'throw': {
        const n = this.stage.villains.length > 1 ? 1 : (Math.random() < 0.35 ? 2 : 1);
        const lanes = new Set([player.lane]);
        while (lanes.size < n) lanes.add(Math.max(0, Math.min(SHOULDER_LANE, player.lane + (Math.random() < 0.5 ? -1 : 1))));
        for (const ln of lanes) this._throw(v, ln, player, false);
        if (Math.random() < 0.6) this._say(v, '옛다!');
        break;
      }
      case 'roll': {
        const n = this.stage.villains.length > 1 ? 1 : 2;
        const lanes = new Set([player.lane]);
        while (lanes.size < n) lanes.add(Math.max(0, Math.min(NUM_LANES - 1, player.lane + (Math.random() < 0.5 ? -1 : 1))));
        for (const ln of lanes) this._throw(v, ln, player, true);
        if (Math.random() < 0.6) this._say(v, this.stage.throwItem === 'watermelon' ? '수박 서비스~' : this.stage.throwItem === 'hay' ? '거름이여~' : '굴러간다~');
        break;
      }
      case 'swerve': {
        let tgt = Math.min(NUM_LANES - 1, player.lane);
        if (v.w > 2.2 || v.kind === 'villainSuv') tgt = Math.max(0.5, Math.min(2.5, tgt + (tgt > v.lanePos ? -0.5 : 0.5)));
        // 옆 차선에 화물차가 있으면 못 감: 목표 위치에서 실제로 걸치는 차로 전부 검사 (반 차로 목표면 두 차로)
        if (ctx.laneFree) {
          const probe = { x: laneX(tgt), w: v.w };
          let blocked = false;
          for (let i = 0; i < NUM_LANES; i++) if (occupies(probe, i) && !ctx.laneFree(i, v)) blocked = true;
          if (blocked) break;
        }
        v.targetLanePos = tgt;
        v.returnAt = this.time + 3.2;
        this.audio.play('brakeScreech', { volume: 0.5 });
        this._say(v, '비켜 비켜~');
        v.lungeAt = this.time + 0.65; // 따라붙고 나서 돌진
        break;
      }
      case 'zigzag': {
        v.zigBoost = 2.6;
        this._say(v, 'ㅋㅋㅋㅋㅋ');
        break;
      }
      case 'smoke': {
        this._wave(v, 'smoke');
        this._say(v, '탈탈탈탈~');
        this.audio.play('whoosh', { pitch: 0.6 });
        break;
      }
    }
  }

  // 앞으로 퍼지는 파동 (경적 충격파 / 매연)
  _wave(v, kind) {
    const lanes = v.lanes();
    if (kind === 'smoke') {
      const l0 = Math.min(...lanes), l1 = Math.max(...lanes);
      if (l0 > 0) lanes.push(l0 - 1);
      if (l1 < NUM_LANES - 1) lanes.push(l1 + 1);
    }
    const group = new THREE.Group();
    for (const ln of lanes) {
      if (kind === 'horn') {
        const ring = new THREE.Mesh(this.ringGeo, this.hornMat);
        ring.position.set(laneX(ln), 0.2, 0);
        group.add(ring);
      } else {
        const slab = new THREE.Mesh(this.slabGeo, this.smokeMat);
        slab.position.set(laneX(ln), 1.2, 0);
        slab.scale.set(1, 1.8, 1.6);
        group.add(slab);
      }
    }
    group.position.z = -v.front;
    this.scene.add(group);
    this.waves.push({ group, lanes, s: v.front, speed: kind === 'smoke' ? 8 : 20, kind, hit: false, life: 3.2, age: 0 });
    if (kind === 'smoke') for (let i = 0; i < 4; i++) this.fx.smokePuff(new THREE.Vector3(v.x, 1.6, -v.front), { color: 0x222222, count: 8, size: 1.6 });
  }

  // 투척: rolling=false → 0.85초 뒤 플레이어 위치에 직격(경고 표식) / true → 빌런 앞에 떨어져 앞으로 굴러감
  _throw(v, lane, player, rolling) {
    const kind = this.stage.throwItem || 'cup';
    const obj = this._getItem(kind);
    const from = new THREE.Vector3(v.x, v.h + 0.4, -(v.front - 0.6));
    const dur = rolling ? 0.45 : 0.85;
    const landS = rolling ? v.front + 2.2 : player.s + Math.max(0, player.v) * dur + 0.3;
    const to = new THREE.Vector3(laneX(lane), LAND_Y[kind] ?? 0.45, -landS);
    const marker = this._getMarker();
    marker.position.set(to.x, 0.04, rolling ? -(player.s) : to.z); // 굴러오는 건 '내 위치'에 경고
    marker.userData.setProgress?.(0);
    obj.position.copy(from);
    this.items.push({
      obj, kind, lane, from, to, t: 0, dur, landed: false, marker, rolling,
      roll: kind === 'watermelon' ? 7.5 : 6.0, s: landS, len: kind === 'hay' ? 1.5 : 1.1, rollT: 0,
    });
    this.audio.play('throw');
  }

  // 잔챙이 빌런이 던지는 것 (정체 구간에서도 판정)
  throwFrom(src, lane, player, kind) {
    const obj = this._getItem(kind);
    const from = new THREE.Vector3(src.x, src.h + 0.3, -(src.s));
    const dur = 0.8;
    const landS = player.s + Math.max(0, player.v) * dur + 0.4;
    const to = new THREE.Vector3(laneX(lane), 0.45, -landS);
    const marker = this._getMarker();
    marker.position.set(to.x, 0.04, to.z);
    marker.userData.setProgress?.(0);
    obj.position.copy(from);
    this.items.push({ obj, kind, lane, from, to, t: 0, dur, landed: false, marker, rolling: false, roll: 0, s: landS, len: 1.1, rollT: 0, fromMini: true });
    this.audio.play('throw', { volume: 0.6 });
  }

  // ctx: { dt, time, phase, player, hud, laneFree(lane, v), playerBehind }  반환 이벤트 배열
  update(dt, ctx) {
    this.time = ctx.time;
    const events = [];
    const player = ctx.player;
    const hud = ctx.hud;
    const fighting = ctx.phase === 'boss';

    for (const v of this.villains) {
      if (v.dying) { this._updateDeath(v, dt); continue; }
      if (!v.alive) continue;

      v.v = v.vNominal;
      v.baseS += v.v * dt;
      if (v.lungeAt && this.time > v.lungeAt) { v.lungeAt = 0; if (!v.lunge) v.lunge = { t: 0, phase: 'tele', reach: 0, hit: false }; }

      // 돌진 (tele: 부릉부릉 → go: 앞으로 → hold → back)
      if (v.lunge) {
        const L = v.lunge;
        L.t += dt;
        if (L.phase === 'tele') {
          v.nose = Math.min(1, L.t / 0.55) * 0.6; // 엉덩이 내려앉기(코 들림, +rotation.x)
          if (Math.random() < dt * 20) this.fx.smokePuff(_v3.set(v.x, 0.4, -(v.s - v.len / 2)), { count: 2, color: 0x555555 });
          if (L.t > 0.55) {
            L.phase = 'go'; L.t = 0;
            L.reach = Math.max(4, (player.s - player.len / 2) - v.front + 1.6);
            this.audio.play('whoosh');
          }
        } else if (L.phase === 'go') {
          v.lungeOff = L.reach * Math.min(1, L.t / 0.3);
          if (L.t > 0.3) { L.phase = 'hold'; L.t = 0; }
        } else if (L.phase === 'hold') {
          if (L.t > 0.25) { L.phase = 'back'; L.t = 0; }
        } else {
          v.lungeOff = L.reach * Math.max(0, 1 - L.t / 0.8);
          if (L.t > 0.8) { v.lunge = null; v.lungeOff = 0; }
        }
        // 들이받기 판정
        if (v.lunge && !L.hit && (L.phase === 'go' || L.phase === 'hold') && fighting && player.invuln <= 0
          && v.lanes().some((ln) => occupies(player, ln)) && v.s + v.lungeOff + v.len / 2 >= player.s - player.len / 2) {
          L.hit = true;
          events.push({ type: 'playerHit', cause: 'lunge', text: '들이받기!', push: 4 });
        }
      } else {
        v.nose *= Math.exp(-dt * 6);
      }
      v.s = v.baseS + v.lungeOff;

      // 횡방향
      if (v.zig && !v.stopped) {
        v.zigBoost = Math.max(0, v.zigBoost - dt);
        v.zigT += dt * (v.zigBoost > 0 ? 2.4 : 1);
        v.targetLanePos = v.zigC + Math.sin(v.zigT * 0.9) * 1.0 + Math.sin(v.zigT * 2.3) * 0.15;
      } else if (v.returnAt && this.time > v.returnAt) {
        v.returnAt = 0;
        v.targetLanePos = v.homeLane;
      }
      const prevX = v.x;
      const k = v.zig ? 3 : 5;
      v.lanePos += (v.targetLanePos - v.lanePos) * (1 - Math.exp(-dt * k));
      v.x = laneX(v.lanePos);
      const vx = (v.x - prevX) / Math.max(dt, 1e-4);
      v.yaw = -Math.atan2(vx, Math.max(3, v.v)) * 0.7;

      // 도발
      if (v.taunt && this.time > v.taunt.until) v.taunt = null;
      if (this.time > v.nextTaunt) {
        v.nextTaunt = this.time + 3.2 + Math.random() * 2.4;
        const lines = this.stage.taunts || [];
        if (lines.length && ctx.phase !== 'title') this._say(v, lines[Math.floor(Math.random() * lines.length)], 2.2);
      }

      // 펑크 바퀴 불꽃
      if (v.sparkCorners.length) {
        v.sparkT -= dt;
        if (v.sparkT <= 0) {
          v.sparkT = 0.07;
          const idx = v.sparkCorners[Math.floor(Math.random() * v.sparkCorners.length)];
          v.wheelWorldPos(idx, _v3);
          _v3.y = 0.15;
          this.fx.sparks(_v3, { count: 4, speed: 5, dir: new THREE.Vector3(0, 0.6, 1) });
        }
      }

      // 표식
      v.marker.visible = true;
      v.marker.position.set(v.x, v.h + 2.3 + Math.sin(this.time * 5 + v.index) * 0.35, -v.s);
      v.marker.rotation.y = this.time * 2.5;
      const far = player.s < v.s - 40 ? (v.s - player.s - 40) / 60 : 0;
      v.marker.scale.setScalar(1 + Math.min(1.2, Math.max(0, far)));

      // 메시
      if (v.stopped) setHazard(v.mesh, Math.floor(this.time * 2) % 2 === 0);
      v.flash = Math.max(0, v.flash - dt * 9);
      setFlash(v.mesh, v.flash);
      setBrake(v.mesh, false);
      const m = v.mesh;
      m.position.set(v.x, 0, -v.s);
      m.rotation.set(0, v.yaw, 0);
      const body = m.userData.body;
      if (body) {
        body.rotation.x = v.tiltX + v.nose * 0.09 + Math.sin(this.time * 18) * 0.004 * v.sparkCorners.length;
        body.rotation.z = v.tiltZ + (v.flash > 0.5 ? (Math.random() - 0.5) * 0.04 : 0);
      }
      const r = m.userData.wheelRadius || 0.42, radii = m.userData.wheelRadii;
      (m.userData.wheels || []).forEach((w, i) => { if (w.parent === m) w.rotation.x -= (v.v * dt) / (radii?.[i] || r); });
    }

    // 페이즈 전환 (보스·엘리트)
    if (fighting && this.anyAlive && this.phases?.length) { const pe = this._checkPhase(ctx); if (pe) events.push(pe); }

    // 공격 스케줄
    if (fighting && this.anyAlive) {
      this.attackT -= dt;
      if (this.attackT <= 0) {
        const [a, b] = this.stage.attackInterval || [2.5, 3.5];
        this.attackT = (a + Math.random() * (b - a)) * (this.intervalMul || 1);
        const alive = this.alive;
        const v = alive[Math.floor(Math.random() * alive.length)];
        // 플레이어가 아직 뒤(갓길)에 있으면: 뒤로 투척만 (앞으로 쏘는 공격은 안 닿음). 구조형(경적 전용)은 안 던진다
        const peaceful = this.stage.honkOnly || !Object.keys(this.attacks || {}).length;
        const kind = ctx.playerBehind ? (peaceful ? null : 'throw') : this._chooseAttack();
        if (kind) this._attack(kind, v, ctx);
      }
    }

    // 상향등
    for (let i = this.beams.length - 1; i >= 0; i--) {
      const b = this.beams[i];
      b.t += dt; b.life -= dt;
      const v = b.v;
      b.mesh.position.set(v.x, 0, -v.front);
      const mat = b.mesh.material;
      if (b.t < b.tele) {
        // 깜빡깜빡 예고
        const on = Math.floor(b.t * 12) % 2 === 0;
        setHeadlights(v.mesh, on);
        mat.opacity = on ? 0.12 : 0.0;
      } else if (b.t < b.tele + b.on) {
        setHeadlights(v.mesh, true);
        mat.opacity = 0.55;
        if (!b.hit && fighting && player.invuln <= 0 && b.lanes.some((ln) => occupies(player, ln)) && player.s > v.s && player.s - v.s < 32) {
          b.hit = true;
          events.push({ type: 'playerHit', cause: 'highbeam', text: '눈부셔!!', flash: true });
        }
      } else {
        mat.opacity = Math.max(0, mat.opacity - dt * 2);
        setHeadlights(v.mesh, !!ctx.night);
      }
      if (b.life <= 0) { this.scene.remove(b.mesh); b.mesh.material.dispose(); this.beams.splice(i, 1); }
    }

    // 파동 (경적/매연) — 앞으로
    for (let i = this.waves.length - 1; i >= 0; i--) {
      const w = this.waves[i];
      const prevS = w.s;
      w.s += (this.refV() + w.speed) * dt;
      w.life -= dt; w.age += dt;
      w.group.position.z = -w.s;
      const sc = w.kind === 'horn' ? 1 + w.age * 0.8 : 1 + Math.sin(this.time * 6) * 0.06;
      w.group.scale.set(1, sc, 1);
      if (w.kind === 'horn') this.hornMat.opacity = 0.55 * Math.max(0.2, 1 - w.age * 0.5);
      if (!w.hit && player.invuln <= 0 && fighting) {
        const rear = player.s - player.len / 2;
        if (prevS <= player.s + player.len / 2 && w.s >= rear && w.lanes.some((ln) => occupies(player, ln))) {
          w.hit = true;
          events.push({ type: 'playerHit', cause: w.kind, text: w.kind === 'smoke' ? '콜록콜록!' : '고막 테러!' });
        }
      }
      if (w.life <= 0 || w.s > player.s + 30) { this.scene.remove(w.group); this.waves.splice(i, 1); }
    }

    // 투척물
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i];
      const o = it.obj;
      if (!it.landed) {
        it.t += dt;
        const p = Math.min(1, it.t / it.dur);
        o.position.lerpVectors(it.from, it.to, p);
        o.position.y += Math.sin(Math.PI * p) * (it.rolling ? 2.2 : 5.5);
        o.rotation.x += dt * 9; o.rotation.z += dt * 5;
        it.marker?.userData.setProgress?.(it.rolling ? Math.min(1, it.t / 1.1) : p);
        if (p >= 1) {
          it.landed = true;
          o.position.y = it.to.y;
          this.fx.smokePuff(o.position, { count: 5, color: 0xd9cfb8 });
          if (!it.rolling) {
            if (it.marker) { this._releaseMarker(it.marker); it.marker = null; }
            if (player.invuln <= 0 && (fighting || it.fromMini) && occupies(player, it.lane) && Math.abs(it.s - player.s) < player.len / 2 + 1.6) {
              events.push({ type: it.fromMini ? 'miniHit' : 'playerHit', cause: it.kind, text: it.kind === 'cup' ? '커피 테러!' : it.kind === 'butt' ? '앗 뜨거!' : it.kind === 'phone' ? '폰 투척?!' : '으악!' });
            }
            this._burstItem(it);
            this.items.splice(i, 1);
            continue;
          }
          this.audio.play('bump', { volume: 0.5 });
        }
      } else {
        // 앞으로 굴러감 (월드 속도 = 교통 + roll)
        it.rollT += dt;
        it.s += (this.refV() + it.roll) * dt;
        o.position.z = -it.s;
        o.rotation.x -= ((this.refV() + it.roll) * dt) / 0.45;
        if (it.marker) {
          it.marker.position.z = -player.s;
          it.marker.userData.setProgress?.(Math.min(1, (it.rollT + it.dur) / 1.1));
        }
        if (player.invuln <= 0 && fighting && occupies(player, it.lane) && Math.abs(it.s - player.s) < player.len / 2 + it.len / 2) {
          events.push({ type: 'playerHit', cause: it.kind, text: it.kind === 'watermelon' ? '수박 볼링!' : it.kind === 'hay' ? '건초 직격!' : '으악!' });
          if (it.marker) { this._releaseMarker(it.marker); it.marker = null; }
          this._burstItem(it);
          this.items.splice(i, 1);
          continue;
        }
        if (it.s > player.s + 6 && it.marker) { this._releaseMarker(it.marker); it.marker = null; }
        if (it.s > player.s + 30 || (!fighting && !it.fromMini)) {
          if (it.marker) { this._releaseMarker(it.marker); it.marker = null; }
          this._releaseItem(o);
          this.items.splice(i, 1);
        }
      }
    }

    // 파편 (튕겨나간 바퀴 등)
    for (let i = this.debris.length - 1; i >= 0; i--) {
      const d = this.debris[i];
      d.life -= dt;
      d.vel.y -= 22 * dt;
      d.obj.position.addScaledVector(d.vel, dt);
      if (d.bounce && d.obj.position.y < 0.4) { d.obj.position.y = 0.4; d.vel.y = Math.abs(d.vel.y) * 0.5; d.vel.x *= 0.8; d.vel.z *= 0.8; }
      d.obj.rotation.x += d.spin.x * dt; d.obj.rotation.y += d.spin.y * dt; d.obj.rotation.z += d.spin.z * dt;
      if (d.life <= 0) { this.scene.remove(d.obj); this.debris.splice(i, 1); }
    }
    return events;
  }

  _burstItem(it) {
    const p = it.obj.position;
    const cols = it.kind === 'watermelon' ? [0xe8364a, 0x2f8f3a, 0x1e5e26] : it.kind === 'hay' ? [0xe8c45a, 0xc9a23a] : [0x7a4a2a, 0xffffff];
    this.fx.debris(p, cols, 16);
    this.fx.sparks(p, { count: 6 });
    this.audio.play('splat');
    this._releaseItem(it.obj);
  }

  // 오토파일럿용: 위험한 차선들
  dangerLanes(player) {
    const d = new Set();
    for (const w of this.waves) if (w.s < player.s + 3 && w.s > player.s - 26) for (const ln of w.lanes) d.add(ln);
    for (const b of this.beams) if (b.t < b.tele + b.on) for (const ln of b.lanes) d.add(ln);
    for (const it of this.items) {
      if (!it.rolling && !it.landed) d.add(it.lane);
      if (it.rolling && it.s < player.s + 3 && it.s > player.s - 22) d.add(it.lane);
    }
    for (const v of this.villains) if (v.alive && v.lunge && v.lunge.phase !== 'back') for (const ln of v.lanes()) d.add(ln);
    return d;
  }
}
