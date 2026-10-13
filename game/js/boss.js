// 원흉(빌런) 시스템: 정속 주행, 도발, 공격 패턴, 타이어 펑크(HP 25%마다), 하늘로 발사되는 최후
import * as THREE from 'three';
import { laneX, LANE_W, NUM_LANES, TUNE } from './config.js';
import { buildVehicle, buildProjectile, buildWarningMarker, setBrake, setHazard, setFlash } from './vehicles.js';
import { occupies } from './traffic.js';

const POP_ORDER = [2, 3, 0, 1]; // RL, RR, FL, FR
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
    this.s = s;
    this.v = stage.jamSpeed;
    this.vNominal = stage.jamSpeed;
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
    this.brakeBlink = 0;
    this.zigT = Math.random() * 10;
    this.zigBoost = 0;
    this.taunt = null;
    this.nextTaunt = 1.5 + index * 1.7;
    this.mesh.position.set(this.x, 0, -s);
    // 머리 위 '원흉' 표식 (빨간 화살표, 통통 튐)
    this.marker = new THREE.Group();
    const mm = new THREE.MeshBasicMaterial({ color: 0xff2a2a });
    const arrow = new THREE.Mesh(new THREE.ConeGeometry(0.75, 1.5, 4), mm);
    arrow.rotation.x = Math.PI; // 아래를 가리킴
    const cap = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.7, 0.7), mm);
    cap.position.y = 1.05;
    this.marker.add(arrow, cap);
    scene.add(this.marker);
  }

  get lane() { return Math.round(this.lanePos); }

  wheelWorldPos(i, out) {
    const w = this.mesh.userData.wheels?.[i];
    if (w) return w.getWorldPosition(out);
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
    this.items = [];
    this.debris = [];
    this.pools = {};
    this.markerPool = [];
    this.attackT = 3;
    this.time = 0;
    this.waveMat = new THREE.MeshBasicMaterial({ color: 0xff2a2a, transparent: true, opacity: 0.5, depthWrite: false });
    this.smokeMat = new THREE.MeshBasicMaterial({ color: 0x1b1b1b, transparent: true, opacity: 0.6, depthWrite: false });
    this.waveGeo = new THREE.BoxGeometry(LANE_W * 0.92, 1.3, 1.4);
    this.chevGeo = new THREE.ConeGeometry(0.9, 1.4, 3);
  }

  clear() {
    for (const v of this.villains) { this.scene.remove(v.mesh); this.scene.remove(v.marker); }
    for (const w of this.waves) this.scene.remove(w.group);
    for (const it of this.items) { this.scene.remove(it.obj); if (it.marker) this._releaseMarker(it.marker); }
    for (const d of this.debris) this.scene.remove(d.obj);
    this.villains.length = 0; this.waves.length = 0; this.items.length = 0; this.debris.length = 0;
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
  refS() {
    const a = this.villains.filter((v) => v.alive || v.dying);
    if (!a.length) return this.villains.length ? this.villains[0].s : 0;
    return a.reduce((acc, v) => acc + v.s, 0) / a.length;
  }
  refV() { return this.villains.length ? this.villains[0].vNominal : 0; }

  // 사격 대상: 플레이어 차선 ±1 이내의 살아있는 원흉 (가장 가까운 것)
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

  // ── 피해 처리. 반환 { popped, killed, villain }
  damage(v, amount, pos, kind = 'tack') {
    if (!v || !v.alive) return { popped: false, killed: false };
    const before = v.hp / v.maxHp;
    v.hp -= amount;
    v.flash = 1;
    const after = Math.max(0, v.hp) / v.maxHp;
    let popped = false;
    // 25% 경계를 넘을 때마다 타이어 펑크
    for (let k = 1; k <= 3; k++) {
      const th = 1 - k * 0.25;
      if (before > th && after <= th && v.tires > 1) { this._popTire(v); popped = true; }
    }
    if (v.hp <= 0) {
      v.alive = false;
      return { popped, killed: true, villain: v };
    }
    return { popped, killed: false, villain: v };
  }

  _popTire(v) {
    const idx = POP_ORDER[4 - v.tires];
    v.tires--;
    const wheel = v.mesh.userData.wheels?.[idx];
    const p = v.wheelWorldPos(idx, new THREE.Vector3());
    if (wheel) {
      this.scene.attach(wheel);
      const side = idx % 2 === 0 ? -1 : 1;
      this.debris.push({
        obj: wheel, vel: new THREE.Vector3(side * (5 + Math.random() * 4), 7 + Math.random() * 3, -(v.v + 2) - Math.random() * 4),
        spin: new THREE.Vector3(8 + Math.random() * 8, Math.random() * 4, side * 6), life: 3.2, bounce: true,
      });
    }
    v.sparkCorners.push(idx);
    // 차체가 펑크난 쪽으로 기움
    v.tiltZ += (idx % 2 === 0 ? 1 : -1) * 0.07;
    v.tiltX += (idx < 2 ? -1 : 1) * 0.05; // +rotation.x = 코가 들림 → 앞바퀴 펑크면 코가 숙여져야 함
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
    v.vel = new THREE.Vector3(0, 8, -(v.v + 3));
    v.spin = new THREE.Vector3(3.5 + Math.random() * 2, 7 + Math.random() * 3, 2.5);
    v.launched = false;
    // 남은 바퀴 전부 이탈
    while (v.tires > 0) this._popTire(v);
    const p = v.mesh.position.clone(); p.y += 1;
    this.fx.explosion(p, v.len > 6 ? 1.4 : 1.0);
    this.fx.debris(p, [v.spec.color || 0xcccccc, 0x222222, 0xdddddd], 18);
    this.audio.play('explosion');
    setHazard(v.mesh, true);
  }

  _updateDeath(v, dt) {
    v.deathT += dt;
    const m = v.mesh;
    if (!v.launched && v.deathT > 0.85) {
      v.launched = true;
      v.vel.set((Math.random() - 0.5) * 4, 36, -(v.v + 14));
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
    obj.userData.kind = kind;
    return obj;
  }
  _releaseItem(obj) { obj.visible = false; (this.pools[obj.userData.kind] ||= []).push(obj); }

  // ── 공격
  _chooseAttack() {
    const w = this.stage.attacks || { brakeCheck: 1 };
    let tot = 0; for (const k in w) tot += w[k];
    let r = Math.random() * tot;
    for (const k in w) { if ((r -= w[k]) <= 0) return k; }
    return 'brakeCheck';
  }

  _attack(kind, v, player, hud) {
    switch (kind) {
      case 'brakeCheck': {
        v.brakeCheck = { t: 0, fired: false };
        hud.popAt(_v3.set(v.x, v.h + 1.6, -v.s), '급정거 체크!', 'warn');
        this.audio.play('warn');
        break;
      }
      case 'throw': {
        const n = this.stage.villains.length > 1 ? 1 : (this.stage.throwItem === 'hay' ? 2 : (Math.random() < 0.4 ? 2 : 1));
        const lanes = new Set([player.lane]);
        while (lanes.size < n) lanes.add(Math.max(0, Math.min(NUM_LANES - 1, player.lane + (Math.random() < 0.5 ? -1 : 1) * (1 + Math.floor(Math.random() * 2)))));
        for (const ln of lanes) this._throw(v, ln, player);
        if (Math.random() < 0.6) this._say(v, this.stage.throwItem === 'watermelon' ? '수박 서비스~' : this.stage.throwItem === 'hay' ? '거름이여~' : '옛다!');
        break;
      }
      case 'swerve': {
        let tgt = player.lane;
        if (v.w > 2.2 || v.kind === 'villainSuv') tgt = Math.max(0.5, Math.min(2.5, player.lane + (player.lane > v.lanePos ? -0.5 : 0.5)));
        tgt = Math.max(0, Math.min(NUM_LANES - 1, tgt));
        v.targetLanePos = tgt;
        v.swerveFollow = 0.75;
        this.audio.play('brakeScreech', { volume: 0.5 });
        this._say(v, '비켜 비켜~');
        break;
      }
      case 'zigzag': {
        v.zigBoost = 2.6;
        this._say(v, 'ㅋㅋㅋㅋㅋ');
        if (Math.random() < 0.5) setTimeout(() => { if (v.alive) v.brakeCheck = { t: 0, fired: false }; }, 900);
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

  _say(v, text, dur = 2.0) { v.taunt = { text, until: this.time + dur }; this.audio.play('tauntBlip'); }

  _throw(v, lane, player) {
    const kind = this.stage.throwItem || 'cup';
    const obj = this._getItem(kind);
    const from = new THREE.Vector3(v.x, v.h + 0.4, -(v.s - v.len * 0.45));
    // 굴러오는 것(수박/건초) = 앞에 떨어져 플레이어 쪽으로 굴러옴 / 나머지 = 0.85초 뒤 플레이어 위치에 직격 (경고 표식)
    const rolling = kind === 'watermelon' || kind === 'hay';
    const dur = 0.85;
    const landS = rolling ? player.s + 11 + Math.random() * 4 : player.s + Math.max(0, player.v) * dur + 0.4;
    const to = new THREE.Vector3(laneX(lane), kind === 'hay' ? 0.37 : 0.45, -landS);
    const marker = this._getMarker();
    marker.position.set(to.x, 0.04, to.z);
    marker.userData.setProgress?.(0);
    obj.position.copy(from);
    this.items.push({
      obj, kind, lane, from, to, t: 0, dur, landed: false, marker, rolling,
      roll: kind === 'watermelon' ? -5.5 : kind === 'hay' ? -3.5 : 0, s: landS, len: kind === 'hay' ? 1.5 : 1.1,
    });
    this.audio.play('throw');
  }

  _wave(v, kind = 'brake') {
    const lanes = [];
    for (let i = 0; i < NUM_LANES; i++) if (occupies(v, i)) lanes.push(i);
    if (kind === 'smoke') {
      // 매연은 옆 차선까지
      const l0 = Math.min(...lanes), l1 = Math.max(...lanes);
      if (l0 > 0) lanes.push(l0 - 1);
      if (l1 < NUM_LANES - 1) lanes.push(l1 + 1);
    }
    const group = new THREE.Group();
    for (const ln of lanes) {
      const slab = new THREE.Mesh(this.waveGeo, kind === 'smoke' ? this.smokeMat : this.waveMat);
      slab.position.set(laneX(ln), 0.65, 0);
      group.add(slab);
      if (kind !== 'smoke') {
        const ch = new THREE.Mesh(this.chevGeo, this.waveMat);
        ch.rotation.x = Math.PI / 2; // 뒤(+Z)를 가리키는 화살촉
        ch.position.set(laneX(ln), 1.9, 0.6);
        group.add(ch);
      } else {
        slab.scale.set(1, 2.2, 3);
      }
    }
    group.position.z = -(v.s - v.len / 2);
    this.scene.add(group);
    this.waves.push({ group, lanes, s: v.s - v.len / 2, speed: kind === 'smoke' ? 13 : 24, kind, hit: false, life: 3.5 });
    if (kind === 'smoke') for (let i = 0; i < 5; i++) this.fx.smokePuff(new THREE.Vector3(v.x, 1.5, -(v.s - v.len / 2)), { color: 0x222222, count: 8, size: 1.6 });
  }

  // ctx: { dt, time, phase, player, hud }  반환 이벤트 배열
  update(dt, ctx) {
    this.time = ctx.time;
    const events = [];
    const player = ctx.player;
    const hud = ctx.hud;
    const fighting = ctx.phase === 'boss';

    for (const v of this.villains) {
      if (v.dying) { this._updateDeath(v, dt); continue; }
      if (!v.alive) continue;

      // 종방향: 정속 (급정거 체크 시 코 박기)
      v.v = v.vNominal;
      if (v.brakeCheck) {
        const bc = v.brakeCheck;
        bc.t += dt;
        v.brakeBlink += dt;
        setBrake(v.mesh, Math.floor(bc.t * 14) % 2 === 0);
        v.nose = Math.min(1, bc.t / 0.6);
        if (!bc.fired && bc.t > 0.6) {
          bc.fired = true;
          this._wave(v, 'brake');
          this.audio.play('brakeScreech');
          this.fx.smokePuff(_v3.set(v.x, 0.3, -(v.s - v.len * 0.4)), { count: 8, color: 0xeeeeee });
        }
        if (bc.t > 1.1) { v.brakeCheck = null; setBrake(v.mesh, false); }
      } else {
        v.nose = Math.max(0, v.nose - dt * 3);
        setBrake(v.mesh, false);
      }
      v.s += v.v * dt;

      // 횡방향
      if (v.kind === 'villainPhone') {
        v.zigBoost = Math.max(0, v.zigBoost - dt);
        v.zigT += dt * (v.zigBoost > 0 ? 2.4 : 1);
        v.targetLanePos = 1 + Math.sin(v.zigT * 0.9) * 1.0 + Math.sin(v.zigT * 2.3) * 0.15;
      } else if (v.swerveFollow > 0) {
        v.swerveFollow -= dt;
        if (v.swerveFollow <= 0) {
          v.brakeCheck = { t: 0.25, fired: false };
          // 잠시 후 원위치
          v.returnAt = this.time + 2.5;
        }
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

      // 원흉 표식
      v.marker.visible = true;
      v.marker.position.set(v.x, v.h + 2.3 + Math.sin(this.time * 5 + v.index) * 0.35, -v.s);
      v.marker.rotation.y = this.time * 2.5;
      const sc = 1 + Math.min(1.2, Math.max(0, (player.s < v.s - 40 ? (v.s - player.s - 40) / 60 : 0)));
      v.marker.scale.setScalar(sc);

      // 메시
      v.flash = Math.max(0, v.flash - dt * 9);
      setFlash(v.mesh, v.flash);
      const m = v.mesh;
      m.position.set(v.x, 0, -v.s);
      m.rotation.set(0, v.yaw, 0);
      const body = m.userData.body;
      if (body) {
        body.rotation.x = v.tiltX - v.nose * 0.09 + Math.sin(this.time * 18) * 0.004 * v.sparkCorners.length;
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
        this._attack(this._chooseAttack(), v, player, hud);
      }
    }

    // 파동 (급정거/매연)
    for (let i = this.waves.length - 1; i >= 0; i--) {
      const w = this.waves[i];
      const ref = this.refV();
      const prevS = w.s;
      w.s += (ref - w.speed) * dt;
      w.life -= dt;
      w.group.position.z = -w.s;
      const pulse = 1 + Math.sin(this.time * 30) * 0.08;
      w.group.scale.set(1, pulse, 1);
      if (!w.hit && player.invuln <= 0 && ctx.phase === 'boss') {
        const front = player.s + player.len / 2;
        if (prevS >= player.s - player.len / 2 && w.s <= front && w.lanes.some((ln) => occupies(player, ln))) {
          w.hit = true;
          events.push({ type: 'playerHit', cause: w.kind, text: w.kind === 'smoke' ? '콜록콜록!' : '급정거 당함!' });
        }
      }
      if (w.life <= 0 || w.s < player.s - 25) { this.scene.remove(w.group); this.waves.splice(i, 1); }
    }

    // 투척물
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i];
      const o = it.obj;
      if (!it.landed) {
        it.t += dt;
        const p = Math.min(1, it.t / it.dur);
        // 이동하는 도로 위에서: 목표 지점은 월드 고정
        o.position.lerpVectors(it.from, it.to, p);
        o.position.y += Math.sin(Math.PI * p) * 5.5;
        o.rotation.x += dt * 9; o.rotation.z += dt * 5;
        it.marker?.userData.setProgress?.(p);
        if (p >= 1) {
          it.landed = true;
          if (it.marker) { this._releaseMarker(it.marker); it.marker = null; }
          o.position.y = it.to.y;
          o.rotation.set(0, Math.random() * 6, 0);
          this.fx.smokePuff(o.position, { count: 5, color: 0xd9cfb8 });
          this.audio.play(it.kind === 'cup' || it.kind === 'phone' ? 'splat' : 'bump', { volume: 0.6 });
          if (!it.rolling) {
            // 직격형: 착지 순간 판정 후 사라짐 (커피는 웅덩이 연출만)
            if (player.invuln <= 0 && ctx.phase === 'boss' && occupies(player, it.lane) && Math.abs(it.s - player.s) < player.len / 2 + 1.6) {
              events.push({ type: 'playerHit', cause: it.kind, text: it.kind === 'cup' ? '커피 테러!' : it.kind === 'phone' ? '폰 투척?!' : '으악!' });
            }
            this._burstItem(it);
            this.items.splice(i, 1);
            continue;
          }
        }
      } else {
        it.s += it.roll * dt;
        o.position.z = -it.s;
        if (it.roll) o.rotation.x -= (it.roll * dt) / 0.45;
        // 플레이어 충돌
        if (player.invuln <= 0 && ctx.phase === 'boss' && occupies(player, it.lane)
          && Math.abs(it.s - player.s) < player.len / 2 + it.len / 2) {
          events.push({ type: 'playerHit', cause: it.kind, text: it.kind === 'watermelon' ? '수박 테러!' : it.kind === 'hay' ? '건초 직격!' : it.kind === 'cup' ? '커피 테러!' : '으악!' });
          this._burstItem(it);
          this.items.splice(i, 1);
          continue;
        }
        if (it.s < player.s - 18 || ctx.phase !== 'boss') {
          this._releaseItem(o); o.scale.set(1, 1, 1);
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
    it.obj.scale.set(1, 1, 1);
  }

  // 오토파일럿용: 차선별 위험도
  dangerLanes(player) {
    const d = new Set();
    for (const w of this.waves) if (w.s > player.s - 3 && w.s - player.s < 22) for (const ln of w.lanes) d.add(ln);
    for (const it of this.items) {
      const s = it.landed ? it.s : -it.to.z;
      if (s - player.s < 16 && s - player.s > -4) d.add(it.lane);
    }
    for (const v of this.villains) if (v.alive && v.brakeCheck) for (let i = 0; i < NUM_LANES; i++) if (occupies(v, i)) d.add(i);
    return d;
  }
}
