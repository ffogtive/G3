// 플레이어 "참교육 머신": 차선 홉 이동, 자동 가속, 추돌 처리, 연출(롤/요/홉/바퀴 회전)
import * as THREE from 'three';
import { laneX, TUNE, SHOULDER_LANE } from './config.js';
import { buildVehicle, setBrake, setHeadlights, setStrobe } from './vehicles.js';

const MAX_LANE = SHOULDER_LANE; // 0~3 차선 + 4 갓길

export class Player {
  constructor(scene) {
    this.scene = scene;
    this.kind = 'player';
    this.isPlayer = true;
    this.stats = { speed: 1, armor: 0 };
    this.beaconOff = new THREE.MeshBasicMaterial({ color: 0x5a3a00 });
    this.beaconOn = new THREE.MeshBasicMaterial({ color: 0xffa000 });
    this._build('player');
    this.reset(0, 2);
  }

  _build(vkind) {
    if (this.mesh) this.scene.remove(this.mesh);
    this.vkind = vkind;
    this.mesh = buildVehicle(vkind, { detailed: true });
    this.scene.add(this.mesh);
    const ud = this.mesh.userData;
    this.len = ud.length || 4.0;
    this.w = ud.width || 1.85;
    // 지붕 긴급 경광등 (주황, 깜빡) — 갓길 통행 명분: 참교육 긴급차량
    const h = ud.height || 1.7;
    this.beacon = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.28, 0.32), this.beaconOn);
    const bp = ud.beaconPos;
    if (bp) this.beacon.position.set(bp.x ?? bp[0], bp.y ?? bp[1], bp.z ?? bp[2]);
    else this.beacon.position.set(-0.55, h - 0.05, 0.55);
    // 암행 순찰차는 지붕 경광등 대신 숨은 적/청 스트로브
    this.beacon.visible = !(ud.strobe && ud.strobePattern === 'police');
    (ud.body || this.mesh).add(this.beacon);
  }

  // 상점에서 산 차로 교체 (스테이지 시작 시)
  setKind(vkind, night = false) {
    if (vkind && vkind !== this.vkind) this._build(vkind);
    setHeadlights(this.mesh, night);
  }

  // 참교육 점프: 앞차 한 대를 훌쩍 (0.75초 동안 충돌 무시)
  jump() {
    if (this.jumpT > 0) return false;
    this.jumpT = 0.75;
    this.v = Math.max(this.v, 10);
    return true;
  }

  reset(s, lane) {
    this.s = s; this.lane = lane; this.x = laneX(lane);
    this.v = 0; this.a = 0;
    this.lcFrom = lane; this.lcT = 1; this.lcDir = 0;
    this.wiggleT = 1; this.wiggleDir = 0;
    this.invuln = 0; this.bumpKick = 0; this.landGrace = 0;
    this.roll = 0; this.yaw = 0; this.hop = 0;
    this.mode = 'jam';
    this.ghost = false;
    this.jumpT = 0;
    this.boostT = 0;
    this.brakeOn = false;
    this.slowTime = 0;
    this.mesh.visible = true;
    this.mesh.position.set(this.x, 0, -s);
  }

  get changingLane() { return this.lcT < 1; }

  // dir: -1 왼쪽(1차선 쪽), +1 오른쪽. 반환: 'ok' | 'edge' | {blocked: entity}
  requestLane(dir, traffic) {
    const tl = this.lane + dir;
    if (tl < 0 || tl > MAX_LANE) { this._wiggle(dir); return 'edge'; }
    if (tl === SHOULDER_LANE && this.shoulderClosed) { this._wiggle(dir); return 'closed'; }   // 갓길 폐쇄·터널
    if (this.lcT < 0.65) return 'busy';
    if (!this.ghost && traffic) {
      const blocker = traffic.canMergeInto ? traffic.canMergeInto(tl, this) : traffic.laneBlocked(tl, this.s - this.len / 2 - 0.35, this.s + this.len / 2 + 0.35, this);
      if (blocker) { this._wiggle(dir); return { blocked: blocker }; }
    }
    this.lcFrom = this.x;
    this.lane = tl;
    this.lcT = 0;
    this.lcDir = dir;
    return 'ok';
  }

  _wiggle(dir) { this.wiggleT = 0; this.wiggleDir = dir; }

  // 외부 충격 (원흉 공격 등)
  knock(back = 3, kick = 1) {
    this.s -= back;
    this.v = Math.min(this.v, 0) - 1.5;
    this.bumpKick = kick;
    this.invuln = TUNE.hp?.invuln ?? 1.0;   // 피격 후 무적 (v0.4: 1.0초)
  }

  // ctx: { input, traffic, mode, bossRefS, bossRefV, cruiseV, brake }
  // 반환: 이벤트 배열 [{type:'bump', other}]
  update(dt, ctx) {
    const events = [];
    this.mode = ctx.mode;
    this.invuln = Math.max(0, this.invuln - dt);
    const prevV = this.v;

    // ── 종방향 속도
    if (ctx.mode === 'jam') {
      const braking = ctx.brake;
      if (braking) this.v = Math.max(0, this.v - TUNE.playerBrake * dt);
      else {
        const vmax = (this.lane === SHOULDER_LANE ? TUNE.shoulderMaxV : TUNE.playerMaxV) * (this.stats?.speed || 1) * (ctx.boostT > 0 ? 1.4 : 1);
        this.v = Math.min(vmax, this.v + TUNE.playerAccel * (ctx.boostT > 0 ? 2 : 1) * dt * (this.v < 0 ? 2.2 : 1));
      }
      // 소프트 추종: 앞차를 고속으로 들이받지 않게 자동 감속 (부술 수 있는 콘·낙하물은 예외 → 날려버림)
      const L0 = ctx.traffic ? ctx.traffic.leaderOf(this) : null;
      let auto = false;
      if (L0 && !L0.car.smash && !(this.jumpT > 0) && !(this.stats?.tow && L0.car.isObstacle)) {
        const vSafe = Math.max(0, L0.car.v + Math.max(0, L0.gap - 0.9) * 2.4);
        if (this.v > vSafe) { this.v = Math.max(vSafe, this.v - TUNE.playerBrake * dt); auto = true; }
      }
      this.brakeOn = braking || auto;
    } else if (ctx.mode === 'boss') {
      // 보스전: 빌런 '앞'에서 (뒤는 정체라 못 감) 같은 속도로 달리며 뒤로 압정 투척
      const target = ctx.bossRefS + TUNE.bossAheadGap;
      const vCmd = ctx.bossRefV + Math.max(-7, Math.min(9, (target - this.s) * 1.6));
      const dv = vCmd - this.v;
      this.v += Math.max(-14 * dt, Math.min(12 * dt, dv));
      this.brakeOn = dv < -0.5;
    } else if (ctx.mode === 'cruise') {
      // 해방 후 질주: 앞차가 가까우면 속도를 맞춘다 (뚫고 지나가지 않게)
      let vt = ctx.cruiseV;
      const L = ctx.traffic ? ctx.traffic.leaderOf(this) : null;
      if (L && L.gap < 12) vt = Math.min(vt, L.car.v + Math.max(-3, (L.gap - 5) * 0.6));
      const dv = vt - this.v;
      this.v += Math.max(-14 * dt, Math.min(7 * dt, dv));
      this.brakeOn = dv < -1;
    } else { // 'idle' (인트로/결과)
      const dv = (ctx.cruiseV ?? 0) - this.v;
      this.v += Math.max(-8 * dt, Math.min(6 * dt, dv));
      this.brakeOn = this.v < 0.5;
    }
    this.a = (this.v - prevV) / Math.max(dt, 1e-4);
    this.s += this.v * dt;

    // ── 추돌 (정체 구간만)
    if (ctx.mode === 'jam' && ctx.traffic && !this.ghost) {
      const L = this.jumpT > 0 ? null : ctx.traffic.leaderOf(this);
      if (L && L.gap < 0 && L.car.smash) {
        // 콘·낙하물: 날려버리고 살짝 감속 (분노 가속 중엔 감속 없음)
        events.push({ type: 'smash', other: L.car });
        if (!(ctx.boostT > 0)) this.v *= 0.62;
      } else if (L && L.gap < 0 && L.car.isObstacle && this.stats?.tow) {
        // 레커차: 고장차 즉시 견인
        events.push({ type: 'tow', other: L.car });
      } else if (L && L.gap < 0) {
        const other = L.car;
        this.s = other.s - other.len / 2 - this.len / 2 - 0.35;
        if (this.landGrace > 0) {
          // 점프 착지 직후: 다음 차 뒤 틈에 '쏙' 내려앉는 것으로 처리 (추돌·분노·감속 페널티 없음)
          this.v = Math.min(this.v, other.v);
        } else if (this.invuln <= 0) {
          const relV = this.v - (other.v || 0);   // 추돌 상대속도 (내구도 피해 판정)
          this.v = Math.min(this.v, other.v) * 0.2 - 2.6;
          this.bumpKick = 1;
          this.invuln = 0.45;
          events.push({ type: 'bump', other, relV });
        } else {
          this.v = Math.min(this.v, other.v);
        }
      }
    }
    if (ctx.mode === 'jam' && this.v < 5) this.slowTime += dt;

    // ── 횡방향 (차선 홉)
    if (this.lcT < 1) {
      this.lcT = Math.min(1, this.lcT + dt / TUNE.laneChangeTime);
      const e = 1 - Math.pow(1 - this.lcT, 3);
      this.x = this.lcFrom + (laneX(this.lane) - this.lcFrom) * e;
      const arc = Math.sin(Math.PI * this.lcT);
      this.hop = 0.28 * arc;
      this.roll = -this.lcDir * 0.16 * arc;
      this.yaw = -this.lcDir * 0.16 * arc;
    } else {
      this.x = laneX(this.lane);
      this.hop *= Math.exp(-dt * 20);
      this.roll *= Math.exp(-dt * 14);
      this.yaw *= Math.exp(-dt * 14);
    }
    let wig = 0;
    if (this.wiggleT < 1) {
      this.wiggleT = Math.min(1, this.wiggleT + dt / 0.22);
      wig = Math.sin(Math.PI * this.wiggleT) * 0.55 * this.wiggleDir;
    }

    // 점프 아치
    this.landGrace = Math.max(0, (this.landGrace || 0) - dt);
    if (this.jumpT > 0) {
      this.jumpT = Math.max(0, this.jumpT - dt);
      const p = 1 - this.jumpT / 0.75;
      this.hop = Math.max(this.hop, Math.sin(Math.PI * p) * 3.4);
      if (this.jumpT === 0) this.landGrace = 0.35;
    }
    // ── 메시 반영
    this.bumpKick = Math.max(0, this.bumpKick - dt * 3.2);
    const m = this.mesh;
    m.position.set(this.x + wig, this.hop, -this.s);
    m.rotation.y = this.yaw - wig * 0.08;
    const body = m.userData.body;
    if (body) {
      const accPitch = Math.max(-0.06, Math.min(0.06, this.a * 0.004));
      body.rotation.x = accPitch - this.bumpKick * 0.14 * Math.sin(this.bumpKick * 9);
      body.rotation.z = this.roll;
      body.position.y = (ctx.mode === 'jam' && this.v < 0.5 ? Math.sin(performance.now() * 0.03) * 0.012 : 0);
    }
    const r = m.userData.wheelRadius || 0.42;
    for (const w of m.userData.wheels || []) w.rotation.x -= (this.v * dt) / r;
    setBrake(m, this.brakeOn);
    const blink = Math.floor(performance.now() / 180) % 2 === 0;
    const urgent = ctx.mode === 'jam' || ctx.mode === 'boss';
    this.beacon.material = urgent && blink ? this.beaconOn : this.beaconOff;
    if (m.userData.strobe) setStrobe(m, urgent ? performance.now() / 1000 : null);
    // 보스전에선 지붕 압정포가 뒤(빌런 쪽)를 본다
    const cannon = m.userData.cannon;
    if (cannon) {
      const want = ctx.mode === 'boss' ? Math.PI : 0;
      cannon.rotation.y += (want - cannon.rotation.y) * Math.min(1, dt * 8);
    }

    // 무적 깜빡임
    m.visible = !(this.invuln > 0.05 && Math.floor(this.invuln * 16) % 2 === 0 && ctx.mode === 'boss');
    return events;
  }
}
