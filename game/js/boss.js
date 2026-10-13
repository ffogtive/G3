// 원흉(빌런) 시스템 v2 — 정면 참교육
//
// 가설: 빌런 뒤는 정체라 못 간다 → 플레이어는 갓길로 앞질러 빌런 '앞'에서 싸운다.
//       빌런의 공격은 앞으로 날아오고(상향등·경적·돌진·투척·굴리기·매연), 플레이어는 차선을 바꿔 피하며
//       뒤로 압정을 던져 빌런이 밟게 한다 → HP 25%마다 타이어 펑크 → 하늘로 날아가 반짝★.
import * as THREE from 'three';
import { laneX, LANE_W, NUM_LANES, SHOULDER_LANE } from './config.js';
import { buildVehicle, buildProjectile, buildWarningMarker, setBrake, setHazard, setFlash, setHeadlights } from './vehicles.js';
import { occupies } from './traffic.js';

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
    for (const v of this.villains) { this.scene.remove(v.mesh); this.scene.remove(v.marker); }
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
  }

  get alive() { return this.villains.filter((v) => v.alive); }
  get anyAlive() { return this.villains.some((v) => v.alive); }
  hpFrac() {
    const hp = this.villains.reduce((a, v) => a + Math.max(0, v.hp), 0);
    return hp / Math.max(1, this.totalMaxHp);
  }
  tiresLeft() { return this.villains.reduce((a, v) => a + v.tires, 0); }
  // 정속 기준 위치 (돌진 중에도 흔들리지 않게 baseS)
  refS() {
    const a = this.villains.filter((v) => v.alive || v.dying);
    const src = a.length ? a : this.villains;
    if (!src.length) return 0;
    return src.reduce((acc, v) => acc + (v.dying ? v.baseS : v.baseS), 0) / src.length;
  }
  refV() { return this.villains.length ? this.villains[0].vNominal : 0; }

  // 압정 투척 대상: 플레이어 차선 ±1 이내의 살아있는 원흉
  targetFor(player) {
    let best = null, bd = Infinity;
    for (const v of this.villains) {
      if (!v.alive) continue;
      const dx = Math.abs(v.x - player.x) - Math.max(0, (v.w - 2) / 2);
      if (dx > LANE_W * 1.15) continue;
      if (dx < bd) { bd = dx; best = v; }
    }
    return best;
  }

  // ── 피해. 반환 { popped, killed, villain }
  damage(v, amount, pos, kind = 'tack') {
    if (!v || !v.alive) return { popped: false, killed: false };
    const before = v.hp / v.maxHp;
    v.hp -= amount;
    v.flash = 1;
    const after = Math.max(0, v.hp) / v.maxHp;
    let popped = false;
    for (let k = 1; k <= 3; k++) {
      const th = 1 - k * 0.25;
      if (before > th && after <= th && v.tires > 1) { this._popTire(v); popped = true; }
    }
    if (v.hp <= 0) { v.alive = false; return { popped, killed: true, villain: v }; }
    return { popped, killed: false, villain: v };
  }

  _popTire(v) {
    const idx = POP_ORDER[4 - v.tires];
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
    while (v.tires > 0) this._popTire(v);
    const p = v.mesh.position.clone(); p.y += 1;
    this.fx.explosion(p, v.len > 6 ? 1.4 : 1.0);
    this.fx.debris(p, [v.spec.color || 0xcccccc, 0x222222, 0xdddddd], 18);
    this.audio.play('explosion');
    setHazard(v.mesh, true);
    for (const b of this.beams) if (b.v === v) b.life = 0;
  }

  _updateDeath(v, dt) {
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
    const w = this.stage.attacks || { horn: 1 };
    let tot = 0; for (const k in w) tot += w[k];
    let r = Math.random() * tot;
    for (const k in w) { if ((r -= w[k]) <= 0) return k; }
    return 'horn';
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
        if (ctx.laneFree && !ctx.laneFree(Math.round(tgt), v)) break; // 옆 차선에 화물차가 있으면 못 감
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
    const to = new THREE.Vector3(laneX(lane), kind === 'hay' ? 0.37 : 0.45, -landS);
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

  // ctx: { dt, time, phase, player, hud, laneFree(lane, v) }  반환 이벤트 배열
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
      if (v.kind === 'villainPhone') {
        v.zigBoost = Math.max(0, v.zigBoost - dt);
        v.zigT += dt * (v.zigBoost > 0 ? 2.4 : 1);
        v.targetLanePos = 1 + Math.sin(v.zigT * 0.9) * 1.0 + Math.sin(v.zigT * 2.3) * 0.15;
      } else if (v.returnAt && this.time > v.returnAt) {
        v.returnAt = 0;
        v.targetLanePos = v.homeLane;
      }
      const prevX = v.x;
      const k = v.kind === 'villainPhone' ? 3 : 5;
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

    // 공격 스케줄
    if (fighting && this.anyAlive) {
      this.attackT -= dt;
      if (this.attackT <= 0) {
        const [a, b] = this.stage.attackInterval || [2.5, 3.5];
        this.attackT = a + Math.random() * (b - a);
        const alive = this.alive;
        const v = alive[Math.floor(Math.random() * alive.length)];
        this._attack(this._chooseAttack(), v, ctx);
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
            if (player.invuln <= 0 && fighting && occupies(player, it.lane) && Math.abs(it.s - player.s) < player.len / 2 + 1.6) {
              events.push({ type: 'playerHit', cause: it.kind, text: it.kind === 'cup' ? '커피 테러!' : it.kind === 'phone' ? '폰 투척?!' : '으악!' });
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
        if (it.s > player.s + 30 || !fighting) {
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
